#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

static NSView *findTTView(NSView *v) {
    if ([NSStringFromClass([v class]) isEqualToString:@"TTView"]) return v;
    for (NSView *s in v.subviews) { NSView *r = findTTView(s); if (r) return r; }
    return nil;
}

static void clearChrome(NSView *v) {
    NSString *cls = NSStringFromClass([v class]);
    if ([v isKindOfClass:[NSVisualEffectView class]] || [cls isEqualToString:@"NSScrollPocket"]) {
        v.hidden = YES;
        return;
    }
    if ([cls containsString:@"SubduedGlassEffectView"] && v.subviews.count > 1) {
        v.subviews[0].hidden = YES;  // strip backdrop; subviews[1] holds the tabs
    }
    if ([cls containsString:@"Tab"] || [cls containsString:@"Titlebar"]) {
        v.wantsLayer = YES;
        v.layer.backgroundColor = NSColor.clearColor.CGColor;
    }
    for (NSView *s in v.subviews) clearChrome(s);
}

static NSColor *terminalBackground(NSView *tt) {
    id ctl = [tt valueForKey:@"controller"];
    id c = [ctl valueForKey:@"customBackgroundColor"];
    if (![c isKindOfClass:[NSColor class]]) c = [[tt valueForKey:@"profile"] valueForKey:@"BackgroundColor"];
    return [c isKindOfClass:[NSColor class]] ? c : nil;
}

static NSView *findDesc(NSView *v, NSString *cls) {
    if ([NSStringFromClass([v class]) isEqualToString:cls]) return v;
    for (NSView *s in v.subviews) { NSView *r = findDesc(s, cls); if (r) return r; }
    return nil;
}

static NSView *findSuper(NSView *v, NSString *cls) {
    for (NSView *s = v.superview; s; s = s.superview) if ([NSStringFromClass([s class]) isEqualToString:cls]) return s;
    return nil;
}

static NSView *titlebarView(NSWindow *w) {
    NSView *frame = w.contentView.superview;
    return [frame respondsToSelector:NSSelectorFromString(@"titlebarView")] ? [frame valueForKey:@"titlebarView"] : nil;
}

static BOOL isTabBarAccessory(NSTitlebarAccessoryViewController *c) {
    if (findDesc(c.view, @"NSTabBar")) return YES;
    // AppKit adds an empty NSView first and attaches the NSTabBar later.
    return c.layoutAttribute == NSLayoutAttributeBottom && [c.view isMemberOfClass:NSView.class] && c.view.subviews.count == 0;
}

static const void *kTabConstraintsKey = &kTabConstraintsKey;
static const CGFloat kTabLeftInset = 70;  // room for the traffic lights

static BOOL constraintsApplied(NSWindow *w, NSView *clip) {
    NSArray<NSLayoutConstraint *> *cs = objc_getAssociatedObject(w, kTabConstraintsKey);
    if (!cs || cs.firstObject.firstItem != clip || clip.translatesAutoresizingMaskIntoConstraints) return NO;
    for (NSLayoutConstraint *c in cs) if (!c.active) return NO;
    return YES;
}

// empty toolbar makes title row taller (~38pt) so the tab bar is not glued to the top edge.
static void ensureToolbar(NSWindow *w) {
    if (w.toolbar) return;
    NSToolbar *t = [[NSToolbar alloc] initWithIdentifier:@"terminl"];
    t.allowsUserCustomization = NO;
    w.toolbar = t;
    w.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
}

// AppKit rebuilds the tab bar on main-window changes, tab drags and appearance changes.
static void setupTabBar(NSWindow *w) {
    ensureToolbar(w);
    NSView *tb = titlebarView(w);
    NSView *tabBar = tb ? findDesc(tb, @"NSTabBar") : nil;
    NSView *doc = tb ? findDesc(tb, @"NSThemeDocumentButton") : nil;

    if (!tabBar) {
        if (w.titleVisibility != NSWindowTitleVisible) w.titleVisibility = NSWindowTitleVisible;
        if (doc.hidden) doc.hidden = NO;
        objc_setAssociatedObject(w, kTabConstraintsKey, nil, OBJC_ASSOCIATION_RETAIN);
        return;
    }

    if (w.titleVisibility != NSWindowTitleHidden) w.titleVisibility = NSWindowTitleHidden;
    if (doc && !doc.hidden) doc.hidden = YES;  // proxy icon would sit under the first tab
    NSView *clip = findSuper(tabBar, @"NSTitlebarAccessoryContainerView") ?: findSuper(tabBar, @"NSTitlebarAccessoryClipView");
    NSView *accessory = clip.subviews.firstObject;
    if (!clip || !accessory || constraintsApplied(w, clip)) return;
    NSView *container = findDesc(tb, @"NSToolbarView") ?: tb;
    NSView *newTab = findDesc(tabBar, @"NSTabBarNewTabButton");

    if (newTab) {
        // don't stretch
        NSRect f = tabBar.frame; f.size.height = newTab.frame.size.width; tabBar.frame = f;
    }
                                                                                                         //
    // AppKit keeps the tab bar at a fixed offset inside the accessory view; shift the clip so the bar is centred on the title row.
    CGFloat top = NSMidY(tabBar.frame) - NSHeight(container.bounds) / 2;
    [NSLayoutConstraint deactivateConstraints:objc_getAssociatedObject(w, kTabConstraintsKey) ?: @[]];
    clip.translatesAutoresizingMaskIntoConstraints = NO;
    accessory.translatesAutoresizingMaskIntoConstraints = NO;
    NSArray *cs = @[
        [clip.leftAnchor constraintEqualToAnchor:container.leftAnchor constant:kTabLeftInset],
        [clip.rightAnchor constraintEqualToAnchor:container.rightAnchor],
        [clip.topAnchor constraintEqualToAnchor:container.topAnchor constant:top],
        [clip.heightAnchor constraintEqualToAnchor:container.heightAnchor],
        [accessory.leftAnchor constraintEqualToAnchor:clip.leftAnchor],
        [accessory.rightAnchor constraintEqualToAnchor:clip.rightAnchor],
        [accessory.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [accessory.heightAnchor constraintEqualToAnchor:clip.heightAnchor],
    ];
    [NSLayoutConstraint activateConstraints:cs];
    objc_setAssociatedObject(w, kTabConstraintsKey, cs, OBJC_ASSOCIATION_RETAIN);
    clip.needsLayout = accessory.needsLayout = YES;
}

// The layout attribute must be set before the accessory is added or AppKit asserts.
static IMP origAddAccessory;
static void tabAddAccessory(NSWindow *self, SEL _cmd, NSTitlebarAccessoryViewController *c) {
    BOOL tabs = [NSStringFromClass([self class]) isEqualToString:@"TTWindow"] && isTabBarAccessory(c);
    if (tabs) c.layoutAttribute = NSLayoutAttributeRight;
    ((void (*)(id, SEL, id))origAddAccessory)(self, _cmd, c);
    if (tabs) dispatch_async(dispatch_get_main_queue(), ^{ setupTabBar(self); });
}

static void fixWindow(NSWindow *w) {
    NSView *tt = findTTView(w.contentView);
    if (!tt || ![tt respondsToSelector:@selector(backgroundColor)]) return;
    NSColor *bg = terminalBackground(tt);
    if (!bg) return;
    w.titlebarAppearsTransparent = YES;
    w.backgroundColor = bg;
    clearChrome(w.contentView.superview);
    setupTabBar(w);
}

static void fixAll(void) {
    for (NSWindow *w in NSApp.windows) {
        fixWindow(w);
    }
}

// Zoom to the full visible screen instead of a size rounded to whole character cells.
static NSRect fullStandardFrame(id self, SEL _cmd, NSWindow *w, NSRect defaultFrame) {
    return defaultFrame;
}

// Terminal resizes the window to keep its row count when the tab bar shows or hides.
// Keep the window frame instead when that is what changed.
static IMP origUpdateGeometry;
static const void *kTabBarVisibleKey = &kTabBarVisibleKey;
static const void *kPinnedFrameKey = &kPinnedFrameKey;

// Terminal recomputes geometry more than once per tab bar change, so the frame is
// pinned briefly after the change rather than for a single call.
static void stableUpdateGeometry(NSWindowController *self, SEL _cmd) {
    NSWindow *w = self.window;
    NSNumber *visible = @(w.tabGroup.isTabBarVisible);
    NSNumber *previous = objc_getAssociatedObject(w, kTabBarVisibleKey);
    objc_setAssociatedObject(w, kTabBarVisibleKey, visible, OBJC_ASSOCIATION_RETAIN);
    if (previous && ![previous isEqual:visible]) {
        objc_setAssociatedObject(w, kPinnedFrameKey, [NSValue valueWithRect:w.frame], OBJC_ASSOCIATION_RETAIN);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(w, kPinnedFrameKey, nil, OBJC_ASSOCIATION_RETAIN);
        });
    }
    ((void (*)(id, SEL))origUpdateGeometry)(self, _cmd);
    NSValue *pinned = objc_getAssociatedObject(w, kPinnedFrameKey);
    if (pinned && !NSEqualRects(w.frame, pinned.rectValue)) {
        [w setFrame:pinned.rectValue display:YES];
    }
}

__attribute__((constructor)) static void init(void) {
    Method geometry = class_getInstanceMethod(NSClassFromString(@"TTWindowController"), NSSelectorFromString(@"updateWindowGeometry"));
    if (geometry) origUpdateGeometry = method_setImplementation(geometry, (IMP)stableUpdateGeometry);
    Method zoom = class_getInstanceMethod(NSClassFromString(@"TTWindowController"), @selector(windowWillUseStandardFrame:defaultFrame:));
    if (zoom) method_setImplementation(zoom, (IMP)fullStandardFrame);
    Method add = class_getInstanceMethod([NSWindow class], @selector(addTitlebarAccessoryViewController:));
    origAddAccessory = method_setImplementation(add, (IMP)tabAddAccessory);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidResizeNotification, NSWindowDidBecomeMainNotification]) {
            [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) { fixWindow(note.object); }];
        }
        // TODO: see if we can avoid the polling
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { fixAll(); }];
    });
}
