// Command palette (Cmd+Shift+P): fuzzy search over every enabled item in the main menu.
#import <Cocoa/Cocoa.h>

static const CGFloat kPaletteWidth = 560, kPaletteFieldHeight = 46, kPaletteRowHeight = 32, kPalettePadding = 8;
static const NSInteger kPaletteMaxRows = 10;

@interface TerminlPaletteItem : NSObject
@property (strong) NSMenuItem *menuItem;
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
            p.menuItem = item;
            p.title = item.title;
            p.path = path;
            p.shortcut = paletteShortcut(item);
            [out addObject:p];
        }
    }
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
    NSMutableArray *items = [NSMutableArray array];
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
    NSMenuItem *menuItem = item.menuItem;
    // Next turn, so the action's responder chain starts at the restored terminal window, not the search field.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger index = [menuItem.menu indexOfItem:menuItem];
        if (index >= 0) [menuItem.menu performActionForItemAtIndex:index];
    });
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
    if (command == @selector(moveDown:)) [self moveSelection:1];
    else if (command == @selector(moveUp:)) [self moveSelection:-1];
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
