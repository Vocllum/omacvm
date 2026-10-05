// Offline test of the escape combo (test.sh): Ctrl+Option+Cmd+Esc in the VM
// goes back to the app from before (its Space), in macOS back into the last
// full-screen VM. Drives the helper's own tapCb with made-up key events and
// its capture logic (frontChanged) with made-up front apps; the window server
// is not asked (activateFn and finderFn are stand-ins). No permissions, no
// VM, nothing is activated.
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <fcntl.h>
#include <sys/wait.h>

static int fail, peer;
static pid_t wentTo; static CGWindowID wentWin; static int went, refuse;
static int fakeActivate(pid_t pid, CGWindowID win) { wentTo = pid; wentWin = win; went++; return !refuse; }
static pid_t finder;
static pid_t fakeFinder(void) { return finder; }

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

// What the guest got since the last call, lines joined by '|'.
static const char *sent(void) {
  static char out[256];
  out[0] = 0; usleep(2000);
  ssize_t n = read(peer, out, sizeof out - 1);
  out[n > 0 ? n : 0] = 0;
  for (char *c = out; *c; c++) if (*c == '\n') *c = '|';
  return out;
}

static CGEventRef key(int down, CGEventFlags f, int64_t state, int repeat) {
  CGEventRef e = CGEventCreateKeyboardEvent(NULL, ESC_KEYCODE, down);
  CGEventSetFlags(e, f);
  CGEventSetIntegerValueField(e, kCGEventSourceStateID, state);
  if (repeat) CGEventSetIntegerValueField(e, kCGKeyboardEventAutorepeat, 1);
  return e;
}

// Press and release; 1 if both were eaten, 0 if both passed, -1 mixed. Runs
// the main queue so the switch (scheduled after the callback) happens.
static int press(CGEventFlags f, int64_t state, int repeat) {
  went = 0;
  CGEventRef d = key(1, f, state, repeat), u = key(0, f, state, 0);
  CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL), ru = tapCb(NULL, kCGEventKeyUp, u, NULL);
  CFRelease(d); CFRelease(u);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
  return !rd && !ru ? 1 : rd && ru ? 0 : -1;
}

static pid_t child(void) { pid_t p = fork(); if (p == 0) { pause(); _exit(0); } return p; }
static void end(pid_t p) { kill(p, SIGKILL); waitpid(p, NULL, 0); }

int main(void) {
  activateFn = fakeActivate; finderFn = fakeFinder; verifyAfter = -1;
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  int sv[2]; socketpair(AF_UNIX, SOCK_STREAM, 0, sv); peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1;
  snprintf(clients[0].name, sizeof clients[0].name, "Omarchy");
  snprintf(clients[0].ip, sizeof clients[0].ip, "127.0.0.1");
  const CGEventFlags C = kCGEventFlagMaskControl, O = kCGEventFlagMaskAlternate, M = kCGEventFlagMaskCommand;
  const int64_t HID = kCGEventSourceStateHIDSystemState, POSTED = kCGEventSourceStateCombinedSessionState;
  pid_t terminal = child(), vm = child(), parallels = child();
  finder = child();

  frontChanged(terminal, -1, 0, "", 11, 1);            // Terminal on Desktop 1
  check(press(C|O|M, HID, 0) == 0 && !went, "in macOS before any VM: the combo passes, nothing switches");
  frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);      // the VM's full-screen Space
  check(!strcmp(sent(), "S on|"), "VM full screen in front: captured");

  check(press(C|O|M, HID, 0) == 1, "combo in the VM: eaten (down and up)");
  check(!strcmp(sent(), "S esc|") && !capturing && escaped, "... Omarchy lets go (S esc), capture off");
  check(went == 1 && wentTo == terminal && wentWin == 11, "... and Terminal's window comes to the front (its Space)");
  frontChanged(terminal, -1, 0, "", 11, 1);            // macOS shows Desktop 1
  check(!escaped && !strcmp(sent(), ""), "on Desktop 1: nothing more sent, capture re-arms");

  check(press(C|O|M, HID, 0) == 1, "combo in macOS: eaten");
  check(went == 1 && wentTo == vm && wentWin == 22 && !strcmp(sent(), ""), "... the VM's full-screen window comes to the front");
  frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);
  check(capturing && !strcmp(sent(), "S on|"), "... and it is captured again");

  // macOS refused the switch: the VM stays in front, the combo toggles as before.
  refuse = 1;
  check(press(C|O|M, HID, 0) == 1 && went == 1 && !capturing, "combo, switch refused: capture off");
  sent();
  frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);
  check(!capturing && escaped, "... the VM still in front stays released");
  check(press(C|O|M, HID, 0) == 1 && !went && capturing && !strcmp(sent(), "S on|"), "... the combo again captures, no switch");
  refuse = 0;

  // The app from before has quit: Finder.
  end(terminal);
  check(press(C|O|M, HID, 0) == 1 && went == 1 && wentTo == finder && wentWin == 0, "the app from before has quit: Finder");
  sent();
  frontChanged(finder, -1, 0, "", 0, 1);

  // Not the real keyboard, a held key, other combos: as before.
  check(press(C|O|M, POSTED, 0) == 0 && !went, "combo posted by an app in macOS: passes, no switch");
  check(press(C|O|M, HID, 1) == -1 && !went, "a held combo (autorepeat): its repeats eaten, no switch");
  check(press(O|M, HID, 0) == 0 && !went, "Option+Cmd+Esc (Force Quit) passes");
  check(press(C|M, HID, 0) == 0 && !went, "Ctrl+Cmd+Esc passes");

  // Parallels: the same way out and back.
  frontChanged(parallels, 0, 1, "Omarchy", 33, 0);
  sent();
  check(press(C|O|M, HID, 0) == 1 && went == 1 && wentTo == finder, "Parallels VM: back to the app from before");
  frontChanged(finder, -1, 0, "", 0, 1);
  check(press(C|O|M, HID, 0) == 1 && went == 1 && wentTo == parallels && wentWin == 33, "... and into the Parallels VM again");
  frontChanged(parallels, 0, 1, "Omarchy", 33, 0);

  // The same VM app in front in a window (it left full screen): the combo is the VM's, as before.
  frontChanged(parallels, 0, 0, "", 0, 0);
  check(press(C|O|M, HID, 0) == 0 && !went, "the VM's app in front in a window: the combo passes to it");

  // The VM has quit: the combo in macOS is macOS's again.
  frontChanged(finder, -1, 0, "", 0, 1);
  end(parallels);
  check(press(C|O|M, HID, 0) == 0 && !went, "the last VM has quit: the combo passes in macOS");

  end(vm); end(finder);
  return fail;
}
