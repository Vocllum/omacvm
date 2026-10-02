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
//     own path (absolute pointer, native smooth scrolling).
// While the VM is full screen, the macOS pointer is hidden wherever the VM window
// is what lies under it (the guest draws its own pointer); over anything else
// (the Omanotch strip, the Dock, menus, another display) it shows.
// Ctrl+Option+Cmd+Esc toggles capture off/on; it re-arms by itself when
// Parallels becomes frontmost again. If this process dies, the event tap goes
// with it and macOS gets its gestures back.
// --scroll: two-finger scrolling goes to the guest too. While fingers touch the
// built-in trackpad, their raw positions do (every two-finger frame, precise to
// hundredths of a millimetre); after they lift, macOS's momentum goes as point
// deltas, "W <dx> <dy>", which the guest continues the touch with. macOS's own
// scroll events are not passed to Parallels then. Other continuous scrolling
// (Magic Mouse) goes as W deltas as a whole; a wheel mouse (discrete steps)
// still scrolls through Parallels; one-finger movement and clicks stay with
// Parallels.
// --keys-only (trackpad gestures turned off at setup): macOS keeps every
// gesture and nothing is sent from the trackpad; on UTM, Cmd still reaches the
// guest as Super (below).
//
// Protocol (TCP, the guest connects to the Mac on port 47830: 10.211.55.2 on
// Parallels, 192.168.64.1 on UTM), one line per message:
//   F <n> [<id> <x> <y> <size>]...   x/y 0..1 with y down, size >= 0
//   S <on|off|esc>                    capture state changes
//   W <dx> <dy>                       --scroll: macOS scroll deltas in points
//   P                                 --scroll: macOS recognized a pinch (magnify)
//   O <natural> <w> <h>               on connect: macOS's natural scrolling (1/0) and the
//                                     trackpad's size in 1/100 mm
//   A <dx> <dy>                       --scroll: macOS's scroll while the fingers touch
//                                     (points; the guest reads macOS's acceleration from it)
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <libproc.h>
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

#define PORT 47830
// The Mac's address on each VM network: Parallels' shared network, UTM's
// shared network (vmnet). One listener per address; never 0.0.0.0.
static const char *listenAddrs[] = { "10.211.55.2", "192.168.64.1" };
#define ESC_KEYCODE 53
#define PINCH_SPREAD 0.035f         // normalized change of finger distance that makes a pinch
#define PINCH_RATIO 1.3f            // ... and it must exceed the centroid movement by this much

static volatile int frontIsVM, escaped, capturing;
static pid_t frontPid;   // the full-screen VM app in front, else 0
// Every VM that runs the guest daemon stays connected (one per address);
// frames go only to VMs on the network of the frontmost VM app (0 = Parallels,
// 1 = UTM, the index into listenAddrs). One connection per VM used to mean
// two running VMs pushed each other off every two seconds.
#define MAX_CLIENTS 8
static struct { int fd, net; char ip[32]; } clients[MAX_CLIENTS];
static volatile int frontNet = -1;
static pthread_mutex_t sendLock = PTHREAD_MUTEX_INITIALIZER;
static CFMachPortRef tapPort;
static int verbose;
void ns_scroll_delta(CGEventRef e, double *dx, double *dy);   // scroll_ns.m
int ns_event_type(CGEventRef e);                               // scroll_ns.m
static int trackpad = 1;          // 0 with --keys-only
static int scroll2;               // 1 with --scroll
static int tpW = 15600, tpH = 9600;   // built-in trackpad, 1/100 mm
static FILE *rec;                 // --record: trackpad frames and macOS's scroll, for analysis
static double unixNow(void) { return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970; }
static volatile int fingers;      // contacts in the built-in trackpad's last frame
static volatile double lastTwo;   // when it last had two or more fingers
static int pinchSent;             // P sent for the current two-finger touch

static void logf_(const char *fmt, ...) {
  time_t t = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
  va_list ap; va_start(ap, fmt); printf("%s omacvm-gestures: ", ts); vprintf(fmt, ap); printf("\n"); va_end(ap);
  fflush(stdout);
}

// net < 0: every client.
static void sendTo(int net, const char *line, size_t len) {
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (clients[i].fd < 0 || (net >= 0 && clients[i].net != net)) continue;
    if (send(clients[i].fd, line, len, MSG_NOSIGNAL) < 0) {
      logf_("guest disconnected: %s", clients[i].ip);
      close(clients[i].fd); clients[i].fd = -1;
    }
  }
  pthread_mutex_unlock(&sendLock);
}

static int haveClient(int net) {
  int found = 0;
  pthread_mutex_lock(&sendLock);
  for (int i = 0; i < MAX_CLIENTS; i++) if (clients[i].fd >= 0 && clients[i].net == net) found = 1;
  pthread_mutex_unlock(&sendLock);
  return found;
}

static void sendLine(const char *line, size_t len) { sendTo(frontNet, line, len); }

// "on"/"esc" concern the frontmost VM; "off" goes to every VM.
static void sendState(const char *s) {
  char b[16]; int n = snprintf(b, sizeof b, "S %s\n", s);
  sendTo(strcmp(s, "off") ? frontNet : -1, b, (size_t)n);
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
  if (k >= 2) lastTwo = CFAbsoluteTimeGetCurrent();
  if (trackpad && capturing && haveClient(frontNet)) {
    if (k >= 3 || (k == 2 && scroll2)) send = 1;
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
static int vmFullScreen(pid_t pid) {
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
  }
  CFRelease(wins);
  return found;
}

static void updateCapture(CFRunLoopTimerRef t, void *info) {
  (void)t; (void)info;
  ProcessSerialNumber psn; pid_t pid = 0; char name[64] = "";
  if (GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr) proc_name(pid, name, sizeof name);
  // Parallels' VM window, or UTM's.
  int net = !strcmp(name, "prl_client_app") ? 0 : !strcmp(name, "UTM") ? 1 : -1;
  int front = net >= 0 && vmFullScreen(pid);
  if (front) frontNet = net;
  frontPid = front ? pid : 0;
  if (!front && escaped) escaped = 0;   // re-arm once the VM is left
  frontIsVM = front;
  int now = front && !escaped;
  if (now != capturing) {
    capturing = now;
    logf_("capture %s", now ? "ON" : "off");
    if (rec) fprintf(rec, "C\t%.4f\t%d\n", unixNow(), now);
    sendState(now ? "on" : (front ? "esc" : "off"));
  }
  if (tapPort && !CGEventTapIsEnabled(tapPort)) CGEventTapEnable(tapPort, true);
}

// ---- the macOS pointer over the full-screen VM ----
// Parallels and UTM only hide the macOS pointer over their window when it comes
// in from their own window; from the Omanotch strip or another app it can stay
// on top of the guest's pointer. So it is hidden here whenever the front VM's
// full-screen window is the top window under it. A background process may only
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

// Whether the front VM's full-screen window is the top window at p.
static int vmWindowAt(CGPoint p, pid_t pid) {
  CFArrayRef wins = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  if (!wins) return 0;
  int hit = 0;
  for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(wins, i);
    int owner = 0, layer = -1; double alpha = 1; CGRect r;
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &owner);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    CFNumberRef a = CFDictionaryGetValue(w, kCGWindowAlpha);
    if (a) CFNumberGetValue(a, kCFNumberDoubleType, &alpha);
    // Skip the window server's own overlays (cursor, screen shields) and invisible windows.
    if (layer < 0 || layer >= 1000 || alpha <= 0) continue;
    if (!CGRectMakeWithDictionaryRepresentation(CFDictionaryGetValue(w, kCGWindowBounds), &r) || !CGRectContainsPoint(r, p)) continue;
    hit = owner == pid && layer == 0;
    break;
  }
  CFRelease(wins);
  return hit;
}

static void updateCursor(CFRunLoopTimerRef t, void *info) {
  (void)t; (void)info;
  static CGPoint last = { -1, -1 };
  static CFAbsoluteTime lastCheck;
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
  // The window list only when the pointer moved, and every half second for
  // windows that appear under a pointer at rest (the Dock, a notification).
  if (p.x == last.x && p.y == last.y && now - lastCheck < 0.5) return;
  last = p; lastCheck = now;
  setCursorHidden(vmWindowAt(p, pid));
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
    if (kc != ESC_KEYCODE || !combo || !frontIsVM) {
      if (kc >= 0 && kc < 128 && macToLinux[kc]) {
        if (type == kCGEventKeyDown && capturing && frontNet == 1 && (f & kCGEventFlagMaskCommand)) {
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
    escaped = !escaped;
    capturing = frontIsVM && !escaped;
    logf_("escape combo: capture %s", capturing ? "ON" : "off");
    sendState(capturing ? "on" : "esc");
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
    // Continuous (trackpad, Magic Mouse) scrolling, as macOS shaped it, goes to
    // the guest; a wheel mouse's discrete steps pass to Parallels.
    if (!(scroll2 && trackpad && capturing && haveClient(frontNet))) return e;
    if (!CGEventGetIntegerValueField(e, kCGScrollWheelEventIsContinuous)) return e;
    // Fingers on the built-in trackpad: their raw frames carry this scroll; the
    // guest only learns from it how much macOS accelerates right now.
    if (fingers >= 2 && !CGEventGetIntegerValueField(e, kCGScrollWheelEventMomentumPhase)) {
      double ay = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1);
      double ax = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis2);
      if (ax != 0 || ay != 0) {
        char b[64]; int n = snprintf(b, sizeof b, "A %.2f %.2f\n", ax, ay);
        sendLine(b, (size_t)n);
      }
      return NULL;
    }
    double dy = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1);
    double dx = CGEventGetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis2);
    double nx = 0, ny = 0;
    if (verbose) ns_scroll_delta(e, &nx, &ny);
    if (verbose)
      logf_("scroll pt %.3f %.3f ns %.4f %.4f fixed %.4f %.4f phase %lld momentum %lld", dx, dy, nx, ny,
            CGEventGetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis2),
            CGEventGetDoubleValueField(e, kCGScrollWheelEventFixedPtDeltaAxis1),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventScrollPhase),
            CGEventGetIntegerValueField(e, kCGScrollWheelEventMomentumPhase));
    if (dx != 0 || dy != 0) {
      char b[64]; int n = snprintf(b, sizeof b, "W %.2f %.2f\n", dx, dy);
      sendLine(b, (size_t)n);
    }
    return NULL;
  }
  if (verbose && capturing && type != kCGEventScrollWheel) {
    static int lastType = -1; static double lastLog;
    double now = CFAbsoluteTimeGetCurrent();
    if ((int)type != lastType || now - lastLog > 0.5) {
      logf_("gesture event type %d, NSEvent type %d (fingers %d, pinchSent %d)", (int)type,
            ns_event_type(e), fingers, pinchSent);
      lastType = (int)type; lastLog = now;
    }
  }
  // macOS recognized a pinch (NSEventTypeMagnify): tell the guest, so its
  // two-finger touch passes raw fingers from now on.
  if ((type == 29 || type == 30) && scroll2 && capturing && trackpad && !pinchSent &&
      haveClient(frontNet) && ns_event_type(e) == 30) {
    sendLine("P\n", 2);
    pinchSent = 1;
    if (verbose) logf_("pinch (macOS)");
  }
  return capturing && trackpad ? NULL : e;   // a gesture event type
}

// ---- server: one guest connection at a time ----
static void *serverThread(void *arg) {
  int net = (int)(intptr_t)arg;
  const char *addr = listenAddrs[net];
  for (;;) {
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT) };
    inet_pton(AF_INET, addr, &a.sin_addr);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 2) < 0) {
      close(s); sleep(5); continue;   // that VM network is not up (yet)
    }
    logf_("listening on %s:%d", addr, PORT);
    for (;;) {
      struct sockaddr_in peer; socklen_t pl = sizeof peer;
      int c = accept(s, (struct sockaddr *)&peer, &pl);
      if (c < 0) break;
      setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
      char ip[32]; inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof ip);
      pthread_mutex_lock(&sendLock);
      int slot = -1;
      for (int i = 0; i < MAX_CLIENTS; i++)    // the same VM reconnecting replaces its old connection
        if (clients[i].fd >= 0 && !strcmp(clients[i].ip, ip)) { close(clients[i].fd); slot = i; break; }
      for (int i = 0; slot < 0 && i < MAX_CLIENTS; i++) if (clients[i].fd < 0) slot = i;
      if (slot < 0) { close(clients[0].fd); slot = 0; }   // full: drop the oldest slot
      clients[slot].fd = c; clients[slot].net = net;
      snprintf(clients[slot].ip, sizeof clients[slot].ip, "%s", ip);
      pthread_mutex_unlock(&sendLock);
      logf_("guest connected: %s", ip);
      const char *st = capturing && net == frontNet ? "on\n" : "off\n";
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
    close(s);
  }
  return NULL;
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "-v")) verbose = 1;
    else if (!strcmp(argv[i], "--keys-only")) trackpad = 0;
    else if (!strcmp(argv[i], "--scroll")) scroll2 = 1;
    else if (!strcmp(argv[i], "--record")) {
      char path[1024]; snprintf(path, sizeof path, "%s/Library/Logs/omacvm-input.tsv", getenv("HOME"));
      rec = fopen(path, "a");
      if (rec) setvbuf(rec, NULL, _IOLBF, 0);
    }
  }
  signal(SIGPIPE, SIG_IGN);

  CFArrayRef list = trackpad ? MTDeviceCreateList() : NULL;
  int started = 0;
  for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
    MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    if (!MTDeviceIsBuiltIn(d)) continue;   // built-in trackpad only
    { int w = 0, h = 0; if (MTDeviceGetSensorSurfaceDimensions(d, &w, &h) == 0 && w > 0 && h > 0) { tpW = w; tpH = h; } }
    MTRegisterContactFrameCallback(d, frameCb); MTDeviceStart(d, 0); started++;
  }
  if (trackpad && !started) { logf_("no built-in trackpad found"); return 1; }

  CGEventMask m = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventScrollWheel);
  int gestureTypes[] = { 18, 19, 20, 29, 30, 31, 32, 34 };   // rotate, begin/end, gesture, magnify, swipe, smart magnify, pressure
  for (size_t i = 0; i < sizeof gestureTypes / sizeof *gestureTypes; i++) m |= (CGEventMask)1 << gestureTypes[i];
  // Needs Accessibility (to drop events) and Input Monitoring (to see the escape
  // combo). Ask once, then wait for the grant instead of exiting, so launchd
  // does not restart us into a loop of prompts.
  CFStringRef keys[] = { kAXTrustedCheckOptionPrompt }; CFTypeRef vals[] = { kCFBooleanTrue };
  CFDictionaryRef opts = CFDictionaryCreate(NULL, (const void **)keys, (const void **)vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int asked = 0;
  while (!(tapPort = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, m, tapCb, NULL))) {
    if (!asked) {
      logf_("waiting for Accessibility and Input Monitoring permission");
      AXIsProcessTrustedWithOptions(opts);
      CGRequestListenEventAccess();
      asked = 1;
    }
    sleep(3);
  }
  CFRelease(opts);
  if (asked) logf_("permissions granted");
  CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(NULL, tapPort, 0), kCFRunLoopCommonModes);

  CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 0.2, 0, 0, updateCapture, NULL);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
  CFRunLoopTimerRef cursorTimer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 1.0 / 120, 0, 0, updateCursor, NULL);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), cursorTimer, kCFRunLoopCommonModes);

  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  initKeymap();
  for (size_t i = 0; i < sizeof listenAddrs / sizeof *listenAddrs; i++) {
    pthread_t th; pthread_create(&th, NULL, serverThread, (void *)(intptr_t)i);
  }
  logf_(!trackpad ? "running, keys only: trackpad gestures stay with macOS"
        : scroll2 ? "running with two-finger scrolling (escape: Ctrl+Option+Cmd+Esc)" : "running (escape: Ctrl+Option+Cmd+Esc)");
  CFRunLoopRun();
  return 0;
}
