// omacvm-gestures (Mac side): gives the Omarchy VM in Parallels the Mac trackpad's
// multi-finger gestures.
//
// While Parallels or UTM is the frontmost app and its VM window covers a whole display
// ("capture mode"):
//   * macOS trackpad gesture events (Spaces / Mission Control swipes, pinch,
//     rotate, smart zoom) are dropped by an event tap, so macOS reacts to none
//     of them;
//   * raw finger contacts from the built-in trackpad (MultitouchSupport) are
//     sent to the guest daemon, which replays them on a virtual touchpad:
//     every frame with 3+ fingers, and 2-finger frames once they are a pinch;
//   * one-finger movement, clicks and two-finger scrolling stay on Parallels'
//     own path (absolute pointer, native smooth scrolling), unless the VM
//     uses Glide (below).
// While the VM is full screen, the macOS pointer is hidden wherever the VM window
// is what lies under it (the guest draws its own pointer); over anything else
// (the Omanotch strip, the Dock, menus, another display) it shows.
// Ctrl+Option+Cmd+Esc in the full-screen VM hands everything back to macOS and
// swipes the display under the pointer to the Space beside the VM's (macOS's
// own animation); pressed there again in macOS, it swipes back into the VM
// (escape section below).
// Capture re-arms by itself when the VM is in front again. If this process
// dies, the event tap goes with it and macOS gets its gestures back.
// Each VM says on connect what it wants (the handshake below). Capture
// only covers a full-screen VM whose connected daemon wants the trackpad, so a
// VM with gestures off (or not connected yet) leaves macOS its gestures.
// Glide (experimental, per VM): two-finger scrolling goes to the guest too.
// While fingers touch the built-in trackpad, their raw positions do (every
// two-finger frame, precise to hundredths of a millimetre) along with macOS's
// own scroll for them ("A", macOS's acceleration); after they lift, macOS's
// momentum goes as point deltas ("W"), which the guest continues the touch
// with. macOS's own scroll events then do not reach the VM app. Other
// continuous scrolling (Magic Mouse) goes as W deltas as a whole; a wheel
// mouse (discrete steps) still scrolls through the VM app.
// --keys-only: no trackpad for any VM (macOS keeps every gesture); on UTM, Cmd
// still reaches the guest as Super (below). --record: the built-in trackpad's
// frames and macOS's scroll events to ~/Library/Logs/omacvm-input.tsv (Glide
// diagnostics, see docs/experiments/scroll-analysis).
//
// Protocol (TCP, the guest connects to the Mac on port 47830: 10.211.55.2 on
// Parallels, 192.168.64.1 on UTM, .1 of Fusion's NAT network), one line per message:
//   F <n> [<id> <x> <y> <size>]...   x/y 0..1 with y down, size >= 0
//   S <on|off|esc>                    capture state changes
//   O <natural> <w> <h>               on connect: macOS's natural scrolling (1/0) and the
//                                     trackpad's size in 1/100 mm
//   A <dx> <dy>                       Glide: macOS's scroll while the fingers touch (points)
//   W <dx> <dy>                       Glide: macOS's momentum (and Magic Mouse) in points
//   P                                 Glide: macOS recognized a pinch (magnify)
//   K <code> <0|1|2>                  UTM: a Cmd shortcut as Super+key (Linux keycode)
// and first, the handshake (any VM on these networks, and any Mac program on
// 127.0.0.1, can connect; neither side ever sends the Bridge's token itself):
//   C <guest nonce>                   from the guest: 32 hex digits
//   M <mac nonce> <proof>             the Mac proves it knows the token: HMAC-SHA256(token,
//                                     "omacvm-gestures mac <addr> <guest nonce> <mac nonce>"), hex;
//                                     <addr>: the Mac address it accepted on, so a proof that
//                                     a listener on 127.0.0.1 fetched from 10.211.55.2 fails
//   R <gestures 0|1> <glide 0|1> <proof> [<name>]   from the guest once the Mac's proof
//                                     holds: what this VM wants, its own proof (as above
//                                     with "vm") and the VM's name in base64 (omacvm apply
//                                     tells the VM). Only then do the lines above flow.
// Daemons from before the handshake (OmacVM 2.4, 2.5) send "H <gestures> <glide>
// <token> [<name>]", still let in until omacvm apply gives them the new one.
// Daemons from before the token (2.3 and older) are refused: omacvm update.
// Two VMs in one app share its network: F, K, A, W, P and S on/esc go only to
// the VM whose name is in the title of the app's front window; without such a
// match (VMs from before the name, a renamed VM) to every VM of that app.
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0   // macOS: SO_NOSIGPIPE is set on the socket instead
#endif

// ---- MultitouchSupport (private framework) ----
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
  int32_t frame; double timestamp; int32_t pathIndex, state, fingerID, handID;
  MTVector normalized; float zTotal; int32_t f9; float angle, majorAxis, minorAxis;
  MTVector absolute; int32_t f14, f15; float zDensity;
} MTTouch;
typedef void *MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, MTTouch *, int, double, int);
extern CFArrayRef MTDeviceCreateList(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef, MTFrameCallback);
extern void MTDeviceStart(MTDeviceRef, int);
extern bool MTDeviceIsBuiltIn(MTDeviceRef);
extern int MTDeviceGetSensorSurfaceDimensions(MTDeviceRef, int *, int *);   // 1/100 mm

#ifndef PORT
#define PORT 47830
#endif
// The Mac's address on each VM network: Parallels' shared network, UTM's
// shared network (vmnet), VMware Fusion's NAT network (vmnet8: Fusion picks
// its subnet at install time, the Mac is .1; empty without Fusion) and
// OmacVM.app (QEMU's user network reaches the Mac's 127.0.0.1; its fast
// network, src/net/mac, is 192.168.77.0/24). One listener per address; never
// 0.0.0.0.
static char listenAddrs[5][16] = { "10.211.55.2", "192.168.64.1", "", "127.0.0.1", "192.168.77.1" };
#define NET_UTM 1
#define NET_FUSION 2
#define NET_APP 3
#define NET_APP_FAST 4   // its clients count as NET_APP's

// The first VNET_8_HOSTONLY_SUBNET line, and only a private address (as
// fusion_host in src/lib/mac.sh and the Bridge read it). Fusion installed
// after this helper started: the Fusion listener reads it again until found.
static void readFusionHost(void) {
  FILE *f = fopen("/Library/Preferences/VMware Fusion/networking", "r");
  char line[256], net[32];
  struct in_addr a;
  if (!f) return;
  while (fgets(line, sizeof line, f)) {
    if (sscanf(line, "answer VNET_8_HOSTONLY_SUBNET %31s", net) != 1) continue;
    if (inet_pton(AF_INET, net, &a) == 1) {
      uint32_t h = ntohl(a.s_addr);
      int priv = (h >> 24) == 10 || (h >> 20) == 0xAC1 || (h >> 16) == 0xC0A8;
      char host[16];
      snprintf(host, sizeof host, "%u.%u.%u.1", h >> 24, (h >> 16) & 255, (h >> 8) & 255);
      if (priv && strcmp(host, listenAddrs[0]) && strcmp(host, listenAddrs[NET_UTM]) && strcmp(host, listenAddrs[NET_APP_FAST])) {
        // Other threads test the first byte: set it last.
        memcpy(listenAddrs[NET_FUSION] + 1, host + 1, sizeof host - 1);
        __sync_synchronize();
        listenAddrs[NET_FUSION][0] = host[0];
      }
    }
    break;
  }
  fclose(f);
}
#define ESC_KEYCODE 53
#define PINCH_SPREAD 0.035f         // normalized change of finger distance that makes a pinch
#define PINCH_RATIO 1.3f            // ... and it must exceed the centroid movement by this much

static volatile int frontIsVM, escaped, capturing;
static pid_t frontPid;   // the full-screen VM app in front, else 0
// The escape combo's way out and back: the last app in front that was no VM
// app, and the last full-screen VM, each with its front window.
static pid_t otherPid, vmPid, appPid;   // appPid: the app in front at the last check
static CGWindowID otherWin, vmWin;
// Every VM that runs the guest daemon stays connected (one per address);
// frames go only to VMs on the network of the frontmost VM app (0 = Parallels,
// 1 = UTM, 2 = Fusion, 3 = OmacVM.app, the index into listenAddrs). One connection per VM used to mean
// two running VMs pushed each other off every two seconds.
#define MAX_CLIENTS 8
static struct { int fd, net, gestures, glide, target; char ip[32], name[256]; } clients[MAX_CLIENTS];
static volatile int frontNet = -1;
static char frontTitle[512];      // the front VM app's window title (Accessibility)
static pthread_mutex_t sendLock = PTHREAD_MUTEX_INITIALIZER;
static CFMachPortRef tapPort;
static CFRunLoopSourceRef tapSource;
static CGEventMask tapMask;
static CGEventRef tapCb(CGEventTapProxy p, CGEventType type, CGEventRef e, void *u);
static int verbose;
int ns_event_type(CGEventRef e);  // scroll_ns.m
void ns_on_app_activate(void (*f)(void));
int ns_activate(pid_t pid);
int ns_hide(pid_t pid);
int ns_is_regular(pid_t pid);
static int isOther(pid_t pid, int net, const char *name, int regular);
pid_t ns_finder_pid(void);
static int trackpad = 1;          // 0 with --keys-only
static int tpW = 15600, tpH = 9600;   // built-in trackpad, 1/100 mm
static FILE *rec;                 // --record: trackpad frames and macOS's scroll, for analysis
static double unixNow(void) { return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970; }
static volatile int fingers;      // contacts in the built-in trackpad's last frame
static int pinchSent;             // P sent for the current two-finger touch

static void logf_(const char *fmt, ...) {
  time_t t = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
  va_list ap; va_start(ap, fmt); printf("%s omacvm-gestures: ", ts); vprintf(fmt, ap); printf("\n"); va_end(ap);
  fflush(stdout);
}

// ---- which VM is in front ----
// Every VM of an app connects from the app's one network, so the network tells
// the app, not the VM. The VM is told by its name (from its hello) in the title
// of the app's front window: Parallels, UTM and VMware Fusion put the VM's name
// there, in a window or full screen. The name that is the title wins, else the
// longest name in it ("Omarchy 2" over "Omarchy"). No match: every VM on the
// front app's network, as before VMs said their name.
static int nameIs(int i, int exact) {
  const char *n = clients[i].name;
  return n[0] && (exact ? !strcmp(frontTitle, n) : strstr(frontTitle, n) != NULL);
}

// The front VM's clients (clients[].target); sendLock held. Returns the
// targets as a bit mask.
static unsigned pickTargets(void) {
  int exact = 0; size_t best = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || clients[i].net != frontNet) continue;
    if (nameIs(i, 1)) exact = 1;
    else if (nameIs(i, 0) && strlen(clients[i].name) > best) best = strlen(clients[i].name);
  }
  unsigned mask = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    int on = clients[i].fd >= 0 && clients[i].net == frontNet &&
             (exact ? nameIs(i, 1) : best ? nameIs(i, 0) && strlen(clients[i].name) == best : 1);
    clients[i].target = on;
    if (on) mask |= 1u << i;
  }
  return mask;
}

// After the front window, the front app or the connected VMs changed; sendLock
// held. While capturing (states), a VM that stops being the front one gets
// "S off" (it lets go of held fingers and keys) and a new one "S on".
static void retargetLocked(int states) {
  static unsigned last;
  unsigned mask = pickTargets();
  if (mask == last) return;
  char who[256] = ""; size_t n = 0; int named = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (!(mask & 1u << i)) continue;
    named |= nameIs(i, 0);
    n += (size_t)snprintf(who + n, n < sizeof who ? sizeof who - n : 0, "%s%s", n ? ", " : "", clients[i].ip);
    if (n >= sizeof who) n = sizeof who - 1;
  }
  logf_("front window \"%s\": %s%s", frontTitle, named ? "" : "every VM of the app, ", mask ? who : "no VM connected");
  for (int i = 0; states && i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || !((mask ^ last) & 1u << i)) continue;
    const char *st = mask & 1u << i ? "S on\n" : "S off\n";
    send(clients[i].fd, st, strlen(st), MSG_NOSIGNAL);
  }
  last = mask;
}

// all: every client; else the front VM's.
static void sendTo(int all, const char *line, size_t len) {
  pthread_mutex_lock(&sendLock);
  int dropped = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || (!all && !clients[i].target)) continue;
    if (send(clients[i].fd, line, len, MSG_NOSIGNAL) < 0) {
      logf_("guest disconnected: %s", clients[i].ip);
      close(clients[i].fd); clients[i].fd = -1; dropped = 1;
    }
  }
  if (dropped) retargetLocked(capturing);
  pthread_mutex_unlock(&sendLock);
}

static int haveClient(void) {
  int found = 0;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) if (clients[i].fd >= 0 && clients[i].target) found = 1;
  pthread_mutex_unlock(&sendLock);
  return found;
}

// What the front VM wants. Without a name match these are all VMs of the front
// app, and every one must agree (either may be the one in front), so a VM that
// does not use a feature never loses macOS's own handling to it.
static int wants(int glide) {
  int any = 0, all = 1;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || !clients[i].target) continue;
    any = 1;
    if (!(glide ? clients[i].glide && clients[i].gestures : clients[i].gestures)) all = 0;
  }
  pthread_mutex_unlock(&sendLock);
  return trackpad && any && all;
}
static int gesturesOn(void) { return frontNet >= 0 && wants(0); }
static int glideOn(void) { return frontNet >= 0 && wants(1); }

static void sendLine(const char *line, size_t len) { sendTo(0, line, len); }

// "on"/"esc" concern the front VM; "off" goes to every VM.
static void sendState(const char *s) {
  char b[16]; int n = snprintf(b, sizeof b, "S %s\n", s);
  sendTo(!strcmp(s, "off"), b, (size_t)n);
}

// ---- touch forwarding ----
static int forwarding;          // last frame sent to the guest had fingers
static int pinchArmed, pinch;   // 2-finger gesture tracking
static float d0, cx0, cy0;

static int touching(const MTTouch *t) { return t->state >= 1 && t->state <= 5 && t->zTotal > 0.0f; }

static int frameCb(MTDeviceRef dev, MTTouch *touches, int n, double ts, int frame) {
  (void)dev; (void)ts; (void)frame;
  MTTouch *c[16]; int k = 0;
  for (int i = 0; i < n && k < 16; i++) if (touching(&touches[i])) c[k++] = &touches[i];

  int send = 0;
  if (k != 2) pinchSent = 0;
  fingers = k;
  if (rec && k > 0) {
    float sx = 0, sy = 0;
    for (int i = 0; i < k; i++) { sx += c[i]->normalized.pos.x; sy += 1.0f - c[i]->normalized.pos.y; }
    fprintf(rec, "F\t%.4f\t%d\t%.5f\t%.5f\t%d\n", unixNow(), k, sx / k, sy / k, capturing);
  }
  if (capturing && gesturesOn()) {
    if (k >= 3 || (k == 2 && glideOn())) send = 1;
    else if (k == 2) {
      float dx = c[0]->normalized.pos.x - c[1]->normalized.pos.x, dy = c[0]->normalized.pos.y - c[1]->normalized.pos.y;
      float d = sqrtf(dx * dx + dy * dy);
      float cx = (c[0]->normalized.pos.x + c[1]->normalized.pos.x) / 2, cy = (c[0]->normalized.pos.y + c[1]->normalized.pos.y) / 2;
      if (!pinchArmed) { pinchArmed = 1; pinch = 0; d0 = d; cx0 = cx; cy0 = cy; }
      if (!pinch) {
        float spread = fabsf(d - d0), move = hypotf(cx - cx0, cy - cy0);
        if (spread > PINCH_SPREAD && spread > move * PINCH_RATIO) { pinch = 1; if (verbose) logf_("pinch"); }
      }
      send = pinch;
    }
  }
  if (k != 2) pinchArmed = 0;

  if (send) {
    char buf[1024]; int len = snprintf(buf, sizeof buf, "F %d", k);
    for (int i = 0; i < k && len < (int)sizeof buf - 64; i++)
      len += snprintf(buf + len, sizeof buf - (size_t)len, " %d %.5f %.5f %.3f", c[i]->pathIndex,
                      c[i]->normalized.pos.x, 1.0f - c[i]->normalized.pos.y, c[i]->zTotal);
    buf[len++] = '\n';
    sendLine(buf, (size_t)len);
    forwarding = 1;
  } else if (forwarding) {
    sendLine("F 0\n", 4);   // gesture over (fingers lifted below the threshold, or capture ended)
    forwarding = 0;
  }
  return 0;
}

// ---- capture mode: frontmost app + full-screen VM window ----
static int vmFullScreen(pid_t pid, CGWindowID *win) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  CGDirectDisplayID ds[16]; uint32_t nd = 0; CGGetActiveDisplayList(16, ds, &nd);
  int found = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && !found; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; CGRect r;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner != pid || layer != 0) continue;
    if (!CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r)) continue;
    for (uint32_t d = 0; d < nd; d++) {
      CGRect b = CGDisplayBounds(ds[d]);
      // Parallels' full-screen window spans the display width and sits below the
      // menu bar / notch strip, so allow a gap at the top.
      if (fabs(r.size.width - b.size.width) < 2 && r.size.height >= b.size.height - 80 &&
          fabs(r.origin.x - b.origin.x) < 2) { found = 1; break; }
    }
    if (found) CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, win);
  }
  CFRelease(wins);
  return found;
}

// The app's front window on the current Space (the list is front to back), 0
// for none (Finder with only the desktop).
static CGWindowID frontWindow(pid_t pid) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  CGWindowID found = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && !found; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner == pid && layer == 0) CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, &found);
  }
  CFRelease(wins);
  return found;
}

// The capture check runs every 0.2 s while a VM app is in front (to see its
// window go full screen), else every 2 s plus on every app switch. The pointer
// check runs only while a full-screen VM is in front: at 120 Hz while the
// pointer moves, at 20 Hz once it has rested a second (an idle desktop then
// costs 20 wake-ups a second here, not 120).
#define CURSOR_REST_AFTER 1.0
#define CURSOR_REST_EVERY 0.05
static CFRunLoopTimerRef captureTimer, cursorTimer;
static void updateCursor(CFRunLoopTimerRef t, void *info);

static void cursorTimerOn(int on) {
  static int running = -1;
  if (!cursorTimer || on == running) return;
  running = on;
  if (!on) updateCursor(NULL, NULL);   // shows the pointer again
  CFRunLoopTimerSetNextFireDate(cursorTimer, CFAbsoluteTimeGetCurrent() + (on ? 0 : 1e9));
}

// The title of the VM app's focused window (its main window when none has
// focus), through Accessibility, which this helper has for its event tap
// anyway; the window list would need Screen Recording for window names.
static void windowTitle(pid_t pid, char *out, size_t cap) {
  static AXUIElementRef app; static pid_t appPid;
  out[0] = 0;
  if (pid != appPid || !app) {
    if (app) CFRelease(app);
    app = AXUIElementCreateApplication(pid); appPid = pid;
    if (app) AXUIElementSetMessagingTimeout(app, 0.1f);   // a hung VM app must not stall the event tap
  }
  if (!app) return;
  CFTypeRef win = NULL, title = NULL;
  if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &win) != kAXErrorSuccess || !win)
    if (AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute, &win) != kAXErrorSuccess) win = NULL;
  if (win && AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &title) == kAXErrorSuccess && title &&
      CFGetTypeID(title) == CFStringGetTypeID())
    CFStringGetCString(title, out, (CFIndex)cap, kCFStringEncodingUTF8);
  if (title) CFRelease(title);
  if (win) CFRelease(win);
}

// ---- the event tap: created again when a VM app starts after us ----
// A new event tap goes to the head of the HID chain. QEMU's own one (OmacVM.app,
// full grab) is created when the VM starts and then sits ahead of ours: it
// sends the escape combo to the guest and returns nothing, so we never saw it
// after OmacVM.app was restarted (brianmerchant, PR #39). So the tap is
// created again whenever a different OmacVM VM comes to the front full screen,
// and when macOS has invalidated it. The new tap goes in before the old one
// is removed: no gap without one.
static int installTap(void) {
  CFMachPortRef newTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, tapMask, tapCb, NULL);
  if (!newTap) return 0;
  CFRunLoopSourceRef newSource = CFMachPortCreateRunLoopSource(NULL, newTap, 0);
  if (!newSource) { CFMachPortInvalidate(newTap); CFRelease(newTap); return 0; }
  CFRunLoopRef loop = CFRunLoopGetMain();
  CFRunLoopAddSource(loop, newSource, kCFRunLoopCommonModes);
  if (tapSource) {
    CFRunLoopRemoveSource(loop, tapSource, kCFRunLoopCommonModes);
    CFRunLoopSourceInvalidate(tapSource);
    CFRelease(tapSource);
  }
  if (tapPort) { CFMachPortInvalidate(tapPort); CFRelease(tapPort); }
  tapPort = newTap;
  tapSource = newSource;
  return 1;
}

// Main thread only. A failure (permission taken away) keeps the old tap and
// is logged once until a re-creation works again.
static void rearmTap(const char *why) {
  static int failedLogged;
  if (installTap()) {
    logf_("event tap created again (%s)", why);
    failedLogged = 0;
  } else if (!failedLogged) {
    logf_("cannot create the event tap again (%s): Accessibility or Input Monitoring taken away? Keeping the old one", why);
    failedLogged = 1;
  }
}

// What the capture check found (updateCapture, below): the front app's pid,
// its VM network (-1: not a VM app), whether its VM window covers a display,
// that window's title, the window, and whether the app is one the escape
// combo may go back to (other). Main thread.
static void frontChanged(pid_t pid, int net, int front, const char *title, CGWindowID win, int other) {
  // Each OmacVM VM is its own QEMU process with its own tap: a different pid
  // in front (frontPid is 0 while no VM is) may have put its tap ahead of ours.
  if (front && net == NET_APP && pid != frontPid) rearmTap("an OmacVM VM came to the front");
  if (front) {
    pthread_mutex_lock(&sendLock);
    if (net != frontNet || strcmp(title, frontTitle)) {
      frontNet = net;
      snprintf(frontTitle, sizeof frontTitle, "%s", title);
      retargetLocked(capturing);
    }
    pthread_mutex_unlock(&sendLock);
    vmPid = pid; vmWin = win;
  } else if (other) {
    otherPid = pid; otherWin = win;
  }
  appPid = pid;
  frontPid = front ? pid : 0;
  cursorTimerOn(front);
  if (!front && escaped) escaped = 0;   // re-arm once the VM is left
  frontIsVM = front;
  int now = front && !escaped;
  if (now != capturing) {
    capturing = now;
    logf_("capture %s", now ? "ON" : "off");
    if (rec) fprintf(rec, "C\t%.4f\t%d\n", unixNow(), now);
    sendState(now ? "on" : (front ? "esc" : "off"));
  }
  if (tapPort && !CFMachPortIsValid(tapPort)) rearmTap("macOS invalidated it");
  else if (tapPort && !CGEventTapIsEnabled(tapPort)) CGEventTapEnable(tapPort, true);
}

// Its two permissions, logged at start and whenever one changes (looked at
// every 10 s at most); omacvm check reads the last line. A missing one is
// named, not just "waiting".
static void logPermissions(void) {
  static int last = -1; static CFAbsoluteTime at;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (last >= 0 && now - at < 10) return;
  at = now;
  int ax = AXIsProcessTrusted() != 0, im = CGPreflightListenEventAccess() != 0;
  if ((ax | im << 1) == last) return;
  last = ax | im << 1;
  logf_("permissions: Accessibility %s, Input Monitoring %s", ax ? "granted" : "MISSING", im ? "granted" : "MISSING");
}

static void updateCapture(CFRunLoopTimerRef t, void *info) {
  (void)info;
  logPermissions();
  ProcessSerialNumber psn; pid_t pid = 0; char name[64] = "";
  if (GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr) proc_name(pid, name, sizeof name);
  // Parallels' VM window, UTM's, or VMware Fusion's.
  int net = !strcmp(name, "prl_client_app") ? 0 : !strcmp(name, "UTM") ? NET_UTM
          : !strcmp(name, "VMware Fusion") && listenAddrs[NET_FUSION][0] ? NET_FUSION
          : !strcmp(name, "OmacVM") ? NET_APP : -1;   // OmacVM.app's QEMU
  CGWindowID win = 0;
  int front = net >= 0 && vmFullScreen(pid, &win);
  // Which of the app's VMs: its window title, on this check (every 0.2 s
  // while a VM app is full screen in front) and on every app switch.
  char title[sizeof frontTitle] = "";
  if (front) windowTitle(pid, title, sizeof title);
  int other = isOther(pid, net, name, net < 0 && pid > 0 && ns_is_regular(pid));
  if (other) win = frontWindow(pid);
  frontChanged(pid, net, front, title, win, other);
  if (t) {
    // Every 0.2 s while a VM app is in front, else every 2 s; the slow look
    // may come up to 0.5 s late so macOS can batch it with other wake-ups.
    CFRunLoopTimerSetTolerance(t, net >= 0 ? 0.02 : 0.5);
    CFRunLoopTimerSetNextFireDate(t, CFAbsoluteTimeGetCurrent() + (net >= 0 ? 0.2 : 2.0));
  }
}

// ---- the macOS pointer over the full-screen VM ----
// Parallels and UTM only hide the macOS pointer over their window when it comes
// in from their own window; from the Omanotch strip or another app it can stay
// on top of the guest's pointer. So it is hidden here whenever the window under
// it is the front VM's full-screen window. A background process may only
// do that with the window server's "SetsCursorInBackground" (private, but
// stable for many macOS releases); without it this does nothing.
static int cursorHidden, cursorControl = -1;

static int enableCursorControl(void) {
  typedef int (*DefaultConnection)(void);
  typedef int (*SetProperty)(int, int, CFStringRef, CFTypeRef);
  DefaultConnection c = (DefaultConnection)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
  SetProperty set = (SetProperty)dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
  if (!c || !set) return 0;
  int cid = c();
  return set(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue) == 0;
}

static void setCursorHidden(int h) {
  if (h == cursorHidden) return;
  cursorHidden = h;
  if (h) CGDisplayHideCursor(kCGNullDirectDisplay); else CGDisplayShowCursor(kCGNullDirectDisplay);
}

// Whether the window a click at p would reach belongs to the front VM app and
// is a normal window. AppKit's hit test, not the window list: it skips
// click-through overlays that cover the whole screen (macOS's screenshot
// tool keeps one around for hours, Bartender has one over the menu bar).
typedef long (*WindowAtFn)(id, SEL, CGPoint, long);
static char hitOwner[64]; static int hitLayer;

static int vmWindowAt(CGPoint p, pid_t pid) {
  static Class nsWindow; static SEL windowAt;
  if (!nsWindow) {
    // AppKit needs its application object before it talks to the window server.
    ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    nsWindow = objc_getClass("NSWindow");
    windowAt = sel_registerName("windowNumberAtPoint:belowWindowWithWindowNumber:");
  }
  // AppKit's screen coordinates start at the primary display's bottom left.
  CGPoint q = { p.x, CGDisplayBounds(CGMainDisplayID()).size.height - p.y };
  long n = ((WindowAtFn)objc_msgSend)((id)nsWindow, windowAt, q, 0);
  hitOwner[0] = 0; hitLayer = -1;
  if (n <= 0) return 0;
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)n);
  if (!wins) return 0;
  int hit = 0;
  if (CFArrayGetCount(wins) > 0) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, 0);
    int owner = 0;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &hitLayer);
    CFStringRef name = CFDictionaryGetValue(w, kCGWindowOwnerName);
    if (name) CFStringGetCString(name, hitOwner, sizeof hitOwner, kCFStringEncodingUTF8);
    hit = owner == pid && hitLayer == 0;
    // Only a window that fills its display: the VM's full-screen window, not
    // another window of the same app (VMware Fusion's library, say).
    CGRect r;
    CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
    if (hit && b && CGRectMakeWithDictionaryRepresentation(b, &r)) {
      CGDirectDisplayID d; uint32_t nd = 0;
      CGGetDisplaysWithPoint(CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)), 1, &d, &nd);
      CGRect s = nd ? CGDisplayBounds(d) : CGRectNull;
      hit = nd && r.size.width >= s.size.width - 1 && r.size.height >= s.size.height - 80;
    }
  }
  CFRelease(wins);
  return hit;
}

static void updateCursor(CFRunLoopTimerRef t, void *info) {
  (void)t; (void)info;
  static CGPoint last = { -1, -1 };
  static CFAbsoluteTime lastCheck, lastMove;
  if (cursorControl < 0) {
    cursorControl = enableCursorControl();
    if (!cursorControl) logf_("cannot hide the macOS pointer from the background");
  }
  pid_t pid = frontPid;
  if (!cursorControl || !pid) { setCursorHidden(0); last.x = -1; return; }
  CGEventRef e = CGEventCreate(NULL);
  CGPoint p = CGEventGetLocation(e);
  CFRelease(e);
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  int moved = p.x != last.x || p.y != last.y;
  if (moved) lastMove = now;
  // At rest: the next look in 50 ms instead of 8 (the timer goes back to
  // 120 Hz by itself after the first look that sees it move).
  if (t && now - lastMove > CURSOR_REST_AFTER) CFRunLoopTimerSetNextFireDate(t, now + CURSOR_REST_EVERY);
  // The window list only when the pointer moved, and every half second for
  // windows that appear under a pointer at rest (the Dock, a notification).
  if (!moved && now - lastCheck < 0.5) return;
  last = p; lastCheck = now;
  int h = vmWindowAt(p, pid);
  if (verbose && h != cursorHidden)
    logf_("macOS pointer %s (over %s, layer %d)", h ? "hidden" : "shown", hitOwner[0] ? hitOwner : "nothing", hitLayer);
  setCursorHidden(h);
}

// ---- Cmd as Super on UTM ----
// UTM does not grab the keyboard (Omanotch needs a free pointer), so macOS keeps
// Cmd+Space, Cmd+Tab & co. While a UTM VM is full screen and capturing, every
// Cmd+key goes to the guest daemon instead, which types it as Super+key on a
// virtual keyboard: "K <linux keycode> <0 up|1 down|2 repeat>". Parallels has
// its own setting for this ("Send macOS system shortcuts: Always").
static unsigned short macToLinux[128];
static unsigned char forwarded[128];

static void initKeymap(void) {
  // Physical keys (kVK_* -> KEY_*); the guest's own layout gives them meaning.
  static const unsigned short pairs[][2] = {
    {0,30},{1,31},{2,32},{3,33},{4,35},{5,34},{6,44},{7,45},{8,46},{9,47},{11,48},{12,16},{13,17},{14,18},
    {15,19},{16,21},{17,20},{18,2},{19,3},{20,4},{21,5},{22,7},{23,6},{24,13},{25,10},{26,8},{27,12},{28,9},
    {29,11},{30,27},{31,24},{32,22},{33,26},{34,23},{35,25},{36,28},{37,38},{38,36},{39,40},{40,37},{41,39},
    {42,43},{43,51},{44,53},{45,49},{46,50},{47,52},{48,15},{49,57},{51,14},{53,1},{76,96},
    {96,63},{97,64},{98,65},{99,61},{100,66},{101,67},{103,87},{109,68},{111,88},{118,62},{120,60},{122,59},
    {115,102},{116,104},{117,111},{119,107},{121,109},{123,105},{124,106},{125,108},{126,103}};
  for (size_t i = 0; i < sizeof pairs / sizeof *pairs; i++) macToLinux[pairs[i][0]] = pairs[i][1];
  // The key left of 1 and the extra key beside left Shift swap places on ISO keyboards.
  int iso = KBGetLayoutType(LMGetKbdType()) == kKeyboardISO;
  macToLinux[10] = iso ? 41 : 86;   // kVK_ISO_Section
  macToLinux[50] = iso ? 86 : 41;   // kVK_ANSI_Grave
}

static void sendKey(int code, int val) {
  char b[24]; int n = snprintf(b, sizeof b, "K %d %d\n", code, val); sendLine(b, (size_t)n);
}

static void forwardKey(int kc, CGEventFlags f, int val) {
  if (val == 1) {
    sendKey(125, 1);                                         // Super
    if (f & kCGEventFlagMaskShift) sendKey(42, 1);
    if (f & kCGEventFlagMaskControl) sendKey(29, 1);
    if (f & kCGEventFlagMaskAlternate) sendKey(56, 1);
  }
  sendKey(macToLinux[kc], val);
  if (val == 0) { sendKey(56, 0); sendKey(29, 0); sendKey(42, 0); sendKey(125, 0); }
}

// ---- the escape combo: swipe the monitor under the pointer, and back ----
// Ctrl+Option+Cmd+Esc in the captured full-screen VM hands the trackpad and
// keys back to macOS at once ("S esc", Omarchy lets go of held keys). Then
// the display under the pointer swipes to the Space beside the VM's, with
// macOS's own animation (a Dock swipe, as three or four fingers make it): only
// that display changes, and the keyboard goes to what it shows. Pressed again
// there in macOS, it swipes back to the VM. The setting "EscapeSwipe" = "all"
// (OmacVM.app's "Escape combo", or defaults write org.omacvm.gestures
// EscapeSwipe all) swipes every display that shows the VM instead.
// Never a trap: no swipe possible (no Spaces information, the VM's Space has
// no neighbour), or the Space did not change -> the app from before comes to
// the front instead (its Space, RC8's switch); refused too -> the VM's app is
// hidden, so macOS has the keyboard whatever happens.
enum { COMBO_PASS, COMBO_LEAVE, COMBO_CAPTURE, COMBO_ENTER };

// haveVM: a full-screen VM to go back to, and its app is not the one in front
// (a VM in a window keeps the combo, as before).
static int comboAction(int vmFront, int esc, int haveVM) {
  if (vmFront) return esc ? COMBO_CAPTURE : COMBO_LEAVE;
  return haveVM ? COMBO_ENTER : COMBO_PASS;
}

static int alive(pid_t p) { return p > 0 && (kill(p, 0) == 0 || errno == EPERM); }

// An app the combo may go back to: no VM app, not this helper, not the lock
// screen, and a regular app (Raycast, Alfred, Spotlight or a password
// manager's panel are in front only for a moment and show no window).
static int isOther(pid_t pid, int net, const char *name, int regular) {
  return net < 0 && pid > 0 && pid != getpid() && strcmp(name, "loginwindow") && regular;
}

// The app in front now (the capture check's way of asking).
static pid_t frontNow(void) {
  ProcessSerialNumber psn; pid_t pid = 0;
  return GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr ? pid : 0;
}

// This window still exists and belongs to pid: a VM app (Parallels, UTM,
// Fusion) outlives its VM, and a pid may be used again.
static int windowAlive(pid_t pid, CGWindowID win) {
  if (!win) return 0;
  CFArrayRef w = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, win);
  int ok = 0;
  if (w && CFArrayGetCount(w) > 0) {
    int owner = 0;
    CFNumberGetValue(CFDictionaryGetValue(CFArrayGetValueAtIndex(w, 0), kCGWindowOwnerPID), kCFNumberIntType, &owner);
    ok = owner == pid;
  }
  if (w) CFRelease(w);
  return ok;
}

// Brings the app with this window to the front. The window server's own call
// (SkyLight, private; window managers use it) works from a background helper
// and across Spaces; NSRunningApplication's activate is the fallback, and
// the way for an app without a known window.
typedef CGError (*SetFrontFn)(ProcessSerialNumber *, uint32_t, uint32_t);
static int bringToFront(pid_t pid, CGWindowID win) {
  static SetFrontFn setFront; static int looked;
  if (!looked) {
    looked = 1;
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    setFront = (SetFrontFn)dlsym(RTLD_DEFAULT, "_SLPSSetFrontProcessWithOptions");
    if (!setFront) logf_("escape combo: no SkyLight front-window call, using NSRunningApplication");
  }
  ProcessSerialNumber psn;
  if (win && setFront && GetProcessForPID(pid, &psn) == noErr && setFront(&psn, win, 0x200 /* user generated */) == kCGErrorSuccess)
    return 1;
  return ns_activate(pid);
}

// ---- Spaces (SkyLight, private; looked up at run time) ----
#define MAX_SPACES 32
#define MAX_DISPLAYS 16
typedef struct {
  CGDirectDisplayID id;
  CGRect bounds;
  uint64_t spaces[MAX_SPACES];   // left to right
  int n;
  uint64_t current;
} DisplaySpaces;

typedef int (*ConnFn)(void);
typedef CFArrayRef (*CopyDisplaySpacesFn)(int);
typedef CFArrayRef (*CopySpacesForWindowsFn)(int, int, CFArrayRef);
typedef CFUUIDRef (*DisplayUUIDFn)(CGDirectDisplayID);
static ConnFn cgsConn;
static CopyDisplaySpacesFn cgsDisplaySpaces;
static CopySpacesForWindowsFn cgsWindowSpaces;
static DisplayUUIDFn displayUUID;

static int lookUpSpaces(void) {
  static int looked;
  if (!looked) {
    looked = 1;
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    cgsConn = (ConnFn)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
    cgsDisplaySpaces = (CopyDisplaySpacesFn)dlsym(RTLD_DEFAULT, "CGSCopyManagedDisplaySpaces");
    cgsWindowSpaces = (CopySpacesForWindowsFn)dlsym(RTLD_DEFAULT, "CGSCopySpacesForWindows");
    displayUUID = (DisplayUUIDFn)dlsym(RTLD_DEFAULT, "CGDisplayCreateUUIDFromDisplayID");
    if (!cgsConn || !cgsDisplaySpaces || !displayUUID)
      logf_("escape combo: macOS gives no Spaces information here: the combo switches apps instead of swiping");
  }
  return cgsConn && cgsDisplaySpaces && displayUUID;
}

static uint64_t spaceID(CFDictionaryRef s) {
  int64_t v = 0;
  CFNumberRef n = s ? CFDictionaryGetValue(s, CFSTR("ManagedSpaceID")) : NULL;
  if (!n || CFGetTypeID(n) != CFNumberGetTypeID()) n = s ? CFDictionaryGetValue(s, CFSTR("id64")) : NULL;
  if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberSInt64Type, &v);
  return v > 0 ? (uint64_t)v : 0;
}

// Every active display with its Spaces, as macOS lists them (with "Displays
// have separate Spaces" off, one list ("Main") for all). 0: not known.
static int readSpaces(DisplaySpaces *out, int cap) {
  if (!lookUpSpaces()) return 0;
  CFArrayRef list = cgsDisplaySpaces(cgsConn());
  if (!list) return 0;
  CGDirectDisplayID ids[MAX_DISPLAYS]; uint32_t nd = 0;
  CGGetActiveDisplayList(MAX_DISPLAYS, ids, &nd);
  int k = 0;
  for (uint32_t i = 0; i < nd && k < cap; i++) {
    char uuid[64] = "";
    CFUUIDRef u = displayUUID(ids[i]);
    if (u) {
      CFStringRef s = CFUUIDCreateString(NULL, u);
      if (s) { CFStringGetCString(s, uuid, sizeof uuid, kCFStringEncodingUTF8); CFRelease(s); }
      CFRelease(u);
    }
    CFDictionaryRef entry = NULL;
    for (CFIndex j = 0; j < CFArrayGetCount(list) && !entry; j++) {
      CFDictionaryRef e = CFArrayGetValueAtIndex(list, j);
      CFStringRef d = CFGetTypeID(e) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(e, CFSTR("Display Identifier")) : NULL;
      char name[64] = "";
      if (d && CFGetTypeID(d) == CFStringGetTypeID()) CFStringGetCString(d, name, sizeof name, kCFStringEncodingUTF8);
      if ((uuid[0] && !strcasecmp(name, uuid)) || (!strcmp(name, "Main") && CFArrayGetCount(list) == 1)) entry = e;
    }
    if (!entry) continue;
    DisplaySpaces *d = &out[k];
    memset(d, 0, sizeof *d);
    d->id = ids[i];
    d->bounds = CGDisplayBounds(ids[i]);
    d->current = spaceID(CFDictionaryGetValue(entry, CFSTR("Current Space")));
    CFArrayRef sp = CFDictionaryGetValue(entry, CFSTR("Spaces"));
    if (sp && CFGetTypeID(sp) == CFArrayGetTypeID())
      for (CFIndex j = 0; j < CFArrayGetCount(sp) && d->n < MAX_SPACES; j++) {
        uint64_t id = spaceID(CFArrayGetValueAtIndex(sp, j));
        if (id) d->spaces[d->n++] = id;
      }
    if (d->n && d->current) k++;
  }
  CFRelease(list);
  return k;
}

// The Space a window is on; 0: not known.
static uint64_t readWindowSpace(CGWindowID win) {
  if (!win || !lookUpSpaces() || !cgsWindowSpaces) return 0;
  int32_t w = (int32_t)win;
  CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &w);
  CFArrayRef ws = CFArrayCreate(NULL, (const void **)&n, 1, &kCFTypeArrayCallBacks);
  CFRelease(n);
  CFArrayRef r = cgsWindowSpaces(cgsConn(), 7 /* all Spaces */, ws);
  CFRelease(ws);
  int64_t v = 0;
  if (r && CFArrayGetCount(r) > 0) CFNumberGetValue(CFArrayGetValueAtIndex(r, 0), kCFNumberSInt64Type, &v);
  if (r) CFRelease(r);
  return v > 0 ? (uint64_t)v : 0;
}

static int spaceIndex(const DisplaySpaces *d, uint64_t id) {
  for (int i = 0; i < d->n; i++) if (d->spaces[i] == id) return i;
  return -1;
}

// Out of the VM's Space: to the one on its left (where macOS puts the Space a
// window went full screen from), else the one on its right. 0: no neighbour.
static int stepOut(const DisplaySpaces *d) {
  int i = spaceIndex(d, d->current);
  if (i < 0) return 0;
  return i > 0 ? -1 : i + 1 < d->n ? 1 : 0;
}

// One swipe toward `want`: only when it is right beside the current Space
// (+1 right, -1 left); farther away or gone: 0 (then the app switch).
static int stepToward(const DisplaySpaces *d, uint64_t want) {
  int i = spaceIndex(d, d->current), j = spaceIndex(d, want);
  return i < 0 || j < 0 || (j - i != 1 && i - j != 1) ? 0 : j - i;
}

// ---- the swipe: a Dock swipe, the events a three/four-finger swipe makes ----
#define kCGSEventTypeField 55
#define kCGEventGestureHIDType 110
#define kCGEventGestureScrollY 119
#define kCGEventGestureSwipeMotion 123
#define kCGEventGestureSwipeProgress 124
#define kCGEventGestureSwipeVelocityX 129
#define kCGEventGestureSwipeVelocityY 130
#define kCGEventGesturePhase 132
#define kCGEventScrollGestureFlagBits 135
#define kCGEventGestureZoomDeltaX 139
#define kIOHIDEventTypeDockSwipe 23
#define kCGSEventGesture 29
#define kCGSEventDockControl 30
#define kSwipeBegan 1
#define kSwipeEnded 4

// Which sign of the swipe's progress goes to the Space on the right. Not
// documented: a swipe seen going the other way flips it (learnSign), kept in
// the settings domain for the next start.
static int swipeSign = 1;
#define GESTURES_DOMAIN CFSTR("org.omacvm.gestures")

static int dockSwipe(CGPoint at, int phase, int right) {
  CGEventRef dock = CGEventCreate(NULL), gesture = CGEventCreate(NULL);
  if (!dock || !gesture) {
    if (dock) CFRelease(dock);
    if (gesture) CFRelease(gesture);
    return 0;
  }
  double s = right ? -1.0 : 1.0;   // fingers to the left reveal the Space on the right
  CGEventSetIntegerValueField(gesture, kCGSEventTypeField, kCGSEventGesture);
  CGEventSetIntegerValueField(dock, kCGSEventTypeField, kCGSEventDockControl);
  CGEventSetIntegerValueField(dock, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
  CGEventSetIntegerValueField(dock, kCGEventGesturePhase, phase);
  CGEventSetIntegerValueField(dock, kCGEventScrollGestureFlagBits, right ? 1 : 0);
  CGEventSetIntegerValueField(dock, kCGEventGestureSwipeMotion, 1);   // horizontal
  CGEventSetDoubleValueField(dock, kCGEventGestureScrollY, 0);
  CGEventSetDoubleValueField(dock, kCGEventGestureZoomDeltaX, 1.401298464e-45);   // FLT_TRUE_MIN, as the trackpad sends
  if (phase == kSwipeEnded) {
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeProgress, s * 2.0);
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeVelocityX, s * 400.0);
    CGEventSetDoubleValueField(dock, kCGEventGestureSwipeVelocityY, 0);
  }
  CGEventSetLocation(dock, at);
  CGEventSetLocation(gesture, at);
  CGEventPost(kCGSessionEventTap, dock);
  CGEventPost(kCGSessionEventTap, gesture);
  CFRelease(dock); CFRelease(gesture);
  return 1;
}

static CGPoint pointerNow(void) {
  CGEventRef e = CGEventCreate(NULL);
  CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
  if (e) CFRelease(e);
  return p;
}

// One swipe on that display (dir +1: to the Space on the right). The Dock
// swipes the display the pointer is on; the events also carry it.
static int postSwipe(CGDirectDisplayID d, CGRect b, int dir) {
  (void)d;
  CGPoint p = pointerNow();
  CGPoint at = CGRectContainsPoint(b, p) ? p : CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
  int right = dir * swipeSign > 0;
  return dockSwipe(at, kSwipeBegan, right) && dockSwipe(at, kSwipeEnded, right);
}

// The on-screen windows of pid (layer 0), front to back, as rectangles.
static int windowsOf(pid_t pid, CGRect *out, int cap) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  int k = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && k < cap; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; CGRect r;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner == pid && layer == 0 && CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r) &&
        r.size.width > 100 && r.size.height > 100)
      out[k++] = r;
  }
  CFRelease(wins);
  return k;
}

// The front app on a display now: the owner of its topmost normal window that
// is not `skip`'s (the VM), with that window. 0: none (the desktop).
static pid_t topAppOn(CGRect b, pid_t skip, CGWindowID *win) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  pid_t found = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins) && !found; i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; CGRect r;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    if (owner == skip || owner == getpid() || layer != 0 ||
        !CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r) ||
        r.size.width <= 100 || r.size.height <= 100 || !CGRectContainsPoint(b, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r))))
      continue;
    found = owner;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, win);
  }
  CFRelease(wins);
  return found;
}

// "EscapeSwipe": "all" swipes every display that shows the VM, anything else
// (default) the display under the pointer only.
static int escapeAll(void) {
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
  CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("EscapeSwipe"), GESTURES_DOMAIN);
  int all = v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringCompare((CFStringRef)v, CFSTR("all"), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
  if (v) CFRelease(v);
  return all;
}

static void loadSwipeSign(void) {
  CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("SwipeSign"), GESTURES_DOMAIN);
  int s = 0;
  if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &s);
  if (v) CFRelease(v);
  if (s == -1) swipeSign = -1;
}

static void saveSwipeSign(void) {
  CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &swipeSign);
  CFPreferencesSetAppValue(CFSTR("SwipeSign"), n, GESTURES_DOMAIN);
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
  CFRelease(n);
}

// Seams for the offline test (test-escape.c): the window server is not asked.
static int (*activateFn)(pid_t, CGWindowID) = bringToFront;
static pid_t (*finderFn)(void) = ns_finder_pid;
static pid_t (*frontFn)(void) = frontNow;
static int (*vmWindowFn)(pid_t, CGWindowID) = windowAlive;
static int (*spacesFn)(DisplaySpaces *, int) = readSpaces;
static uint64_t (*windowSpaceFn)(CGWindowID) = readWindowSpace;
static int (*swipeFn)(CGDirectDisplayID, CGRect, int) = postSwipe;
static CGPoint (*pointerFn)(void) = pointerNow;
static int (*vmWindowsFn)(pid_t, CGRect *, int) = windowsOf;
static pid_t (*topAppFn)(CGRect, pid_t, CGWindowID *) = topAppOn;
static int (*hideFn)(pid_t) = ns_hide;
static int (*escapeAllFn)(void) = escapeAll;
static void (*saveSignFn)(void) = saveSwipeSign;
static double verifyAfter = 0.8;   // s: a swipe's animation is over by then

static void after(void (^f)(void)) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(verifyAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), f);
}

// The Space each display showed the VM on when the combo left it (pressing
// it again there swipes back to it), and the swipes of the last press.
static struct { CGDirectDisplayID id; uint64_t space; } left[MAX_DISPLAYS];
typedef struct { CGDirectDisplayID id; uint64_t from, to; int dir; } Swipe;
static Swipe swiped[MAX_DISPLAYS];
static int nSwiped;

static void rememberLeft(CGDirectDisplayID id, uint64_t space) {
  for (int i = 0; i < MAX_DISPLAYS; i++)
    if (left[i].id == id || !left[i].id) { left[i].id = id; left[i].space = space; return; }
}

static uint64_t leftOn(CGDirectDisplayID id) {
  for (int i = 0; i < MAX_DISPLAYS && left[i].id; i++) if (left[i].id == id) return left[i].space;
  return 0;
}

static const DisplaySpaces *displayIn(const DisplaySpaces *ds, int n, CGDirectDisplayID id) {
  for (int i = 0; i < n; i++) if (ds[i].id == id) return &ds[i];
  return NULL;
}

// Brings an app to the front; after a moment it must be there, else the usual
// activation once more. done(1) once it is in front, done(0) if not.
static void goTo(pid_t pid, CGWindowID win, const char *what, void (^done)(int)) {
  char name[64] = "";
  proc_name(pid, name, sizeof name);
  int ok = activateFn(pid, win);
  logf_("escape combo: %s %s (pid %d, window %u)%s", what, name, pid, win, ok ? "" : ": macOS refused, trying again");
  after(^{
    if (frontFn() == pid) { if (done) done(1); return; }
    int again = activateFn(pid, 0);
    after(^{
      char who[64] = "";
      proc_name(pid, who, sizeof who);
      int in = frontFn() == pid;
      logf_("escape combo: %s %s (second try %s)", who, in ? "is in front" : "did not come to the front", again ? "taken" : "refused");
      if (done) done(in);
    });
  });
}

// The last way out: the VM's app hidden, so it cannot keep the keyboard.
static void hideVM(void) {
  if (frontFn() != vmPid) return;
  char name[64] = "";
  proc_name(vmPid, name, sizeof name);
  int ok = hideFn(vmPid);
  logf_("escape combo: %s kept the front: hidden%s, macOS has the keyboard (the combo brings it back)", name, ok ? "" : " (refused!)");
}

// Out by switching apps (RC8): the app from before, else Finder; refused: hide.
static void leaveBySwitch(void) {
  pid_t to = alive(otherPid) ? otherPid : finderFn();
  CGWindowID w = to == otherPid ? otherWin : 0;
  if (to <= 0) { logf_("escape combo: no app to go back to"); hideVM(); return; }
  goTo(to, w, to == otherPid ? "back to" : "back to (the app from before has quit)", ^(int ok) { if (!ok) hideVM(); });
}

// After a swipe out: the keyboard follows the pointer's display. The VM may
// still be in front (its window on another display, or macOS kept it there):
// then the app on top of the pointer's display, else Finder.
static void focusPointerDisplay(void) {
  if (frontFn() != vmPid) return;
  CGPoint p = pointerFn();
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS);
  CGRect b = CGRectNull;
  for (int i = 0; i < nd; i++) if (CGRectContainsPoint(ds[i].bounds, p)) b = ds[i].bounds;
  CGWindowID w = 0;
  pid_t to = CGRectIsNull(b) ? 0 : topAppFn(b, vmPid, &w);
  if (to <= 0) { to = finderFn(); w = 0; }
  if (to <= 0) { hideVM(); return; }
  goTo(to, w, "keyboard to", ^(int ok) { if (!ok) hideVM(); });
}

// Did each swipe of the last press land? A Space that moved the other way
// teaches the sign (kept); none moved: the swipe does not work here.
static int swipesLanded(void) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), landed = 0;
  for (int i = 0; i < nSwiped; i++) {
    const DisplaySpaces *d = displayIn(ds, nd, swiped[i].id);
    if (!d) continue;
    if (d->current == swiped[i].to) { landed++; continue; }
    int from = spaceIndex(d, swiped[i].from), now = spaceIndex(d, d->current);
    if (from >= 0 && now == from - swiped[i].dir) {
      swipeSign = -swipeSign;
      saveSignFn();
      logf_("escape combo: the swipe went the other way: direction learned");
    }
  }
  return landed;
}

static void checkLeave(void) {
  if (!swipesLanded()) {
    logf_("escape combo: the Space did not change: switching apps instead");
    leaveBySwitch();
    return;
  }
  focusPointerDisplay();
}

static void checkEnter(void) {
  if (!swipesLanded()) {
    logf_("escape combo: the Space did not change: switching to the VM instead");
    goTo(vmPid, vmWin, "back into the VM:", NULL);
    return;
  }
  // The keyboard to the VM now on the pointer's display (a full-screen Space
  // usually brings its app; the notch's kind of full screen is a window).
  if (frontFn() != vmPid) goTo(vmPid, vmWin, "keyboard to the VM:", NULL);
}

static int swipe(const DisplaySpaces *d, int dir, uint64_t to, const char *what) {
  // "Displays have separate Spaces" off: one list for every display, swiped once.
  for (int i = 0; i < nSwiped; i++) if (swiped[i].from == d->current) return 0;
  if (!dir || nSwiped >= MAX_DISPLAYS || !swipeFn(d->id, d->bounds, dir)) return 0;
  swiped[nSwiped++] = (Swipe){ d->id, d->current, to, dir };
  logf_("escape combo: display %u swiped %s (%s)", d->id, dir > 0 ? "right" : "left", what);
  return 1;
}

static int showsVM(const DisplaySpaces *d, const CGRect *wins, int nw) {
  for (int i = 0; i < nw; i++)
    if (CGRectContainsPoint(d->bounds, CGPointMake(CGRectGetMidX(wins[i]), CGRectGetMidY(wins[i])))) return 1;
  return 0;
}

// Out of the VM: the pointer's display (or, with "all", each display that
// shows the VM) swipes to the Space beside the VM's.
static void leaveVM(void) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), all = escapeAllFn();
  CGRect wins[MAX_DISPLAYS]; int nw = vmWindowsFn(vmPid, wins, MAX_DISPLAYS);
  CGPoint p = pointerFn();
  nSwiped = 0;
  int pointerOnVM = 0;
  for (int i = 0; i < nd; i++) {
    const DisplaySpaces *d = &ds[i];
    int under = CGRectContainsPoint(d->bounds, p), vm = showsVM(d, wins, nw);
    pointerOnVM |= under && vm;
    if (!vm || !(all || under)) continue;
    int dir = stepOut(d);
    if (dir) { rememberLeft(d->id, d->current); swipe(d, dir, d->spaces[spaceIndex(d, d->current) + dir], "out of the VM"); }
  }
  if (nSwiped) { after(^{ checkLeave(); }); return; }
  // The pointer is on a display without the VM: nothing to swipe there, the
  // keyboard goes to what it shows.
  if (nd && nw && !pointerOnVM && !all) { focusPointerDisplay(); return; }
  logf_("escape combo: no swipe possible here (%s): switching apps", !nd ? "no Spaces information" : "the VM's Space has no neighbour");
  leaveBySwitch();
}

// Into the VM again: the pointer's display (or, with "all", each display the
// combo left) swipes back to the VM's Space when it is right beside it.
static void enterVM(void) {
  DisplaySpaces ds[MAX_DISPLAYS]; int nd = spacesFn(ds, MAX_DISPLAYS), all = escapeAllFn();
  CGPoint p = pointerFn();
  uint64_t vmSpace = windowSpaceFn(vmWin);
  nSwiped = 0;
  for (int i = 0; i < nd; i++) {
    const DisplaySpaces *d = &ds[i];
    if (!all && !CGRectContainsPoint(d->bounds, p)) continue;
    uint64_t want = leftOn(d->id);
    if (!want || spaceIndex(d, want) < 0) want = all ? 0 : vmSpace;
    if (want && d->current != want) swipe(d, stepToward(d, want), want, "back into the VM");
  }
  if (nSwiped) { after(^{ checkEnter(); }); return; }
  goTo(vmPid, vmWin, "back into the VM:", NULL);
}

// The switch runs after the tap's callback has returned (it talks to the
// window server; the callback must stay quick).
static void later(void (*f)(void)) { dispatch_async(dispatch_get_main_queue(), ^{ f(); }); }

// ---- event tap: drop macOS gestures while capturing; escape combo ----
static int swallowEscUp;

static CGEventRef tapCb(CGEventTapProxy p, CGEventType type, CGEventRef e, void *u) {
  (void)p; (void)u;
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(tapPort, true); return e;
  }
  if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
    int kc = (int)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    CGEventFlags f = CGEventGetFlags(e);
    int combo = (f & kCGEventFlagMaskControl) && (f & kCGEventFlagMaskAlternate) && (f & kCGEventFlagMaskCommand);
    if (kc == ESC_KEYCODE && type == kCGEventKeyUp && swallowEscUp) { swallowEscUp = 0; return NULL; }
    int act = kc == ESC_KEYCODE && combo
              ? comboAction(frontIsVM, escaped, alive(vmPid) && vmPid != appPid && vmWindowFn(vmPid, vmWin)) : COMBO_PASS;
    if (act == COMBO_PASS) {
      if (kc >= 0 && kc < 128 && macToLinux[kc]) {
        // UTM, VMware Fusion and OmacVM.app (without Accessibility for it) keep
        // Cmd shortcuts like Cmd+Space for macOS: in full screen they go to
        // Omarchy as Super, through the guest daemon.
        if (type == kCGEventKeyDown && capturing && (frontNet == NET_UTM || frontNet == NET_FUSION || frontNet == NET_APP) &&
            (f & kCGEventFlagMaskCommand) && haveClient()) {
          forwardKey(kc, f, CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat) ? 2 : 1);
          forwarded[kc] = 1;
          return NULL;
        }
        if (type == kCGEventKeyUp && forwarded[kc]) { forwarded[kc] = 0; forwardKey(kc, f, 0); return NULL; }
      }
      return e;
    }
    if (type == kCGEventKeyUp) return e;
    if (CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat)) return NULL;
    // Only the real keyboard: apps that post key events (VM apps among them)
    // must not hand the trackpad back to macOS.
    int64_t srcPid = CGEventGetIntegerValueField(e, kCGEventSourceUnixProcessID);
    int64_t srcState = CGEventGetIntegerValueField(e, kCGEventSourceStateID);
    if (srcState != kCGEventSourceStateHIDSystemState) {
      char who[64] = "";
      if (srcPid > 0) proc_name((pid_t)srcPid, who, sizeof who);
      logf_("escape combo ignored: posted by pid %lld (%s), state %lld", srcPid, who, srcState);
      return e;
    }
    if (act == COMBO_ENTER) {
      later(enterVM);
    } else {
      escaped = act == COMBO_LEAVE;
      capturing = !escaped;
      logf_("escape combo: capture %s", capturing ? "ON" : "off");
      sendState(capturing ? "on" : "esc");
      if (act == COMBO_LEAVE) later(leaveVM);
    }
    swallowEscUp = 1;
    return NULL;
  }
  if (type == kCGEventScrollWheel && rec)
    fprintf(rec, "S\t%.4f\t%lld\t%lld\t%.2f\t%.2f\t%lld\t%d\n", unixNow(),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventScrollPhase),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventMomentumPhase),
            CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis2),
            CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous), capturing);
  if (type == kCGEventScrollWheel) {
    // Glide: continuous (trackpad, Magic Mouse) scrolling, as macOS shaped it,
    // goes to the guest; a wheel mouse's discrete steps pass to the VM app.
    if (!(capturing && glideOn())) return e;
    if (!CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous)) return e;
    double dy = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1);
    double dx = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis2);
    if (dx != 0 || dy != 0) {
      // Fingers on the built-in trackpad: their raw frames carry this scroll;
      // the guest only learns from it how much macOS accelerates right now.
      int touch = fingers >= 2 && !CGEventGetIntegerValueField(e, kCGScrollWheelEventMomentumPhase);
      char b[64]; int n = snprintf(b, sizeof b, "%c %.2f %.2f\n", touch ? 'A' : 'W', dx, dy);
      sendLine(b, (size_t)n);
    }
    return NULL;
  }
  // macOS recognized a pinch (NSEventTypeMagnify): tell the guest, so its
  // two-finger touch passes raw fingers from now on.
  if (!pinchSent && capturing && glideOn() &&
      (type == 30 || (type == 29 && ns_event_type(e) == 30))) {
    sendLine("P\n", 2);
    pinchSent = 1;
    if (verbose) logf_("pinch (macOS)");
  }
  return capturing && gesturesOn() ? NULL : e;   // a gesture event type
}

// The VM's name from its hello: base64, so a name may hold spaces. Anything
// else gives no name.
static void base64Name(const char *in, char *out, size_t cap) {
  static const char abc[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  unsigned v = 0; int bits = 0; size_t n = 0;
  for (; *in && *in != '='; in++) {
    const char *p = strchr(abc, *in);
    if (!p) { n = 0; break; }
    v = (v << 6 | (unsigned)(p - abc)) & 0xffff; bits += 6;
    if (bits >= 8) { bits -= 8; if (n + 1 < cap) out[n++] = (char)(v >> bits & 0xff); }
  }
  out[n] = 0;
  for (size_t i = 0; i < n; i++) if ((unsigned char)out[i] < 32) { out[0] = 0; break; }   // no control characters (the log)
}

// ---- who may connect ----
// Any VM on these networks, and any Mac program on 127.0.0.1, can reach the
// listeners: a VM's daemon proves it knows the Bridge's token (header).

// The Bridge's token, or 0 when there is none.
static size_t readToken(char tok[160]) {
  char path[1024];
  tok[0] = 0;
  snprintf(path, sizeof path, "%s/Library/Application Support/omacvm-bridge/token", getenv("HOME"));
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  if (!fgets(tok, 160, f)) tok[0] = 0;
  fclose(f);
  tok[strcspn(tok, "\r\n")] = 0;
  size_t n = strlen(tok);
  return n >= 32 ? n : 0;
}

static int sameText(const char *a, const char *b) {   // constant time
  size_t n = strlen(a);
  if (strlen(b) != n) return 0;
  unsigned char diff = 0;
  for (size_t i = 0; i < n; i++) diff |= (unsigned char)(a[i] ^ b[i]);
  return diff == 0;
}

static int isHex(const char *s, size_t n) {
  if (strlen(s) != n) return 0;
  for (; *s; s++) if (!strchr("0123456789abcdef", *s)) return 0;
  return 1;
}

// HMAC-SHA256(token, "omacvm-gestures <who> <addr> <guest nonce> <mac nonce>") in hex.
static void proof(const char *tok, size_t tl, const char *who, const char *addr, const char *gn, const char *mn,
                  char out[65]) {
  char msg[160]; unsigned char d[CC_SHA256_DIGEST_LENGTH];
  int n = snprintf(msg, sizeof msg, "omacvm-gestures %s %s %s %s", who, addr, gn, mn);
  CCHmac(kCCHmacAlgSHA256, tok, tl, msg, (size_t)n, d);
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
}

// Daemons from before the handshake say the token itself.
static int bridgeTokenOK(const char *given) {
  char tok[160];
  int ok = readToken(tok) && sameText(tok, given);
  memset(tok, 0, sizeof tok);
  return ok;
}

// ---- server ----
// One line from the guest, up to a few reads (SO_RCVTIMEO each): the newline
// is cut off. -1: nothing came.
static ssize_t recvLine(int fd, char *buf, size_t cap) {
  size_t n = 0;
  for (int i = 0; i < 4 && n + 1 < cap; i++) {
    ssize_t r = recv(fd, buf + n, cap - 1 - n, 0);
    if (r <= 0) break;
    n += (size_t)r;
    char *nl = memchr(buf, '\n', n);
    if (nl) { *nl = 0; return nl - buf; }
  }
  buf[n] = 0;
  return n ? (ssize_t)n : -1;
}

static void addClient(int c, int net, const char *ip, int gestures, int glide, const char *name) {
  pthread_mutex_lock(&sendLock);
  int slot = -1;
  // The same VM reconnecting replaces its old connection. OmacVM.app's VMs
  // all come from 127.0.0.1 (QEMU's user network): there the name tells them
  // apart, or two running VMs would keep pushing each other out. An app VM
  // the app moved between its fast network and the user network comes back
  // from another address: its name tells it is the same VM (its old
  // connection may not have noticed yet that its path is gone).
  int loopback = !strncmp(ip, "127.", 4);
  for (int i = 0; i < MAX_CLIENTS; i++)
    if (clients[i].fd >= 0 &&
        ((!strcmp(clients[i].ip, ip) && (!loopback || !strcmp(clients[i].name, name))) ||
         (net == NET_APP && clients[i].net == NET_APP && name[0] && !strcmp(clients[i].name, name)))) {
      if (strcmp(clients[i].ip, ip)) logf_("guest %s now comes from %s: its old connection closed", clients[i].ip, ip);
      close(clients[i].fd); slot = i; break;
    }
  for (int i = 0; slot < 0 && i < MAX_CLIENTS; i++) if (clients[i].fd < 0) slot = i;
  if (slot < 0) { close(clients[0].fd); slot = 0; }   // full: drop the oldest slot
  clients[slot].fd = c; clients[slot].net = net;
  clients[slot].gestures = gestures != 0; clients[slot].glide = glide != 0;
  snprintf(clients[slot].ip, sizeof clients[slot].ip, "%s", ip);
  snprintf(clients[slot].name, sizeof clients[slot].name, "%s", name);
  logf_("guest connected: %s (gestures %s, scroll momentum %s%s%s%s%s)", ip, gestures ? "on" : "off",
        glide ? "on" : "off", name[0] ? ", VM \"" : "", name, name[0] ? "\"" : "",
        net == NET_APP && strncmp(ip, "127.", 4) ? ", OmacVM.app on its fast network" : "");
  retargetLocked(capturing);
  int front = clients[slot].target;
  pthread_mutex_unlock(&sendLock);
  const char *st = capturing && front ? "on\n" : "off\n";
  char b[96]; int n = snprintf(b, sizeof b, "S %s", st);
  send(c, b, (size_t)n, MSG_NOSIGNAL);
  // The Mac's scrolling direction and the trackpad's size, so the guest
  // scales finger movement for this Mac (OmacVM's tuning is relative to a
  // 156 x 96 mm trackpad with natural scrolling).
  CFPropertyListRef nat = CFPreferencesCopyAppValue(CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication);
  int natural = nat ? CFBooleanGetValue((CFBooleanRef)nat) : 1;
  if (nat) CFRelease(nat);
  n = snprintf(b, sizeof b, "O %d %d %d\n", natural, tpW, tpH);
  send(c, b, (size_t)n, MSG_NOSIGNAL);
}

// A guest whose path went away (OmacVM.app moved it to another network, a
// VM that was killed) is noticed in about KA_IDLE + KA_INTVL * KA_CNT seconds,
// not after TCP's minutes: the next send to it fails and drops it.
#define KA_IDLE 5
#define KA_INTVL 2
#define KA_CNT 3
static void keepalive(int c) {
  int on = 1, idle = KA_IDLE, intvl = KA_INTVL, cnt = KA_CNT;
  setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &on, sizeof on);
  setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof idle);
  setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof intvl);
  setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof cnt);
}

// Each connection's handshake runs in its own thread, so a peer that connects
// and says nothing holds up no one else; at most this many at once.
#define MAX_GREETING 64
static volatile int greeting;
struct greetArg { int fd, net; struct in_addr addr; };

static void *greet(void *arg) {
  struct greetArg g = *(struct greetArg *)arg; free(arg);
  int c = g.fd, gestures = 1, glide = 0, ok = 0;
  const char *addr = listenAddrs[g.net];
  char ip[32]; inet_ntop(AF_INET, &g.addr, ip, sizeof ip);
  char line[640], name64[360] = "", name[256];
  const char *why = "no token (omacvm update gives the VM a daemon that proves it)";
  struct timeval tv = { .tv_sec = 1 };
  setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  ssize_t n = recvLine(c, line, sizeof line);
  char gn[72] = "";
  if (n > 0 && line[0] == 'C' && sscanf(line + 1, "%71s", gn) == 1) {
    // This daemon's handshake (header): the Mac's proof first.
    char tok[160], mn[33], mine[65], want[65], got[72] = "", out[160];
    size_t tl = readToken(tok);
    why = !tl ? "no Bridge token on this Mac" : "wrong proof";
    // Both proofs name the address this came in on (the VM checks it is its own).
    struct sockaddr_in me; socklen_t ml = sizeof me; char at[INET_ADDRSTRLEN] = "";
    if (getsockname(c, (struct sockaddr *)&me, &ml) || !inet_ntop(AF_INET, &me.sin_addr, at, sizeof at)) tl = 0;
    if (tl && isHex(gn, 32)) {
      unsigned char r[16]; arc4random_buf(r, sizeof r);
      for (int i = 0; i < 16; i++) snprintf(mn + 2 * i, 3, "%02x", r[i]);
      proof(tok, tl, "mac", at, gn, mn, mine);
      int k = snprintf(out, sizeof out, "M %s %s\n", mn, mine);
      tv.tv_sec = 3; setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
      if (send(c, out, (size_t)k, MSG_NOSIGNAL) == k && recvLine(c, line, sizeof line) > 0 && line[0] == 'R' &&
          sscanf(line + 1, "%d %d %71s %359s", &gestures, &glide, got, name64) >= 3) {
        proof(tok, tl, "vm", at, gn, mn, want);
        ok = sameText(got, want);
      }
    }
    memset(tok, 0, sizeof tok);
  } else if (n > 0 && line[0] == 'H') {
    // Daemons from before the handshake say the token itself.
    char given[160] = "";
    sscanf(line + 1, "%d %d %159s %359s", &gestures, &glide, given, name64);
    if (given[0]) { why = "wrong token"; ok = bridgeTokenOK(given); }
  }
  if (ok) {
    base64Name(name64, name, sizeof name);
    // OmacVM.app's VMs on its fast network are the app's (its window in
    // front), whichever address they came in on.
    addClient(c, g.net == NET_APP_FAST ? NET_APP : g.net, ip, gestures, glide, name);
  } else {
    // A refused daemon tries again every 2 s; only the log line is throttled.
    // Keeping its socket open instead would not save anything: a daemon from
    // 2.3 or older then polls it every 2 ms. omacvm check tells the user.
    static char lastIp[32]; static time_t lastLog;
    pthread_mutex_lock(&sendLock);
    if (strcmp(lastIp, ip) || time(NULL) - lastLog >= 60) {
      logf_("refused %s on %s: %s", ip, addr, why);
      snprintf(lastIp, sizeof lastIp, "%s", ip); lastLog = time(NULL);
    }
    pthread_mutex_unlock(&sendLock);
    close(c);
  }
  __sync_fetch_and_sub(&greeting, 1);
  return NULL;
}

static void *serverThread(void *arg) {
  int net = (int)(intptr_t)arg, inUse = 0;
  const char *addr = listenAddrs[net];
  while (net == NET_FUSION && !addr[0]) { sleep(10); readFusionHost(); }
  for (;;) {
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT) };
    if (inet_pton(AF_INET, addr, &a.sin_addr) != 1 || a.sin_addr.s_addr == INADDR_ANY) {
      close(s); logf_("not listening on '%s': not an address", addr); return NULL;   // never 0.0.0.0
    }
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 16) < 0) {
      // That VM network is not up (yet); another program on the port is worth a line.
      if (errno == EADDRINUSE && !inUse) { logf_("%s:%d is taken by another program; trying again", addr, PORT); inUse = 1; }
      close(s); sleep(5); continue;
    }
    inUse = 0;
    logf_("listening on %s:%d", addr, PORT);
    for (;;) {
      struct sockaddr_in peer; socklen_t pl = sizeof peer;
      int c = accept(s, (struct sockaddr *)&peer, &pl);
      if (c < 0) break;
      setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
      keepalive(c);
      struct greetArg *g = malloc(sizeof *g);
      if (!g || __sync_add_and_fetch(&greeting, 1) > MAX_GREETING) {
        if (g) { __sync_fetch_and_sub(&greeting, 1); free(g); }
        close(c); continue;
      }
      g->fd = c; g->net = net; g->addr = peer.sin_addr;
      pthread_t th; pthread_attr_t at;
      pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
      if (pthread_create(&th, &at, greet, g)) { __sync_fetch_and_sub(&greeting, 1); free(g); close(c); }
      pthread_attr_destroy(&at);
    }
    close(s);
  }
  return NULL;
}

// ---- the trackpad: the built-in one, else an external Magic Trackpad ----
// MultitouchSupport lists every multi-touch surface, the Magic Mouse's too; a
// trackpad is told apart by its size (a Magic Trackpad is 160 x 115 mm, a Magic
// Mouse's surface well under 100 mm wide).
static int trackpadStarted;

static void startTrackpad(void) {
  CFArrayRef list = MTDeviceCreateList();
  MTDeviceRef pick = NULL; int pw = 0, ph = 0;
  for (int pass = 0; pass < 2 && !pick; pass++) {
    for (CFIndex i = 0; list && i < CFArrayGetCount(list) && !pick; i++) {
      MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
      int w = 0, h = 0;
      if (MTDeviceGetSensorSurfaceDimensions(d, &w, &h) != 0) w = h = 0;
      if (pass == 0 ? MTDeviceIsBuiltIn(d) : (!MTDeviceIsBuiltIn(d) && w >= 10000)) { pick = d; pw = w; ph = h; }
    }
  }
  if (!pick) return;
  if (pw > 0 && ph > 0) { tpW = pw; tpH = ph; }
  MTRegisterContactFrameCallback(pick, frameCb);
  MTDeviceStart(pick, 0);
  trackpadStarted = 1;
  logf_("trackpad: %s, %d x %d mm", MTDeviceIsBuiltIn(pick) ? "built-in" : "Magic Trackpad", tpW / 100, tpH / 100);
}

static void retryTrackpad(CFRunLoopTimerRef t, void *info) {
  (void)info;
  if (!trackpadStarted) startTrackpad();
  if (trackpadStarted) CFRunLoopTimerInvalidate(t);
}

static void appActivated(void) { updateCapture(captureTimer, NULL); }

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-v")) verbose = 1;
    else if (!strcmp(argv[i], "--keys-only")) trackpad = 0;
    else if (!strcmp(argv[i], "--record")) {
      char path[1024]; snprintf(path, sizeof path, "%s/Library/Logs/omacvm-input.tsv", getenv("HOME"));
      rec = fopen(path, "a");
      if (rec) setvbuf(rec, NULL, _IOLBF, 0);
    }
    // A wrong option is not worth a launchd restart loop: say it and go on.
    else logf_("unknown option %s, ignored", argv[i]);
  }
  signal(SIGPIPE, SIG_IGN);

  tapMask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventScrollWheel);
  int gestureTypes[] = { 18, 19, 20, 29, 30, 31, 32, 34 };   // rotate, begin/end, gesture, magnify, swipe, smart magnify, pressure
  for (size_t i = 0; i < sizeof gestureTypes / sizeof *gestureTypes; i++) tapMask |= (CGEventMask)1 << gestureTypes[i];
  // Needs Accessibility (to drop events) and Input Monitoring (to see the escape
  // combo). Ask once, then wait for the grant instead of exiting, so launchd
  // does not restart us into a loop of prompts.
  CFStringRef keys[] = { kAXTrustedCheckOptionPrompt }; CFTypeRef vals[] = { kCFBooleanTrue };
  CFDictionaryRef opts = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int asked = 0;
  while (!installTap()) {
    if (!asked) {
      logf_("waiting for Accessibility and Input Monitoring permission");
      logPermissions();   // which one is missing
      AXIsProcessTrustedWithOptions(opts);
      CGRequestListenEventAccess();
      asked = 1;
    }
    sleep(3);
  }
  CFRelease(opts);
  if (asked) logf_("permissions granted");
  logPermissions();

  // The trackpad only now, with the permissions granted and the run loop about
  // to run: opened while still waiting, its frames were never taken, and on a
  // MacBook that stalled the built-in keyboard and trackpad (one device) until
  // the user granted Accessibility, which they then could not click.
  if (trackpad) {
    startTrackpad();
    if (!trackpadStarted) {
      // A Mac without a built-in trackpad (Mac mini, iMac, Studio) and no
      // Magic Trackpad connected yet: keys only until one is (checked again
      // every 10 s), instead of exiting into a launchd restart loop.
      logf_("no trackpad found: keys only until a Magic Trackpad connects");
      CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 10, 10, 0, 0, retryTrackpad, NULL);
      CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopCommonModes);
    }
  }


  cursorTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e9, 1.0 / 120, 0, 0, updateCursor, NULL);
  CFRunLoopTimerSetTolerance(cursorTimer, 0.001);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), cursorTimer, kCFRunLoopCommonModes);
  captureTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 0.2, 0, 0, updateCapture, NULL);
  CFRunLoopTimerSetTolerance(captureTimer, 0.02);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), captureTimer, kCFRunLoopCommonModes);
  ns_on_app_activate(appActivated);

  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  initKeymap();
  loadSwipeSign();
  readFusionHost();
  for (size_t i = 0; i < sizeof listenAddrs / sizeof *listenAddrs; i++) {
    if (!listenAddrs[i][0] && i != NET_FUSION) continue;
    pthread_t th; pthread_create(&th, NULL, serverThread, (void *)(intptr_t)i);
  }
  logf_(trackpad ? "running (escape: Ctrl+Option+Cmd+Esc)" : "running, keys only: trackpad gestures stay with macOS");
  CFRunLoopRun();
  return 0;
}
