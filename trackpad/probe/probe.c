// Feasibility probe: raw trackpad frames (MultitouchSupport) + event tap visibility.
// Observes only. Usage: ./probe [seconds]
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
static int blockMode;
static long dropped;
static void front(char *out, size_t n) {
  ProcessSerialNumber psn; pid_t pid = 0; out[0]=0;
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (GetFrontProcess(&psn) == noErr && GetProcessPID(&psn, &pid) == noErr) proc_name(pid, out, (uint32_t)n);
}

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
extern int MTDeviceGetSensorSurfaceDimensions(MTDeviceRef, int *, int *);

static long frames, touchFrames; static int maxFingers, lastN = -1;
static long gesture[64]; static long keys, combo;

static int cb(MTDeviceRef d, MTTouch *t, int n, double ts, int frame) {
  frames++; if (n) touchFrames++; if (n > maxFingers) maxFingers = n;
  if (n != lastN) {
    printf("t=%.3f fingers=%d", ts, n);
    for (int i = 0; i < n && i < 5; i++)
      printf("  [id%d st%d x%.3f y%.3f sz%.2f]", t[i].fingerID, t[i].state, t[i].normalized.pos.x, t[i].normalized.pos.y, t[i].zTotal);
    printf("\n"); fflush(stdout); lastN = n;
  }
  return 0;
}

static CGEventRef tap(CGEventTapProxy p, CGEventType type, CGEventRef e, void *u) {
  if (type < 64) gesture[type]++;
  if (type == kCGEventKeyDown) {
    keys++;
    CGEventFlags f = CGEventGetFlags(e);
    int64_t kc = CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
    char fr[64]; front(fr, sizeof fr);
    if (kc == 53) {
      printf(">>> Esc  ctrl=%d opt=%d cmd=%d shift=%d  front=%s\n", !!(f & kCGEventFlagMaskControl), !!(f & kCGEventFlagMaskAlternate), !!(f & kCGEventFlagMaskCommand), !!(f & kCGEventFlagMaskShift), fr);
      if ((f & kCGEventFlagMaskControl) && (f & kCGEventFlagMaskAlternate) && (f & kCGEventFlagMaskCommand)) combo++;
    } else printf("key (not logged) front=%s\n", fr);
    fflush(stdout);
    return e;
  }
  if (blockMode && type != kCGEventKeyDown) { dropped++; return NULL; }
  return e;
}

int main(int argc, char **argv) {
  double secs = argc > 1 ? atof(argv[1]) : 20;
  blockMode = argc > 2 && !strcmp(argv[2], "block");
  printf("mode: %s\n", blockMode ? "BLOCK gesture events" : "observe");
  CFArrayRef list = MTDeviceCreateList();
  long nd = list ? CFArrayGetCount(list) : 0;
  printf("multitouch devices: %ld\n", nd);
  for (long i = 0; i < nd; i++) {
    MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    int w = 0, h = 0; MTDeviceGetSensorSurfaceDimensions(d, &w, &h);
    printf("  dev %ld builtin=%d surface=%dx%d (1/100 mm)\n", i, MTDeviceIsBuiltIn(d), w, h);
    MTRegisterContactFrameCallback(d, cb); MTDeviceStart(d, 0);
  }
  CGEventMask m = CGEventMaskBit(kCGEventKeyDown) | ((CGEventMask)1 << 29) | ((CGEventMask)1 << 30) | ((CGEventMask)1 << 31)
                | ((CGEventMask)1 << 18) | ((CGEventMask)1 << 19) | ((CGEventMask)1 << 20) | ((CGEventMask)1 << 32) | ((CGEventMask)1 << 34);
  CFMachPortRef mp = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, blockMode ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly, m, tap, NULL);
  printf("event tap: %s\n", mp ? "OK" : "FAILED (needs Input Monitoring/Accessibility)");
  if (mp) CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(NULL, mp, 0), kCFRunLoopCommonModes);
  fflush(stdout);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);
  printf("\nSUMMARY frames=%ld touchFrames=%ld maxFingers=%d keys=%ld combo=%ld dropped=%ld\n", frames, touchFrames, maxFingers, keys, combo, dropped);
  for (int i = 0; i < 64; i++) if (gesture[i]) printf("  event type %d: %ld\n", i, gesture[i]);
  return 0;
}
