// macOS's own precise scroll deltas (NSEvent.scrollingDeltaX/Y), which can be
// finer than the whole points in CGEvent's point-delta fields.
#import <AppKit/AppKit.h>

void ns_scroll_delta(CGEventRef e, double *dx, double *dy) {
  @autoreleasepool {
    NSEvent *ev = [NSEvent eventWithCGEvent:e];
    *dx = ev ? ev.scrollingDeltaX : 0;
    *dy = ev ? ev.scrollingDeltaY : 0;
  }
}

// The NSEvent type of a CGEvent: a generic gesture event (type 29) turns out to
// be a magnify (NSEventTypeMagnify, 30) when macOS recognizes a pinch.
int ns_event_type(CGEventRef e) {
  @autoreleasepool {
    NSEvent *ev = [NSEvent eventWithCGEvent:e];
    return ev ? (int)ev.type : -1;
  }
}
