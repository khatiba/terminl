#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

// Command palette (Cmd+Shift+P): fuzzy search over every enabled item in the main menu.

static const CGFloat kPaletteWidth = 560, kPaletteFieldHeight = 46, kPaletteRowHeight = 32, kPalettePadding = 8;
static const NSInteger kPaletteMaxRows = 10;

@interface TerminlPaletteItem : NSObject
@property (copy) void (^action)(void);
@property (copy) NSString *title, *path, *shortcut;
@property NSInteger score;
@end
@implementation TerminlPaletteItem
@end

static NSString *paletteShortcut(NSMenuItem *item) {
    NSString *key = item.keyEquivalent;
    if (!key.length) return @"";
    NSEventModifierFlags m = item.keyEquivalentModifierMask;
    // An uppercase key equivalent implies Shift without setting it in the mask.
    if (![key.lowercaseString isEqualToString:key]) m |= NSEventModifierFlagShift;
    NSString *glyph;
    switch ([key characterAtIndex:0]) {
        case NSCarriageReturnCharacter: case NSNewlineCharacter: glyph = @"↩"; break;
        case NSEnterCharacter: glyph = @"⌅"; break;
        case NSTabCharacter: case NSBackTabCharacter: glyph = @"⇥"; break;
        case NSBackspaceCharacter: case NSDeleteCharacter: glyph = @"⌫"; break;
        case NSDeleteFunctionKey: glyph = @"⌦"; break;
        case 0x1b: glyph = @"⎋"; break;
        case ' ': glyph = @"Space"; break;
        case NSUpArrowFunctionKey: glyph = @"↑"; break;
        case NSDownArrowFunctionKey: glyph = @"↓"; break;
        case NSLeftArrowFunctionKey: glyph = @"←"; break;
        case NSRightArrowFunctionKey: glyph = @"→"; break;
        case NSHomeFunctionKey: glyph = @"↖"; break;
        case NSEndFunctionKey: glyph = @"↘"; break;
        case NSPageUpFunctionKey: glyph = @"⇞"; break;
        case NSPageDownFunctionKey: glyph = @"⇟"; break;
        default: glyph = key.uppercaseString;
    }
    return [NSString stringWithFormat:@"%@%@%@%@%@%@", m & NSEventModifierFlagFunction ? @"fn " : @"",
        m & NSEventModifierFlagControl ? @"⌃" : @"", m & NSEventModifierFlagOption ? @"⌥" : @"",
        m & NSEventModifierFlagShift ? @"⇧" : @"", m & NSEventModifierFlagCommand ? @"⌘" : @"", glyph];
}

// Validates as it goes, so this must run while the terminal window is still key.
static void paletteCollect(NSMenu *menu, NSString *path, NSMutableArray<TerminlPaletteItem *> *out) {
    if (menu == NSApp.servicesMenu) return;
    if ([menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [menu.delegate menuNeedsUpdate:menu];
    [menu update];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem || item.isHidden || item.view || !item.title.length) continue;
        if ([item.representedObject isKindOfClass:NSClassFromString(@"TTProfile")]) continue;  // one row per profile, three times over
        if (item.submenu) {
            paletteCollect(item.submenu, path.length ? [NSString stringWithFormat:@"%@ › %@", path, item.title] : item.title, out);
        } else if (item.isEnabled && item.action) {
            TerminlPaletteItem *p = [TerminlPaletteItem new];
            p.action = ^{
                NSInteger index = [item.menu indexOfItem:item];
                if (index >= 0) [item.menu performActionForItemAtIndex:index];
            };
            p.title = item.title;
            p.path = path;
            p.shortcut = paletteShortcut(item);
            [out addObject:p];
        }
    }
}

// Actions on the key window's working directory, which Terminal keeps in representedURL.
static NSArray<TerminlPaletteItem *> *paletteCwdItems(NSWindow *w) {
    NSURL *url = w.representedURL;
    if (!url.isFileURL) return @[];
    NSString *path = url.path;
    TerminlPaletteItem *finder = [TerminlPaletteItem new];
    finder.title = @"Open in Finder";
    finder.path = path.stringByAbbreviatingWithTildeInPath;
    finder.shortcut = @"";
    finder.action = ^{ [NSWorkspace.sharedWorkspace selectFile:nil inFileViewerRootedAtPath:path]; };
    return @[finder];
}

// Subsequence match rewarding runs and word starts; NSNotFound when q is not a subsequence of s.
static NSInteger paletteFuzzy(NSString *q, NSString *s) {
    q = q.lowercaseString; s = s.lowercaseString;
    NSInteger score = 0, last = -2, qi = 0, qn = q.length, sn = s.length;
    NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet;
    for (NSInteger i = 0; i < sn && qi < qn; i++) {
        if ([s characterAtIndex:i] != [q characterAtIndex:qi]) continue;
        score += 1;
        if (i == last + 1) score += 5;
        if (i == 0 || ![alnum characterIsMember:[s characterAtIndex:i - 1]]) score += 8;
        last = i;
        qi++;
    }
    return qi == qn ? score - sn / 8 : NSNotFound;
}

@interface TerminlPalettePanel : NSPanel
@end
@implementation TerminlPalettePanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface TerminlPaletteCell : NSTableCellView
@property (strong) NSTextField *shortcut;
@end
@implementation TerminlPaletteCell
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    NSTextField *title = [NSTextField labelWithString:@""];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _shortcut = [NSTextField labelWithString:@""];
    _shortcut.textColor = NSColor.secondaryLabelColor;
    _shortcut.font = [NSFont systemFontOfSize:12];
    for (NSTextField *f in @[title, _shortcut]) {
        f.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:f];
    }
    self.textField = title;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
        [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_shortcut.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:12],
        [_shortcut.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
        [_shortcut.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}
@end

@interface TerminlPalette : NSObject <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (strong) TerminlPalettePanel *panel;
@property (strong) NSTextField *field;
@property (strong) NSBox *separator;
@property (strong) NSScrollView *scroll;
@property (strong) NSTableView *table;
@property (strong) NSWindow *previousKey;
@property (copy) NSArray<TerminlPaletteItem *> *allItems, *items;
@end

@implementation TerminlPalette

- (instancetype)init {
    self = [super init];
    _panel = [[TerminlPalettePanel alloc] initWithContentRect:NSMakeRect(0, 0, kPaletteWidth, kPaletteFieldHeight)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:YES];
    _panel.titleVisibility = NSWindowTitleHidden;
    _panel.titlebarAppearsTransparent = YES;
    _panel.movable = NO;
    _panel.floatingPanel = YES;
    _panel.restorable = NO;
    _panel.releasedWhenClosed = NO;
    _panel.excludedFromWindowsMenu = YES;
    _panel.tabbingMode = NSWindowTabbingModeDisallowed;
    _panel.animationBehavior = NSWindowAnimationBehaviorNone;
    _panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
    _panel.delegate = self;
    for (NSNumber *b in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)])
        [_panel standardWindowButton:b.unsignedIntegerValue].hidden = YES;

    NSVisualEffectView *content = [[NSVisualEffectView alloc] initWithFrame:_panel.contentView.frame];
    content.material = NSVisualEffectMaterialMenu;
    content.state = NSVisualEffectStateActive;
    _panel.contentView = content;

    _field = [NSTextField new];
    _field.bordered = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.font = [NSFont systemFontOfSize:18];
    _field.placeholderString = @"Type a command…";
    _field.cell.scrollable = YES;
    _field.cell.usesSingleLineMode = YES;
    _field.delegate = self;
    [content addSubview:_field];

    _separator = [NSBox new];
    _separator.boxType = NSBoxSeparator;
    [content addSubview:_separator];

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    _table = [NSTableView new];
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.style = NSTableViewStyleInset;
    _table.rowHeight = kPaletteRowHeight;
    _table.intercellSpacing = NSZeroSize;
    _table.backgroundColor = NSColor.clearColor;
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.refusesFirstResponder = YES;  // typing stays in the field
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.action = @selector(clicked:);

    _scroll = [NSScrollView new];
    _scroll.documentView = _table;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    [content addSubview:_scroll];
    return self;
}

- (void)toggle {
    if (_panel.isVisible) { [self dismissRestoringKey:YES]; return; }
    NSWindow *anchor = NSApp.keyWindow ?: NSApp.mainWindow;
    NSMutableArray *items = [paletteCwdItems(NSApp.keyWindow) mutableCopy];
    paletteCollect(NSApp.mainMenu, @"", items);
    _allItems = items;
    _previousKey = NSApp.keyWindow;
    _field.stringValue = @"";
    NSRect area = anchor ? anchor.frame : NSScreen.mainScreen.visibleFrame;
    [_panel setFrameTopLeftPoint:NSMakePoint(NSMidX(area) - kPaletteWidth / 2, NSMaxY(area) - 80)];
    [self filter];
    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_field];
}

- (void)dismissRestoringKey:(BOOL)restore {
    NSWindow *target = _previousKey;
    _previousKey = nil;
    [_panel orderOut:nil];
    if (restore) [target makeKeyWindow];
}

- (void)windowDidResignKey:(NSNotification *)note {
    if (_panel.isVisible) [self dismissRestoringKey:NO];
}

- (void)filter {
    NSString *q = [_field.stringValue stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (!q.length) {
        _items = _allItems;
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (TerminlPaletteItem *item in _allItems) {
            NSInteger title = paletteFuzzy(q, item.title);
            NSInteger full = title == NSNotFound ? paletteFuzzy(q, [item.path stringByAppendingFormat:@" %@", item.title]) : NSNotFound;
            if (title == NSNotFound && full == NSNotFound) continue;
            item.score = title != NSNotFound ? title + 100 : full;  // title hits outrank menu-path hits
            [matches addObject:item];
        }
        // NSArray's sort is not documented as stable, so ties explicitly keep menu order.
        NSArray *order = _allItems;
        _items = [matches sortedArrayUsingComparator:^NSComparisonResult(TerminlPaletteItem *a, TerminlPaletteItem *b) {
            if (a.score != b.score) return a.score > b.score ? NSOrderedAscending : NSOrderedDescending;
            NSUInteger ai = [order indexOfObjectIdenticalTo:a], bi = [order indexOfObjectIdenticalTo:b];
            return ai < bi ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    [_table reloadData];
    if (_items.count) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_table scrollRowToVisible:0];
    }
    [self layout];
}

// Grows downward from a fixed top edge.
- (void)layout {
    NSInteger rows = MIN((NSInteger)_items.count, kPaletteMaxRows);
    CGFloat list = rows ? rows * kPaletteRowHeight + kPalettePadding * 2 : 0;
    CGFloat height = kPaletteFieldHeight + list;
    NSRect frame = _panel.frame;
    frame.origin.y = NSMaxY(frame) - height;
    frame.size.height = height;
    [_panel setFrame:frame display:YES];
    CGFloat fieldHeight = ceil(_field.intrinsicContentSize.height);
    _field.frame = NSMakeRect(16, list + (kPaletteFieldHeight - fieldHeight) / 2, kPaletteWidth - 32, fieldHeight);
    _separator.frame = NSMakeRect(0, list, kPaletteWidth, 1);
    _separator.hidden = !rows;
    _scroll.frame = NSMakeRect(0, 0, kPaletteWidth, list);
    _scroll.hidden = !rows;
}

- (void)run:(TerminlPaletteItem *)item {
    [self dismissRestoringKey:YES];
    // Next turn, so the action's responder chain starts at the restored terminal window, not the search field.
    dispatch_async(dispatch_get_main_queue(), item.action);
}

- (void)runSelected {
    NSInteger row = _table.selectedRow;
    if (row >= 0 && row < (NSInteger)_items.count) [self run:_items[row]];
}

- (void)clicked:(id)sender {
    NSInteger row = _table.clickedRow;
    if (row >= 0 && row < (NSInteger)_items.count) [self run:_items[row]];
}

- (void)moveSelection:(NSInteger)delta {
    NSInteger count = _items.count;
    if (!count) return;
    NSInteger row = (_table.selectedRow + delta + count) % count;
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_table scrollRowToVisible:row];
}

- (void)controlTextDidChange:(NSNotification *)note {
    [self filter];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command == @selector(moveDown:) || command == @selector(insertTab:)) [self moveSelection:1];
    else if (command == @selector(moveUp:) || command == @selector(insertBacktab:)) [self moveSelection:-1];
    else if (command == @selector(insertNewline:)) [self runSelected];
    else if (command == @selector(cancelOperation:)) [self dismissRestoringKey:YES];
    else return NO;
    return YES;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _items.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    TerminlPaletteCell *cell = [tableView makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [TerminlPaletteCell new];
        cell.identifier = @"cell";
    }
    TerminlPaletteItem *item = _items[row];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:item.title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: NSColor.labelColor}];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:item.path] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    cell.textField.attributedStringValue = s;
    cell.shortcut.stringValue = item.shortcut;
    return cell;
}

@end

static TerminlPalette *palette;

static void installPalette(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        NSEventModifierFlags relevant = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl;
        if ((e.modifierFlags & relevant) != (NSEventModifierFlagCommand | NSEventModifierFlagShift)) return e;
        if (![e.charactersIgnoringModifiers.lowercaseString isEqualToString:@"p"]) return e;
        if (NSApp.modalWindow || NSApp.keyWindow.isSheet) return e;
        if (e.isARepeat) return nil;
        if (!palette) palette = [TerminlPalette new];
        [palette toggle];
        return nil;
    }];
}

// Mac-style line editing: Cmd+←/→ to line start/end, Opt+←/→ by word, Cmd+Backspace clears the line.
// Profile key maps can't bind Cmd combos, so these are caught before Terminal sees them and written to the shell.

static NSString *keysSequence(NSEvent *e) {
    NSEventModifierFlags m = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                NSEventModifierFlagControl | NSEventModifierFlagShift);
    switch (e.keyCode) {
        case 123:  // ←
            if (m == NSEventModifierFlagCommand) return @"\x01";
            if (m == NSEventModifierFlagOption) return @"\eb";
            break;
        case 124:  // →
            if (m == NSEventModifierFlagCommand) return @"\x05";
            if (m == NSEventModifierFlagOption) return @"\ef";
            break;
        case 51:  // Backspace: end of line, then kill backwards, so bash clears the whole line like zsh
            if (m == NSEventModifierFlagCommand) return @"\x05\x15";
            break;
    }
    return nil;
}

static void installKeys(void) {
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        NSResponder *r = e.window.firstResponder;
        if (![NSStringFromClass([r class]) isEqualToString:@"TTView"]) return e;
        NSString *seq = keysSequence(e);
        if (!seq) return e;
        id shell = [[r valueForKey:@"controller"] valueForKey:@"shell"];
        if (![shell respondsToSelector:@selector(writeData:)]) return e;
        [shell performSelector:@selector(writeData:) withObject:[seq dataUsingEncoding:NSUTF8StringEncoding]];
        return nil;
    }];
}

// Debug build (make debug): logs to stderr when TERMINL_DUMP is set.
#ifdef TERMINL_DEBUG
#define DUMP(...) do { if (getenv("TERMINL_DUMP")) fprintf(stderr, __VA_ARGS__); } while (0)
#else
#define DUMP(...) do {} while (0)
#endif

static NSView *findTTView(NSView *v) {
    if ([NSStringFromClass([v class]) isEqualToString:@"TTView"]) return v;
    for (NSView *s in v.subviews) { NSView *r = findTTView(s); if (r) return r; }
    return nil;
}

#ifdef TERMINL_DEBUG
static void dump(NSView *v, int depth) {
    fprintf(stderr, "%*s%s %s\n", depth * 2, "", NSStringFromClass([v class]).UTF8String, NSStringFromRect(v.frame).UTF8String);
    for (NSView *s in v.subviews) dump(s, depth + 1);
}
#endif

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
    DUMP("color %s %s\n", NSStringFromClass([c class]).UTF8String, [c description].UTF8String);
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
    DUMP("titlebar tabs applied container=%s top=%g tabBar=%s\n", NSStringFromClass([container class]).UTF8String, top, NSStringFromRect(tabBar.frame).UTF8String);
}

// The layout attribute must be set before the accessory is added or AppKit asserts.
static IMP origAddAccessory;
static void tabAddAccessory(NSWindow *self, SEL _cmd, NSTitlebarAccessoryViewController *c) {
    BOOL tabs = [NSStringFromClass([self class]) isEqualToString:@"TTWindow"] && isTabBarAccessory(c);
    DUMP("addAccessory win=%s view=%s layout=%ld -> tabs=%d\n", NSStringFromClass([self class]).UTF8String, NSStringFromClass([c.view class]).UTF8String, (long)c.layoutAttribute, tabs);
    if (tabs) c.layoutAttribute = NSLayoutAttributeRight;
    ((void (*)(id, SEL, id))origAddAccessory)(self, _cmd, c);
    if (tabs) dispatch_async(dispatch_get_main_queue(), ^{ setupTabBar(self); });
}

static void fixWindow(NSWindow *w) {
    DUMP("fix %s tt=%p\n", w.title.UTF8String, findTTView(w.contentView));
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

// Terminal also resizes the window to keep its row count when the find bar toggles or changes height.
// Those geometry updates happen inside these calls, so the frame is pinned for just their duration.
static IMP origSetFindBarVisible, origFindBarDidChangeHeight;

static void withPinnedFrame(NSWindow *w, void (^body)(void)) {
    if (w) objc_setAssociatedObject(w, kPinnedFrameKey, [NSValue valueWithRect:w.frame], OBJC_ASSOCIATION_RETAIN);
    body();
    if (w) objc_setAssociatedObject(w, kPinnedFrameKey, nil, OBJC_ASSOCIATION_RETAIN);
}

static void stableSetFindBarVisible(NSView *self, SEL _cmd, BOOL visible) {
    withPinnedFrame(self.window, ^{ ((void (*)(id, SEL, BOOL))origSetFindBarVisible)(self, _cmd, visible); });
}

static void stableFindBarDidChangeHeight(NSView *self, SEL _cmd) {
    withPinnedFrame(self.window, ^{ ((void (*)(id, SEL))origFindBarDidChangeHeight)(self, _cmd); });
}

// OSC 52 (ESC ] 52 ; <selection> ; <base64> BEL/ST): lets remote programs (vim, tmux over ssh) set the clipboard.
// Terminal's parser already hands every OSC to performOperatingSystemCommand with the number in _params[0] and
// the text after it in _operatingSystemCommand; it just ignores 52. Read requests ("?") are refused on purpose.
static const NSUInteger kOSC52MaxBytes = 1 << 20;
static IMP origPerformOSC;
static Ivar oscParamsIvar, oscStringIvar;

static void performOSC(id self, SEL _cmd) {
    const int *params = (const int *)((char *)(__bridge void *)self + ivar_getOffset(oscParamsIvar));
    NSString *s = object_getIvar(self, oscStringIvar);
    if (params[0] == 52 && s) {
        NSRange semi = [s rangeOfString:@";"];
        NSString *payload = semi.location == NSNotFound ? nil : [s substringFromIndex:NSMaxRange(semi)];
        if (payload.length && ![payload isEqualToString:@"?"] && payload.length <= kOSC52MaxBytes * 4 / 3 + 4) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:NSDataBase64DecodingIgnoreUnknownCharacters];
            NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            if (text.length) {
                NSPasteboard *pb = NSPasteboard.generalPasteboard;
                [pb clearContents];
                [pb setString:text forType:NSPasteboardTypeString];
            }
        }
    }
    ((void (*)(id, SEL))origPerformOSC)(self, _cmd);
}

static void installOSC52(void) {
    Class c = NSClassFromString(@"TTVT100Emulator");
    oscParamsIvar = class_getInstanceVariable(c, "_params");
    oscStringIvar = class_getInstanceVariable(c, "_operatingSystemCommand");
    Method m = class_getInstanceMethod(c, NSSelectorFromString(@"performOperatingSystemCommand"));
    if (m && oscParamsIvar && oscStringIvar && !strcmp(ivar_getTypeEncoding(oscParamsIvar), "[32i]")) {
        origPerformOSC = method_setImplementation(m, (IMP)performOSC);
    }
}

__attribute__((constructor)) static void init(void) {
    installOSC52();
    Method geometry = class_getInstanceMethod(NSClassFromString(@"TTWindowController"), NSSelectorFromString(@"updateWindowGeometry"));
    if (geometry) origUpdateGeometry = method_setImplementation(geometry, (IMP)stableUpdateGeometry);

    Method findVisible = class_getInstanceMethod(NSClassFromString(@"TTPane"), NSSelectorFromString(@"setFindBarVisible:"));
    if (findVisible) origSetFindBarVisible = method_setImplementation(findVisible, (IMP)stableSetFindBarVisible);

    Method findHeight = class_getInstanceMethod(NSClassFromString(@"TTPane"), NSSelectorFromString(@"findBarViewDidChangeHeight"));
    if (findHeight) origFindBarDidChangeHeight = method_setImplementation(findHeight, (IMP)stableFindBarDidChangeHeight);

    Method zoom = class_getInstanceMethod(NSClassFromString(@"TTWindowController"), @selector(windowWillUseStandardFrame:defaultFrame:));
    if (zoom) method_setImplementation(zoom, (IMP)fullStandardFrame);

    Method add = class_getInstanceMethod([NSWindow class], @selector(addTitlebarAccessoryViewController:));
    origAddAccessory = method_setImplementation(add, (IMP)tabAddAccessory);
#ifdef TERMINL_DEBUG
    fprintf(stderr, "terminl loaded\n");
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
        installPalette();
        installKeys();
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidResizeNotification, NSWindowDidBecomeMainNotification]) {
            [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
                fixWindow(note.object);
            }];
        }
        // turn this off until edge case needs it
        // [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { fixAll(); }];
#ifdef TERMINL_DEBUG
        if (getenv("TERMINL_DUMP")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                for (NSWindow *w in NSApp.windows) if (!findTTView(w.contentView)) { fprintf(stderr, "other window %s '%s' key=%d\n", NSStringFromClass([w class]).UTF8String, w.title.UTF8String, w.isKeyWindow); for (NSView *v in w.contentView.subviews) if ([v isKindOfClass:[NSTextField class]]) fprintf(stderr, "   text: %s\n", [(NSTextField *)v stringValue].UTF8String); }
                [NSApp activateIgnoringOtherApps:YES];
                for (NSWindow *w in NSApp.windows) if (findTTView(w.contentView)) { [w makeKeyAndOrderFront:nil]; [NSApp sendAction:NSSelectorFromString(@"newTab:") to:w.windowController from:nil]; break; }
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                for (NSWindow *w in NSApp.windows) if (findTTView(w.contentView)) {
                    [w zoom:nil];
                    fprintf(stderr, "zoomed %s visible %s\n", NSStringFromRect(w.frame).UTF8String, NSStringFromRect(w.screen.visibleFrame).UTF8String);
                }
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                for (NSWindow *w in NSApp.windows) { NSView *tt = findTTView(w.contentView); if (tt) fprintf(stderr, "bg=%s transparent=%d winbg=%s\n", [terminalBackground(tt) description].UTF8String, w.titlebarAppearsTransparent, w.backgroundColor.description.UTF8String); }
                for (NSWindow *w in NSApp.windows) if (findTTView(w.contentView)) fprintf(stderr, "windowNumber %ld tabs=%lu\n", (long)w.windowNumber, (unsigned long)w.tabGroup.windows.count);
                for (NSWindow *w in NSApp.windows) dump(w.contentView.superview, 0);
            });
        }
#endif
    });
}
