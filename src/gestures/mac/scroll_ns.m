// The NSEvent type of a CGEvent: a generic gesture event (type 29) turns out to
// be a magnify (NSEventTypeMagnify, 30) when macOS recognizes a pinch.
#import <AppKit/AppKit.h>

int ns_event_type(CGEventRef e) {
  @autoreleasepool {
    NSEvent *ev = [NSEvent eventWithCGEvent:e];
    return ev ? (int)ev.type : -1;
  }
}

// Calls f whenever another app comes to the front, so the front-app check
// need not poll fast while no VM is in front.
void ns_on_app_activate(void (*f)(void)) {
  [[[NSWorkspace sharedWorkspace] notificationCenter]
      addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil
              usingBlock:^(NSNotification *n) { (void)n; f(); }];
}

// Activates the app the usual way (the fallback of the escape combo's switch);
// 1 if macOS took the request.
int ns_activate(pid_t pid) {
  @autoreleasepool {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app && [app activateWithOptions:NSApplicationActivateIgnoringOtherApps] ? 1 : 0;
#pragma clang diagnostic pop
  }
}

// Finder's pid, 0 without one: where the escape combo goes when the app from
// before the VM has quit.
pid_t ns_finder_pid(void) {
  @autoreleasepool {
    NSArray<NSRunningApplication *> *a = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.finder"];
    return a.count ? a[0].processIdentifier : 0;
  }
}
