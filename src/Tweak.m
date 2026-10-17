// LiveAspect8 - LiveContainer tweak
//
// Presents the guest app with an iPhone 8 aspect ratio (16:9, 375x667 pt)
// while keeping the device's own pixel density (scale). The 16:9 area is
// centered on the real display; the remainder is left empty.
//
// Only public UIKit API is hooked and there are no app-specific offsets, so
// it does not depend on the guest app's version.
// Build with -fno-objc-arc (see build.sh).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// iPhone 8 = 750x1334 px @2x = 375x667 pt (16:9). Edit to retarget.
#define kAspectLong  667.0
#define kAspectShort 375.0

static CGRect (*orig_screen_bounds)(id, SEL);
static CGRect (*orig_screen_nativeBounds)(id, SEL);
static CGSize (*orig_mode_size)(id, SEL);
static id     (*orig_win_initWithFrame)(id, SEL, CGRect);
static void   (*orig_win_setFrame)(id, SEL, CGRect);
static void   (*orig_win_layoutSubviews)(id, SEL);

#pragma mark - Geometry

static BOOL SizeNear(CGSize a, CGSize b) {
    return fabs(a.width - b.width) < 1.0 && fabs(a.height - b.height) < 1.0;
}

// The device's true (unmodified) screen bounds in points, current orientation.
static CGRect RealBounds(void) {
    UIScreen *s = [UIScreen mainScreen];
    return orig_screen_bounds ? orig_screen_bounds(s, @selector(bounds)) : s.bounds;
}

// The 16:9 rect, centered inside the real screen, aligned to whole pixels.
static CGRect FittedRect(void) {
    CGRect real = RealBounds();
    CGFloat w = real.size.width, h = real.size.height;
    if (w <= 0 || h <= 0) return real;

    CGFloat ratio = (w > h) ? (kAspectLong / kAspectShort)    // landscape: w/h
                            : (kAspectShort / kAspectLong);   // portrait:  w/h
    CGFloat fw = w, fh = h;
    if (w / h > ratio) fw = h * ratio; else fh = w / ratio;

    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale <= 0) scale = 1;
    fw = floor(fw * scale) / scale;
    fh = floor(fh * scale) / scale;
    CGFloat x = floor(((w - fw) / 2.0) * scale) / scale;
    CGFloat y = floor(((h - fh) / 2.0) * scale) / scale;
    return CGRectMake(x, y, fw, fh);
}

// Pixel size of the fitted area, portrait-up (short side first).
static CGSize FittedPixelsPortrait(void) {
    CGRect fit = FittedRect();
    CGFloat ns = [UIScreen mainScreen].nativeScale;
    if (ns <= 0) ns = 1;
    CGFloat lo = floor(MIN(fit.size.width, fit.size.height) * ns);
    CGFloat hi = floor(MAX(fit.size.width, fit.size.height) * ns);
    return CGSizeMake(lo, hi);
}

static BOOL FrameWantsFit(CGRect f) {
    return SizeNear(f.size, RealBounds().size) || SizeNear(f.size, FittedRect().size);
}

#pragma mark - UIScreen / UIScreenMode hooks

static CGRect hook_screen_bounds(id self, SEL _cmd) {
    if (self == [UIScreen mainScreen]) {
        CGRect fit = FittedRect();
        return CGRectMake(0, 0, fit.size.width, fit.size.height);
    }
    return orig_screen_bounds(self, _cmd);
}

static CGRect hook_screen_nativeBounds(id self, SEL _cmd) {
    CGRect orig = orig_screen_nativeBounds(self, _cmd);
    if (self != [UIScreen mainScreen]) return orig;

    // nativeBounds is portrait-up in pixels regardless of interface orientation.
    CGSize p = FittedPixelsPortrait();
    return (orig.size.width <= orig.size.height)
        ? CGRectMake(0, 0, p.width, p.height)
        : CGRectMake(0, 0, p.height, p.width);
}

static CGSize hook_mode_size(id self, SEL _cmd) {
    CGSize s = orig_mode_size(self, _cmd);
    if (!orig_screen_nativeBounds) return s;

    CGSize nb = orig_screen_nativeBounds([UIScreen mainScreen], @selector(nativeBounds)).size;
    // Only rewrite the mode that matches the panel's native pixel size.
    if (SizeNear(s, nb) || SizeNear(CGSizeMake(s.height, s.width), nb)) {
        CGSize p = FittedPixelsPortrait();
        return (s.width <= s.height) ? p : CGSizeMake(p.height, p.width);
    }
    return s;
}

#pragma mark - UIWindow hooks

static id hook_win_initWithFrame(id self, SEL _cmd, CGRect frame) {
    if (FrameWantsFit(frame)) frame = FittedRect();
    return orig_win_initWithFrame(self, _cmd, frame);
}

static void hook_win_setFrame(id self, SEL _cmd, CGRect frame) {
    UIWindow *w = (UIWindow *)self;
    if (w.windowLevel == UIWindowLevelNormal && FrameWantsFit(frame)) {
        frame = FittedRect();
    }
    orig_win_setFrame(self, _cmd, frame);
}

static void hook_win_layoutSubviews(id self, SEL _cmd) {
    UIWindow *w = (UIWindow *)self;
    if (w.windowLevel == UIWindowLevelNormal) {
        CGRect cur = w.frame;
        if (FrameWantsFit(cur)) {
            CGRect fit = FittedRect();
            if (!CGRectEqualToRect(cur, fit)) w.frame = fit;  // routed through hook_win_setFrame
        }
    }
    orig_win_layoutSubviews(self, _cmd);
}

#pragma mark - Install

// Safe for inherited methods: adds an override to `cls` instead of patching
// the superclass; replaces in place when `cls` already implements it.
static void Hook(Class cls, SEL sel, IMP imp, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) {
        method_setImplementation(class_getInstanceMethod(cls, sel), imp);
    }
}

__attribute__((constructor))
static void LiveAspect8_init(void) {
    @autoreleasepool {
        Class screen = [UIScreen class];
        Class window = [UIWindow class];
        Class mode   = objc_getClass("UIScreenMode");  // looked up at runtime on purpose

        Hook(screen, @selector(bounds),
             (IMP)hook_screen_bounds, (IMP *)&orig_screen_bounds);
        Hook(screen, @selector(nativeBounds),
             (IMP)hook_screen_nativeBounds, (IMP *)&orig_screen_nativeBounds);
        Hook(mode, @selector(size),
             (IMP)hook_mode_size, (IMP *)&orig_mode_size);

        Hook(window, @selector(initWithFrame:),
             (IMP)hook_win_initWithFrame, (IMP *)&orig_win_initWithFrame);
        Hook(window, @selector(setFrame:),
             (IMP)hook_win_setFrame, (IMP *)&orig_win_setFrame);
        Hook(window, @selector(layoutSubviews),
             (IMP)hook_win_layoutSubviews, (IMP *)&orig_win_layoutSubviews);

        NSLog(@"[LiveAspect8] loaded");
    }
}
