// omacvm-gestures (Mac side): gives the Omarchy VM in Parallels the Mac trackpad's
// multi-finger gestures.
//
// While Parallels is the frontmost app and its VM window covers a whole display
// ("capture mode"):
//   * macOS trackpad gesture events (Spaces / Mission Control swipes, pinch,
//     rotate, smart zoom) are dropped by an event tap, so macOS reacts to none
//     of them;
//   * raw finger contacts from the built-in trackpad (MultitouchSupport) are
//     sent to the guest daemon, which replays them on a virtual touchpad:
//     every frame with 3+ fingers, and 2-finger frames once they are a pinch;
//   * one-finger movement, clicks and two-finger scrolling stay on Parallels'
//     own path (absolute pointer, native smooth scrolling).
// Ctrl+Option+Cmd+Esc toggles capture off/on; it re-arms by itself when
// Parallels becomes frontmost again. If this process dies, the event tap goes
// with it and macOS gets its gestures back.
//
// Protocol (TCP, guest connects to 10.211.55.2:47830), one line per message:
//   F <n> [<id> <x> <y> <size>]...   x/y 0..1 with y down, size >= 0
//   S <on|off|esc>                    capture state changes
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
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

#define PORT 47830
#define LISTEN_ADDR "10.211.55.2"   // Parallels shared network, host side
#define ESC_KEYCODE 53
#define PINCH_SPREAD 0.035f         // normalized change of finger distance that makes a pinch
#define PINCH_RATIO 1.3f            // ... and it must exceed the centroid movement by this much

static volatile int frontIsVM, escaped, capturing;
static int clientFd = -1;
static pthread_mutex_t sendLock = PTHREAD_MUTEX_INITIALIZER;
static CFMachPortRef tapPort;
static int verbose;

static void logf_(const char *fmt, ...) {
  time_t t = time(NULL); char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
  va_list ap; va_start(ap, fmt); printf("%s omacvm-gestures: ", ts); vprintf(fmt, ap); printf("\n"); va_end(ap);
  fflush(stdout);
}

static void sendLine(const char *line, size_t len) {
  pthread_mutex_lock(&sendLock);
  if (clientFd >= 0 && send(clientFd, line, len, MSG_NOSIGNAL) < 0) {
    logf_("guest disconnected");
    close(clientFd); clientFd = -1;
  }
  pthread_mutex_unlock(&sendLock);
}

static void sendState(const char *s) {
  char b[16]; int n = snprintf(b, sizeof b, "S %s\n", s); sendLine(b, (size_t)n);
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
  if (capturing && clientFd >= 0) {
    if (k >= 3) send = 1;
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
  int front = !strcmp(name, "prl_client_app") && vmFullScreen(pid);
  if (!front && escaped) escaped = 0;   // re-arm once the VM is left
  frontIsVM = front;
  int now = front && !escaped;
  if (now != capturing) {
    capturing = now;
    logf_("capture %s", now ? "ON" : "off");
    sendState(now ? "on" : (front ? "esc" : "off"));
  }
  if (tapPort && !CGEventTapIsEnabled(tapPort)) CGEventTapEnable(tapPort, true);
}

// ---- event tap: drop macOS gestures while capturing; escape combo ----
static int swallowEscUp;

static CGEventRef tapCb(CGEventTapProxy p, CGEventType type, CGEventRef e, void *u) {
  (void)p; (void)u;
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(tapPort, true); return e;
  }
  if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
    if (CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode) != ESC_KEYCODE) return e;
    CGEventFlags f = CGEventGetFlags(e);
    int combo = (f & kCGEventFlagMaskControl) && (f & kCGEventFlagMaskAlternate) && (f & kCGEventFlagMaskCommand);
    if (type == kCGEventKeyUp) { if (swallowEscUp) { swallowEscUp = 0; return NULL; } return e; }
    if (!combo || !frontIsVM) return e;
    if (CGEventGetIntegerValueField(e, kCGKeyboardEventAutorepeat)) return NULL;
    escaped = !escaped;
    capturing = frontIsVM && !escaped;
    logf_("escape combo: capture %s", capturing ? "ON" : "off");
    sendState(capturing ? "on" : "esc");
    swallowEscUp = 1;
    return NULL;
  }
  return capturing ? NULL : e;   // a gesture event type
}

// ---- server: one guest connection at a time ----
static void *serverThread(void *arg) {
  (void)arg;
  for (;;) {
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT) };
    inet_pton(AF_INET, LISTEN_ADDR, &a.sin_addr);
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0 || listen(s, 2) < 0) {
      close(s); sleep(5); continue;   // Parallels' network not up yet
    }
    logf_("listening on %s:%d", LISTEN_ADDR, PORT);
    for (;;) {
      struct sockaddr_in peer; socklen_t pl = sizeof peer;
      int c = accept(s, (struct sockaddr *)&peer, &pl);
      if (c < 0) break;
      setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
      char ip[32]; inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof ip);
      pthread_mutex_lock(&sendLock);
      if (clientFd >= 0) close(clientFd);
      clientFd = c;
      pthread_mutex_unlock(&sendLock);
      logf_("guest connected: %s", ip);
      sendState(capturing ? "on" : "off");
    }
    close(s);
  }
  return NULL;
}

int main(int argc, char **argv) {
  verbose = argc > 1 && !strcmp(argv[1], "-v");
  signal(SIGPIPE, SIG_IGN);

  CFArrayRef list = MTDeviceCreateList();
  int started = 0;
  for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
    MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    if (!MTDeviceIsBuiltIn(d)) continue;   // built-in trackpad only
    MTRegisterContactFrameCallback(d, frameCb); MTDeviceStart(d, 0); started++;
  }
  if (!started) { logf_("no built-in trackpad found"); return 1; }

  CGEventMask m = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
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

  pthread_t th; pthread_create(&th, NULL, serverThread, NULL);
  logf_("running (escape: Ctrl+Option+Cmd+Esc)");
  CFRunLoopRun();
  return 0;
}
