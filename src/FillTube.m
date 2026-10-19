// FillTube - LiveContainer tweak for the YouTube app (21.3x.x and newer)
//
//  1. Stretch to fill: in landscape the video is widened horizontally to the
//     full screen width (never cropped; height is untouched).
//  2. Settings entry "FillTube" with two switches (with icons):
//       - Stretch video to fill (landscape)
//       - Disable all captions
//  3. Disable all captions: hides the caption renderer, greys out the
//     subtitle button in the player, and forces the caption-enabled state
//     to NO so YouTube cannot auto-enable captions (muted / no audio device).
//
// Nothing here uses offsets or private headers: every YouTube class and
// selector is looked up by name at runtime and skipped if missing, so a
// rename in a newer YouTube build degrades one feature instead of crashing.
// A summary line and a one-time view-hierarchy dump go to NSLog and to
// Documents/FillTube.log (readable through the Files app, no Mac needed).
//
// Build with -fno-objc-arc (see build.sh).

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <math.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <mach-o/dyld.h>

#define kKeyStretch   @"FillTube.stretch"
#define kKeyNoCC      @"FillTube.noCaptions"
#define kTweakName    @"FillTube"
#define kTitleStretch @"Stretch video to fill (landscape)"
#define kTitleNoCC    @"Disable all captions"
#define kSettingsCat  0x4C59UL

static BOOL gStretch = YES;
static BOOL gNoCC    = YES;
static Class gPlayerViewClass = Nil;
static NSMutableArray *gCaptionClasses = nil;
static BOOL gDumped = NO;

static const void *kVideoViewKey = &kVideoViewKey;
static const void *kTagKey       = &kTagKey;

#pragma mark - Logging (NSLog + Documents/FillTube.log, no Mac needed)

static void FTLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[[NSString alloc] initWithFormat:fmt arguments:ap] autorelease];
    va_end(ap);
    NSLog(@"%@", msg);

    static NSString *path = nil;
    static BOOL started = NO;
    if (!path) {
        NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        path = [[[d firstObject] stringByAppendingPathComponent:@"FillTube.log"] retain];
    }
    if (!path) return;
    FILE *f = fopen([path UTF8String], started ? "a" : "w");   // each launch starts a fresh log
    if (!f) return;
    started = YES;
    time_t t = time(NULL);
    char ts[16];
    strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
    fprintf(f, "%s %s\n", ts, [msg UTF8String]);
    fclose(f);
}

#pragma mark - Small helpers

static BOOL TextHas(NSString *s, const char *needle) {
    if (![s isKindOfClass:[NSString class]] || [s length] == 0) return NO;
    return [s rangeOfString:[NSString stringWithUTF8String:needle]
                    options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL ClassNameHas(id o, const char *needle) {
    return TextHas(NSStringFromClass([o class]), needle);
}

static BOOL InheritsFrom(Class c, Class base) {
    for (Class k = c; k; k = class_getSuperclass(k)) {
        if (k == base) return YES;
    }
    return NO;
}

static void LoadPrefs(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gStretch = [d objectForKey:kKeyStretch] ? [d boolForKey:kKeyStretch] : YES;
    gNoCC    = [d objectForKey:kKeyNoCC]    ? [d boolForKey:kKeyNoCC]    : YES;
}

static void RefreshAll(void);

static void SetPref(NSString *key, BOOL v) {
    [[NSUserDefaults standardUserDefaults] setBool:v forKey:key];
    if ([key isEqualToString:kKeyStretch]) gStretch = v; else gNoCC = v;
    dispatch_async(dispatch_get_main_queue(), ^{ RefreshAll(); });
}

// Installs imp on cls for sel. If cls only inherits the method, an override is
// added to cls (the superclass is untouched); otherwise it is replaced in place.
static void Install(Class cls, Method m, SEL sel, IMP imp) {
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) {
        method_setImplementation(m, imp);
    }
}

// Wraps a no-argument void method: before(self) -> original -> after(self).
// Every hook gets its own trampoline holding its own original IMP, so hooking
// a class and its subclass can never recurse.
static BOOL HookVoid(Class cls, SEL sel, void (*before)(id), void (*after)(id)) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    void (*orig)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^(id obj) {
        if (before) before(obj);
        orig(obj, sel);
        if (after) after(obj);
    });
    Install(cls, m, sel, imp);
    return YES;
}

#pragma mark - Stretch to fill

static void DumpTree(UIView *v, int depth, int maxDepth) {
    FTLog(@"[FillTube]   %*s%@ %@ hidden=%d", depth * 2, "",
          NSStringFromClass([v class]), NSStringFromCGRect(v.frame), (int)v.hidden);
    if (depth >= maxDepth) return;
    for (UIView *s in v.subviews) DumpTree(s, depth + 1, maxDepth);
}

static BOOL LayerHostsVideo(CALayer *l, int depth) {
    if (!l || depth > 3) return NO;
    if ([l isKindOfClass:[AVPlayerLayer class]] ||
        [l isKindOfClass:[AVSampleBufferDisplayLayer class]] ||
        ClassNameHas(l, "Metal")) {
        return YES;
    }
    for (CALayer *s in l.sublayers) {
        if (LayerHostsVideo(s, depth + 1)) return YES;
    }
    return NO;
}

static CGFloat FindVideoAspect(CALayer *l, int depth) {
    if (!l || depth > 4) return 0;
    if ([l isKindOfClass:[AVPlayerLayer class]]) {
        CGRect r = ((AVPlayerLayer *)l).videoRect;
        if (r.size.width > 1 && r.size.height > 1) return r.size.width / r.size.height;
    }
    for (CALayer *s in l.sublayers) {
        CGFloat a = FindVideoAspect(s, depth + 1);
        if (a > 0) return a;
    }
    return 0;
}

// The subview of YTPlayerView that renders the picture (not controls/captions).
static UIView *FindVideoView(UIView *pv) {
    UIView *c = objc_getAssociatedObject(pv, kVideoViewKey);
    if (c && c.superview == pv) return c;
    for (UIView *s in pv.subviews) {
        if (ClassNameHas(s, "Overlay") || ClassNameHas(s, "Control") ||
            ClassNameHas(s, "Caption") || ClassNameHas(s, "Thumbnail")) {
            continue;
        }
        if (LayerHostsVideo(s.layer, 0) || ClassNameHas(s, "VideoView")) {
            objc_setAssociatedObject(pv, kVideoViewKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return s;
        }
    }
    return nil;
}

// Identity transform while YouTube lays the view out, so its frame math stays valid.
static void PlayerBefore(id obj) {
    UIView *vv = FindVideoView((UIView *)obj);
    if (vv && !CGAffineTransformIsIdentity(vv.transform)) vv.transform = CGAffineTransformIdentity;
}

static void PlayerAfter(id obj) {
    UIView *pv = (UIView *)obj;
    CGSize b = pv.bounds.size;
    UIView *vv = FindVideoView(pv);

    if (!gDumped && b.width > b.height && b.height > 1) {
        gDumped = YES;
        FTLog(@"[FillTube] player view %@ bounds=%@ videoView=%@",
              NSStringFromClass([pv class]), NSStringFromCGSize(b),
              vv ? NSStringFromClass([vv class]) : @"NOT FOUND");
        DumpTree(pv, 0, 3);
    }
    if (!vv) return;

    CGFloat sx = 1.0;
    if (gStretch && b.width > b.height && b.height > 1) {
        CGSize v = vv.bounds.size;
        if (v.width > 1 && fabs(v.height - b.height) < 2.0 && v.width < b.width - 2.0) {
            // The video view is already sized to the picture: widen it to the screen.
            sx = b.width / v.width;
        } else if (v.width >= b.width - 2.0) {
            // The view is full-bleed and the picture is pillarboxed inside it.
            CGFloat a = FindVideoAspect(vv.layer, 0);
            if (a <= 0) a = 16.0 / 9.0;
            CGFloat cw = b.height * a;
            if (a >= 1.2 && cw < b.width - 2.0) sx = b.width / cw;
        }
    }
    if (sx > 3.0) sx = 3.0;

    CGAffineTransform t = (sx > 1.001) ? CGAffineTransformMakeScale(sx, 1.0)
                                       : CGAffineTransformIdentity;
    if (!CGAffineTransformEqualToTransform(vv.transform, t)) vv.transform = t;
}

#pragma mark - Captions

static BOOL LooksLikeCaptionButton(UIView *v) {
    if (ClassNameHas(v, "Cell")) return NO;
    return TextHas(v.accessibilityIdentifier, "caption") ||
           TextHas(v.accessibilityIdentifier, "subtitle") ||
           TextHas(v.accessibilityLabel, "caption") ||
           TextHas(v.accessibilityLabel, "subtitle");
}

static void ButtonAfter(id obj) {
    UIButton *b = (UIButton *)obj;
    BOOL tagged = objc_getAssociatedObject(b, kTagKey) != nil;
    if (gNoCC) {
        if (!LooksLikeCaptionButton(b)) return;
        if (b.enabled) b.enabled = NO;
        if (b.userInteractionEnabled) b.userInteractionEnabled = NO;
        if (b.alpha > 0.4) b.alpha = 0.35;
        if (!tagged) {
            objc_setAssociatedObject(b, kTagKey, [NSNumber numberWithBool:YES],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (tagged) {
        b.enabled = YES;
        b.userInteractionEnabled = YES;
        b.alpha = 1.0;
        objc_setAssociatedObject(b, kTagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void CaptionViewAfter(id obj) {
    UIView *v = (UIView *)obj;
    BOOL tagged = objc_getAssociatedObject(v, kTagKey) != nil;
    if (gNoCC) {
        if (!v.hidden) v.hidden = YES;
        if (v.alpha != 0) v.alpha = 0;
        if (!tagged) {
            objc_setAssociatedObject(v, kTagKey, [NSNumber numberWithBool:YES],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (tagged) {
        v.hidden = NO;
        v.alpha = 1.0;
        objc_setAssociatedObject(v, kTagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL NameIsCaptionView(const char *nm) {
    static const char *skip[] = {"Button", "Cell", "Setting", "Menu", "Picker",
                                 "Option", "Toggle", "Controller", NULL};
    if (!strcasestr(nm, "caption") && !strcasestr(nm, "subtitle")) return NO;
    for (int i = 0; skip[i]; i++) {
        if (strcasestr(nm, skip[i])) return NO;
    }
    return YES;
}

static BOOL IsCaptionViewClass(Class c) {
    const char *nm = class_getName(c);
    if (!nm || !NameIsCaptionView(nm)) return NO;
    return InheritsFrom(c, [UIView class]) && !InheritsFrom(c, [UIControl class]);
}

static BOOL AncestorIsCaptionViewClass(Class c) {
    for (Class k = class_getSuperclass(c); k && k != [UIView class]; k = class_getSuperclass(k)) {
        if (IsCaptionViewClass(k)) return YES;
    }
    return NO;
}

static BOOL InList(const char *const *list, const char *s) {
    for (int i = 0; list[i]; i++) {
        if (strcmp(list[i], s) == 0) return YES;
    }
    return NO;
}

// Caption-state setters are forced to NO, caption-state getters report NO,
// so neither the user nor an auto rule (muted / no audio device) can turn them on.
static void HookBoolMethods(Class c, int *count) {
    static const char *const setters[] = {
        "setClosedCaptionsEnabled:", "setCaptionsEnabled:", "setSubtitlesEnabled:",
        "setClosedCaptionsVisible:", "setCaptionsVisible:", "setSubtitlesVisible:",
        "setShouldShowCaptions:", NULL};
    static const char *const getters[] = {
        "closedCaptionsEnabled", "captionsEnabled", "subtitlesEnabled",
        "isClosedCaptionsEnabled", "isCaptionsEnabled",
        "shouldShowCaptions", "shouldShowClosedCaptions", NULL};

    unsigned int mc = 0;
    Method *ms = class_copyMethodList(c, &mc);
    if (!ms) return;
    for (unsigned int i = 0; i < mc; i++) {
        Method m = ms[i];
        SEL sel = method_getName(m);
        const char *n = sel_getName(sel);

        if (InList(setters, n) && method_getNumberOfArguments(m) == 3) {
            char *t = method_copyArgumentType(m, 2);
            BOOL ok = t && (t[0] == 'c' || t[0] == 'B');
            free(t);
            if (!ok) continue;
            void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^(id obj, BOOL v) {
                orig(obj, sel, gNoCC ? NO : v);
            }));
            (*count)++;
        } else if (InList(getters, n) && method_getNumberOfArguments(m) == 2) {
            char *r = method_copyReturnType(m);
            BOOL ok = r && (r[0] == 'c' || r[0] == 'B');
            free(r);
            if (!ok) continue;
            BOOL (*orig)(id, SEL) = (BOOL (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^BOOL(id obj) {
                return gNoCC ? NO : orig(obj, sel);
            }));
            (*count)++;
        }
    }
    free(ms);
}

static void ScanClasses(int *captionViews, int *boolHooks) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    SEL layoutSel = sel_registerName("layoutSubviews");
    SEL moveSel   = sel_registerName("didMoveToWindow");

    for (unsigned int i = 0; i < n; i++) {
        Class c = list[i];
        const char *nm = class_getName(c);
        if (!nm) continue;

        if (IsCaptionViewClass(c) && !AncestorIsCaptionViewClass(c)) {
            [gCaptionClasses addObject:c];
            HookVoid(c, layoutSel, NULL, CaptionViewAfter);
            HookVoid(c, moveSel, NULL, CaptionViewAfter);
            (*captionViews)++;
        }
        if ((nm[0] == 'Y' && nm[1] == 'T') || (nm[0] == 'M' && nm[1] == 'L')) {
            HookBoolMethods(c, boolHooks);
        }
    }
    free(list);
}

#pragma mark - Settings menu

static NSString *SymbolForTitle(NSString *t) {
    if ([t isEqualToString:kTitleStretch]) return @"arrow.left.and.right";
    if ([t isEqualToString:kTitleNoCC])    return @"captions.bubble";
    return nil;
}

static BOOL DecorateIn(UIView *v, int depth) {
    if (depth > 5) return NO;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        NSString *t = l.text;
        NSString *sym = ([t length] > 0 && ![t hasPrefix:@"￼"]) ? SymbolForTitle(t) : nil;
        if (sym && l.font) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithFont:l.font];
            UIImage *img = [UIImage systemImageNamed:sym withConfiguration:cfg];
            if (!img) return YES;
            UIColor *color = l.textColor ? l.textColor : [UIColor labelColor];
            img = [img imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];

            NSTextAttachment *att = [[[NSTextAttachment alloc] init] autorelease];
            att.image = img;
            CGFloat y = (l.font.capHeight - img.size.height) / 2.0;
            att.bounds = CGRectMake(0, y, img.size.width, img.size.height);

            NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                                   l.font, NSFontAttributeName,
                                   color, NSForegroundColorAttributeName, nil];
            NSMutableAttributedString *m = [[[NSMutableAttributedString alloc]
                initWithAttributedString:[NSAttributedString attributedStringWithAttachment:att]] autorelease];
            [m appendAttributedString:[[[NSAttributedString alloc]
                initWithString:[@"  " stringByAppendingString:t] attributes:attrs] autorelease]];
            l.attributedText = m;
            return YES;
        }
    }
    for (UIView *s in v.subviews) {
        if (DecorateIn(s, depth + 1)) return YES;
    }
    return NO;
}

static void SettingsCellAfter(id obj) {
    DecorateIn((UIView *)obj, 0);
}

static id MakeSwitch(Class itemCls, SEL sw, NSString *title, NSString *desc,
                     NSString *ident, NSString *key, BOOL cur) {
    BOOL (^blk)(id, BOOL) = ^BOOL(id cell, BOOL enabled) {
        SetPref(key, enabled);
        return YES;
    };
    id copied = [[blk copy] autorelease];
    return ((id (*)(id, SEL, id, id, id, BOOL, id, int))objc_msgSend)(
        itemCls, sw, title, desc, ident, cur, copied, 0);
}

static void BuildSection(id mgr) {
    @try {
        id vc = [mgr valueForKey:@"_settingsViewControllerDelegate"];
        Class itemCls = objc_getClass("YTSettingsSectionItem");
        SEL sw  = sel_registerName("switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:");
        SEL set = sel_registerName("setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
        if (!vc || !itemCls || ![itemCls respondsToSelector:sw] || ![vc respondsToSelector:set]) {
            FTLog(@"[FillTube] settings: required selectors missing (vc=%d item=%d)", vc != nil, itemCls != Nil);
            return;
        }
        NSMutableArray *rows = [NSMutableArray array];
        [rows addObject:MakeSwitch(itemCls, sw, kTitleStretch,
            @"Widens the video to the full screen width in landscape. Nothing is cropped.",
            @"liveyt.stretch", kKeyStretch, gStretch)];
        [rows addObject:MakeSwitch(itemCls, sw, kTitleNoCC,
            @"Hides captions, greys out the subtitle button and blocks auto-enable (muted / no audio device).",
            @"liveyt.nocc", kKeyNoCC, gNoCC)];
        ((void (*)(id, SEL, id, NSUInteger, id, id, id, BOOL))objc_msgSend)(
            vc, set, rows, (NSUInteger)kSettingsCat, kTweakName, nil, nil, NO);
    } @catch (NSException *e) {
        FTLog(@"[FillTube] settings build failed: %@", e);
    }
}

static BOOL gHk[4];

static int SettingsHooked(void) { return gHk[0] + gHk[1] + gHk[2] + gHk[3]; }

// Safe to call repeatedly: each hook is installed once, as soon as its class exists.
static int HookSettings(void) {

    // 1) add our category to the settings list
    SEL catSel = sel_registerName("settingsCategoryOrder");
    Class pd = objc_getClass("YTAppSettingsPresentationData");
    if (!gHk[0] && pd) {
        Class meta = object_getClass(pd);
        Method m = class_getInstanceMethod(meta, catSel);
        if (m) {
            NSArray *(*orig)(id, SEL) = (NSArray *(*)(id, SEL))method_getImplementation(m);
            Install(meta, m, catSel, imp_implementationWithBlock(^NSArray *(id cls) {
                NSArray *a = orig(cls, catSel);
                NSNumber *mine = [NSNumber numberWithUnsignedInteger:kSettingsCat];
                if (![a isKindOfClass:[NSArray class]] || [a containsObject:mine]) return a;
                NSMutableArray *out = [[a mutableCopy] autorelease];
                NSUInteger i = [out indexOfObject:[NSNumber numberWithInt:1]];
                if (i != NSNotFound) [out insertObject:mine atIndex:i + 1];
                else [out addObject:mine];
                return out;
            }));
            gHk[0] = YES;
        }
    }

    // 2) build our section when YouTube asks for it
    SEL updSel = sel_registerName("updateSectionForCategory:withEntry:");
    Class mgr = objc_getClass("YTSettingsSectionItemManager");
    if (!gHk[1] && mgr) {
        Method m = class_getInstanceMethod(mgr, updSel);
        if (m) {
            void (*orig)(id, SEL, NSUInteger, id) = (void (*)(id, SEL, NSUInteger, id))method_getImplementation(m);
            Install(mgr, m, updSel, imp_implementationWithBlock(^(id obj, NSUInteger cat, id entry) {
                if (cat == kSettingsCat) { BuildSection(obj); return; }
                orig(obj, updSel, cat, entry);
            }));
            gHk[1] = YES;
        }
    }

    // 3) YouTube asserts on unknown selection indexes
    SEL selSel = sel_registerName("setSelectedItem:");
    Class sc = objc_getClass("YTSettingsSectionController");
    if (!gHk[2] && sc) {
        Method m = class_getInstanceMethod(sc, selSel);
        if (m) {
            void (*orig)(id, SEL, NSUInteger) = (void (*)(id, SEL, NSUInteger))method_getImplementation(m);
            Install(sc, m, selSel, imp_implementationWithBlock(^(id obj, NSUInteger i) {
                if (i != NSNotFound) orig(obj, selSel, i);
            }));
            gHk[2] = YES;
        }
    }

    // 4) icons on our rows
    if (!gHk[3] && HookVoid(objc_getClass("YTSettingsCell"), sel_registerName("layoutSubviews"), NULL, SettingsCellAfter)) {
        gHk[3] = YES;
    }
    return SettingsHooked();
}

#pragma mark - Refresh after a toggle

static void RefreshView(UIView *v) {
    if (gPlayerViewClass && [v isKindOfClass:gPlayerViewClass]) [v setNeedsLayout];
    for (Class c in gCaptionClasses) {
        if ([v isKindOfClass:c]) { CaptionViewAfter(v); break; }
    }
    if ([v isKindOfClass:[UIButton class]]) ButtonAfter(v);
    for (UIView *s in v.subviews) RefreshView(s);
}

static void RefreshAll(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) RefreshView(w);
}

#pragma mark - Entry point

// LiveContainer may run this constructor before YouTube's own classes are
// loaded, so installation is retried (image loads, timers) until it sticks.
static BOOL gGateOK = NO, gPlayerHooked = NO, gButtonsHooked = NO, gScanned = NO, gPending = NO;
static int  gCaptionViews = 0, gBoolHooks = 0, gAttempts = 0, gLastSum = -1;

static BOOL AllDone(void) {
    return gGateOK && gPlayerHooked && gScanned && SettingsHooked() == 4;
}

static void InstallAll(const char *why) {
    @autoreleasepool {
        gAttempts++;
        if (!gGateOK) {
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
            if (!TextHas(bid, "youtube") && !objc_getClass("YTPlayerView")) {
                if (gAttempts <= 2) FTLog(@"[FillTube] waiting (%s): bundle=%@ is not YouTube yet", why, bid);
                return;
            }
            gGateOK = YES;
            LoadPrefs();
            gCaptionClasses = [[NSMutableArray alloc] init];
            FTLog(@"[FillTube] gate passed (%s) bundle=%@", why, bid);
        }

        SEL layoutSel = sel_registerName("layoutSubviews");
        if (!gPlayerHooked) {
            Class pv = objc_getClass("YTPlayerView");
            if (pv) {
                gPlayerViewClass = pv;
                gPlayerHooked = HookVoid(pv, layoutSel, PlayerBefore, PlayerAfter);
            }
        }
        if (!gButtonsHooked) gButtonsHooked = HookVoid([UIButton class], layoutSel, NULL, ButtonAfter);
        int settings = HookSettings();
        if (!gScanned && objc_getClass("YTPlayerView")) {
            gScanned = YES;
            ScanClasses(&gCaptionViews, &gBoolHooks);
        }

        int sum = gPlayerHooked + gButtonsHooked + settings + gScanned * 100 + gCaptionViews + gBoolHooks;
        if (sum != gLastSum) {
            gLastSum = sum;
            FTLog(@"[FillTube] state (%s, attempt %d): stretch=%d noCC=%d | YTPlayerView=%d buttons=%d "
                  @"settingsHooks=%d/4 captionViews=%d captionStateHooks=%d | classes: "
                  @"PresentationData=%d ItemManager=%d SectionController=%d Cell=%d Item=%d",
                  why, gAttempts, gStretch, gNoCC, gPlayerHooked, gButtonsHooked,
                  settings, gCaptionViews, gBoolHooks,
                  objc_getClass("YTAppSettingsPresentationData") != Nil,
                  objc_getClass("YTSettingsSectionItemManager") != Nil,
                  objc_getClass("YTSettingsSectionController") != Nil,
                  objc_getClass("YTSettingsCell") != Nil,
                  objc_getClass("YTSettingsSectionItem") != Nil);
        }
    }
}

static void ImageAdded(const struct mach_header *mh, intptr_t slide) {
    if (gPending || AllDone()) return;
    gPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gPending = NO;
        if (!AllDone()) InstallAll("image");
    });
}

__attribute__((constructor))
static void FillTube_init(void) {
    FTLog(@"[FillTube] constructor ran (log file: Documents/FillTube.log)");
    InstallAll("ctor");
    _dyld_register_func_for_add_image(ImageAdded);
    static const int delays[] = {1, 2, 4, 8, 15};
    for (int i = 0; i < 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delays[i] * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (!AllDone()) InstallAll("timer");
        });
    }
}
