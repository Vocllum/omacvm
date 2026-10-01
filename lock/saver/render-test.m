// render-test <saver> <out.png> [w h]: draw the screen saver view offscreen.
#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>
int main(int argc, char **argv) { @autoreleasepool {
  [NSApplication sharedApplication];
  NSBundle *b = [NSBundle bundleWithPath:@(argv[1])]; [b load];
  CGFloat w = argc > 3 ? atof(argv[3]) : 1728, h = argc > 4 ? atof(argv[4]) : 1117;
  ScreenSaverView *v = [[b.principalClass alloc] initWithFrame:NSMakeRect(0, 0, w, h) isPreview:NO];
  NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
  [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
  [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[2]) atomically:YES];
}}
