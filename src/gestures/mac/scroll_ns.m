// The NSEvent type of a CGEvent: a generic gesture event (type 29) turns out to
// be a magnify (NSEventTypeMagnify, 30) when macOS recognizes a pinch.
#import <AppKit/AppKit.h>

int ns_event_type(CGEventRef e) {
  @autoreleasepool {
    NSEvent *ev = [NSEvent eventWithCGEvent:e];
    return ev ? (int)ev.type : -1;
  }
}
