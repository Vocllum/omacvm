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
