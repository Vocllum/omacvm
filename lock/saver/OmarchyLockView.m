// OmarchyLock.saver: a macOS screen saver that looks like Omarchy's lock screen
// (the shell's plugins/lock/LockView.qml) for the current Omarchy theme: the
// theme background heavily blurred, and the password field centred in the
// theme's lock colours and font.
//
// Theme data (theme.json, background-*.png, font.ttf) is copied into this
// bundle's Resources/theme by tools/omarchy-lock/mac/theme-sync whenever the
// theme changes in the VM; the saver runs sandboxed and reads only its bundle.
#import <ScreenSaver/ScreenSaver.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>

@interface OmarchyLockView : ScreenSaverView
@end

static NSColor *hexColor(NSString *hex) {
  unsigned int v = 0;
  if (hex.length != 8 || ![[NSScanner scannerWithString:hex] scanHexInt:&v]) return NSColor.blackColor;
  return [NSColor colorWithSRGBRed:((v >> 24) & 0xff) / 255.0 green:((v >> 16) & 0xff) / 255.0
                              blue:((v >> 8) & 0xff) / 255.0 alpha:(v & 0xff) / 255.0];
}

static CGFloat round_(CGFloat v) { return floor(v + 0.5); }

@implementation OmarchyLockView {
  NSDictionary *_theme;
  NSImage *_rendered;     // blurred background at the current view size
  NSSize _renderedFor;
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
  if ((self = [super initWithFrame:frame isPreview:isPreview])) {
    self.animationTimeInterval = 5.0;   // static picture; no need to redraw often
    NSBundle *b = [NSBundle bundleForClass:self.class];
    NSString *dir = [b.resourcePath stringByAppendingPathComponent:@"theme"];
    NSData *json = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"theme.json"]];
    _theme = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : @{};
    NSString *font = [dir stringByAppendingPathComponent:_theme[@"font_file"] ?: @"font.ttf"];
    if ([NSFileManager.defaultManager fileExistsAtPath:font])
      CTFontManagerRegisterFontsForURL((__bridge CFURLRef)[NSURL fileURLWithPath:font], kCTFontManagerScopeProcess, NULL);
  }
  return self;
}

- (NSImage *)background {
  NSSize size = self.bounds.size;
  if (_rendered && NSEqualSizes(size, _renderedFor)) return _rendered;
  NSString *dir = [[NSBundle bundleForClass:self.class].resourcePath stringByAppendingPathComponent:@"theme"];
  NSString *path = _theme[@"background"] ? [dir stringByAppendingPathComponent:_theme[@"background"]] : nil;
  CIImage *img = path ? [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:path]] : nil;
  if (!img) return nil;

  CGFloat scale = self.window.backingScaleFactor ?: 2.0;
  CGSize px = CGSizeMake(size.width * scale, size.height * scale);
  // Aspect-fill (Image.PreserveAspectCrop), then blur like the lock's
  // MultiEffect (blurMax 128 x multiplier 1.25) and lower the contrast a bit.
  CGFloat f = MAX(px.width / img.extent.size.width, px.height / img.extent.size.height);
  img = [img imageByApplyingTransform:CGAffineTransformMakeScale(f, f)];
  img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(
            -(img.extent.size.width - px.width) / 2 - img.extent.origin.x,
            -(img.extent.size.height - px.height) / 2 - img.extent.origin.y)];
  NSDictionary *blur = _theme[@"blur"] ?: @{};
  double sigma = [blur[@"max"] ?: @128 doubleValue] * [blur[@"multiplier"] ?: @1.25 doubleValue] / 4.0 * scale;
  img = [[img imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:sigma];
  img = [img imageByApplyingFilter:@"CIColorControls" withInputParameters:@{
            @"inputContrast": @(1.0 + [blur[@"contrast"] ?: @-0.08 doubleValue]) }];
  img = [img imageByCroppingToRect:CGRectMake(0, 0, px.width, px.height)];

  CIContext *ctx = [CIContext contextWithOptions:nil];
  CGImageRef cg = [ctx createCGImage:img fromRect:CGRectMake(0, 0, px.width, px.height)];
  _rendered = [[NSImage alloc] initWithCGImage:cg size:size];
  CGImageRelease(cg);
  _renderedFor = size;
  return _rendered;
}

- (void)drawRect:(NSRect)rect {
  NSRect b = self.bounds;
  [hexColor(_theme[@"color"] ?: @"000000ff") setFill];
  NSRectFill(b);
  [[self background] drawInRect:b];

  // The password field (LockView.qml: BorderSurface 381x67, outline 3, radius =
  // Hyprland rounding, placeholder centred). Logical px = points here.
  CGFloat k = self.isPreview ? b.size.width / 1440.0 : 1.0;   // scale down in the Settings preview
  NSArray *sz = _theme[@"size"] ?: @[@381, @67];
  CGFloat w = [sz[0] doubleValue] * k, h = [sz[1] doubleValue] * k;
  CGFloat line = [_theme[@"outline"] ?: @3 doubleValue] * k, round = [_theme[@"rounding"] ?: @0 doubleValue] * k;
  NSRect box = NSMakeRect(round_(NSMidX(b) - w / 2), round_(NSMidY(b) - h / 2), w, h);
  NSRect innerRect = NSInsetRect(box, line, line);
  CGFloat ir = MAX(0, round - line);
  NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:box xRadius:round yRadius:round];
  NSBezierPath *inner = [NSBezierPath bezierPathWithRoundedRect:innerRect xRadius:ir yRadius:ir];
  [hexColor(_theme[@"field_color"]) setFill];
  [inner fill];                                   // translucent card over the blurred background
  NSBezierPath *ring = [outer copy];
  [ring appendBezierPath:inner];
  ring.windingRule = NSWindingRuleEvenOdd;
  [hexColor(_theme[@"border_color"]) setFill];
  [ring fill];

  NSString *family = _theme[@"font_family"] ?: @"Menlo";
  CGFloat fs = [_theme[@"font_size"] ?: @18 doubleValue] * k;
  NSFont *font = [NSFont fontWithName:family size:fs] ?: [NSFont fontWithName:[family stringByAppendingString:@" Regular"] size:fs]
                 ?: [NSFont fontWithName:[[family stringByReplacingOccurrencesOfString:@" " withString:@""] stringByAppendingString:@"-Regular"] size:fs]
                 ?: [NSFont monospacedSystemFontOfSize:fs weight:NSFontWeightRegular];
  NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
  p.alignment = NSTextAlignmentCenter;
  NSDictionary *attrs = @{ NSFontAttributeName: font, NSParagraphStyleAttributeName: p,
                           NSForegroundColorAttributeName: hexColor(_theme[@"placeholder_color"]) };
  NSString *text = _theme[@"placeholder"] ?: @"Enter Password";
  NSSize ts = [text sizeWithAttributes:attrs];
  [text drawInRect:NSMakeRect(innerRect.origin.x, NSMidY(innerRect) - ts.height / 2, innerRect.size.width, ts.height) withAttributes:attrs];
}

- (void)animateOneFrame {
  // Static image; only redraw if the view size changed (display reconfigured).
  if (!NSEqualSizes(self.bounds.size, _renderedFor)) [self setNeedsDisplay:YES];
}

- (BOOL)hasConfigureSheet { return NO; }
- (NSWindow *)configureSheet { return nil; }
@end
