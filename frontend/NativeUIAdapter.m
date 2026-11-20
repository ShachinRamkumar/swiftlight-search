#import "NativeUIAdapter.h"

static NSImage *iconForItem(LauncherResultItem *item) {
    if (item.icon) return item.icon;
    if (item.identifier.length && [item.identifier hasPrefix:@"/"]) {
        return [NSWorkspace.sharedWorkspace iconForFile:item.identifier];
    }
    return [NSImage imageWithSystemSymbolName:@"doc" accessibilityDescription:@"File"];
}

static NSImage *applicationCategoryBadge(void) {
    static NSImage *badge;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSImageSymbolConfiguration *config =
            [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightMedium];
        NSImage *symbol = [NSImage imageWithSystemSymbolName:@"square.grid.2x2"
                                    accessibilityDescription:@"Application"];
        badge = [symbol imageWithSymbolConfiguration:config] ?: symbol;
        badge.template = YES;
    });
    return badge;
}

@implementation LauncherResultItem
- (instancetype)init {
    if ((self = [super init])) {
        _identifier = NSUUID.UUID.UUIDString;
        _title = @"";
        _completion = @"";
        _subtitle = @"";
        _actionLabel = @"Open";
    }
    return self;
}
@end

@interface InlineCompletionController : NSViewController
@property(nonatomic, strong) NSTextField *overlayLabel;
@property(nonatomic, strong) NSImageView *iconView;
@end

@implementation InlineCompletionController
- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 449, 30)];
    container.wantsLayer = YES;

    _overlayLabel = [NSTextField labelWithString:@""];
    _overlayLabel.font = [NSFont preferredFontForTextStyle:NSFontTextStyleTitle1 options:@{}];
    _overlayLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _overlayLabel.maximumNumberOfLines = 1;
    _overlayLabel.frame = NSMakeRect(0, 0, 405, 30);
    _overlayLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:_overlayLabel];

    _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(417, 0, 30, 30)];
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _iconView.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    [container addSubview:_iconView];

    self.view = container;
}

- (void)updateWithQuery:(NSAttributedString *)query
           selectedItem:(nullable LauncherResultItem *)item
                focused:(BOOL)focused {
    (void)self.view;
    NSFont *font = [NSFont preferredFontForTextStyle:NSFontTextStyleTitle1 options:@{}];
    NSString *typed = query.string ?: @"";
    if (!item || !typed.length || !item.completion.length) {
        _overlayLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:@""];
        _iconView.image = nil;
        return;
    }

    NSMutableAttributedString *display = [[NSMutableAttributedString alloc] init];
    NSRange prefix = [item.completion rangeOfString:typed options:(NSAnchoredSearch | NSCaseInsensitiveSearch)];
    if (prefix.location == 0 && item.completion.length > typed.length) {
        NSString *suffix = [item.completion substringFromIndex:NSMaxRange(prefix)];
        [display appendAttributedString:[[NSAttributedString alloc] initWithString:typed attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: NSColor.clearColor,
        }]];
        NSMutableDictionary *suffixAttrs = [@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        } mutableCopy];
        if (focused) {
            suffixAttrs[NSBackgroundColorAttributeName] = [NSColor.whiteColor colorWithAlphaComponent:0.12];
        }
        [display appendAttributedString:[[NSAttributedString alloc] initWithString:suffix attributes:suffixAttrs]];
    } else {
        NSString *hint = [NSString stringWithFormat:@"%@ — %@", typed, item.title];
        [display appendAttributedString:[[NSAttributedString alloc] initWithString:typed attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: NSColor.clearColor,
        }]];
        [display appendAttributedString:[[NSAttributedString alloc] initWithString:[hint substringFromIndex:typed.length] attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        }]];
    }
    _overlayLabel.attributedStringValue = display;
    _iconView.image = iconForItem(item);
}
@end

@interface SearchResultRowView : NSView
@property(nonatomic, copy) NSString *itemIdentifier;
@property(nonatomic) BOOL highlighted;
@property(nonatomic, strong) NSImageView *iconView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *subtitleLabel;
@property(nonatomic, strong) NSImageView *badgeView;
- (void)configureWithItem:(LauncherResultItem *)item highlighted:(BOOL)highlighted;
@end

@implementation SearchResultRowView
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 14;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 11, 36, 36)];
        _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        [self addSubview:_iconView];

        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
        _titleLabel.textColor = NSColor.labelColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.maximumNumberOfLines = 1;
        [self addSubview:_titleLabel];

        _subtitleLabel = [NSTextField labelWithString:@""];
        _subtitleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        _subtitleLabel.textColor = NSColor.secondaryLabelColor;
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _subtitleLabel.maximumNumberOfLines = 1;
        [self addSubview:_subtitleLabel];

        _badgeView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 22, 22)];
        _badgeView.imageScaling = NSImageScaleProportionallyDown;
        _badgeView.contentTintColor = NSColor.secondaryLabelColor;
        _badgeView.hidden = YES;
        [self addSubview:_badgeView];
    }
    return self;
}

- (void)configureWithItem:(LauncherResultItem *)item highlighted:(BOOL)highlighted {
    _itemIdentifier = [item.identifier copy];
    _highlighted = highlighted;
    _iconView.image = iconForItem(item);
    _titleLabel.stringValue = item.title ?: @"";
    _subtitleLabel.stringValue = item.subtitle ?: @"";
    _subtitleLabel.hidden = item.subtitle.length == 0;
    _badgeView.hidden = !item.application;
    _badgeView.image = item.application ? applicationCategoryBadge() : nil;
    self.layer.backgroundColor = highlighted
        ? [NSColor.whiteColor colorWithAlphaComponent:0.16].CGColor
        : NSColor.clearColor.CGColor;
    [self setNeedsLayout:YES];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat trailing = _badgeView.hidden ? 16 : 48;
    CGFloat textX = 64;
    CGFloat textW = MAX(40, width - textX - trailing);
    _iconView.frame = NSMakeRect(16, round((height - 36) / 2.0), 36, 36);
    if (_subtitleLabel.hidden) {
        _titleLabel.frame = NSMakeRect(textX, round((height - 20) / 2.0), textW, 20);
    } else {
        _titleLabel.frame = NSMakeRect(textX, round(height / 2.0) + 1, textW, 20);
        _subtitleLabel.frame = NSMakeRect(textX, round(height / 2.0) - 17, textW, 16);
    }
    _badgeView.frame = NSMakeRect(width - 38, round((height - 22) / 2.0), 22, 22);
}
@end

@interface FlippedClipDocumentView : NSView
@end
@implementation FlippedClipDocumentView
- (BOOL)isFlipped { return YES; }
@end

@implementation SearchNativeUI
+ (NSViewController *)completionController {
    return [InlineCompletionController new];
}

+ (nullable NSString *)resultIdentifierAtWindowPoint:(NSPoint)point inView:(NSView *)view {
    if ([view isKindOfClass:SearchResultRowView.class]) {
        SearchResultRowView *row = (SearchResultRowView *)view;
        NSPoint local = [row convertPoint:point fromView:nil];
        if (NSPointInRect(local, row.visibleRect)) return row.itemIdentifier;
        return nil;
    }
    for (NSView *child in view.subviews) {
        NSString *identifier = [self resultIdentifierAtWindowPoint:point inView:child];
        if (identifier) return identifier;
    }
    return nil;
}

+ (void)updateCompletionController:(NSViewController *)controller
                             query:(NSAttributedString *)query
                      selectedItem:(nullable LauncherResultItem *)item
                           focused:(BOOL)focused {
    if ([controller isKindOfClass:InlineCompletionController.class]) {
        [(InlineCompletionController *)controller updateWithQuery:query selectedItem:item focused:focused];
    }
}
@end

@implementation SearchResultsController {
    NSScrollView *_scrollView;
    FlippedClipDocumentView *_documentView;
    NSMutableArray<SearchResultRowView *> *_rowViews;
    NSArray<LauncherResultItem *> *_items;
    NSString *_contentKey;
    NSString *_selectedIdentifier;
}

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _rowViews = [NSMutableArray array];
        _items = @[];
    }
    return self;
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 300)];
    root.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    _scrollView = [[NSScrollView alloc] initWithFrame:root.bounds];
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.scrollerStyle = NSScrollerStyleOverlay;
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _documentView = [[FlippedClipDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 520, 0)];
    _scrollView.documentView = _documentView;

    [root addSubview:_scrollView];
    self.view = root;
}

- (void)updateItems:(NSArray<LauncherResultItem *> *)items
              query:(NSString *)query
 selectedIdentifier:(nullable NSString *)identifier {
    (void)query;
    (void)self.view;
    NSMutableString *key = [NSMutableString string];
    for (LauncherResultItem *item in items) {
        [key appendFormat:@"%@|%@|%@|%d;", item.identifier, item.title, item.subtitle, item.application];
    }
    BOOL contentChanged = ![_contentKey isEqualToString:key];
    NSString *nextSelected = identifier ?: @"";
    if (!contentChanged && [_selectedIdentifier isEqualToString:nextSelected]) return;

    _selectedIdentifier = nextSelected;
    if (contentChanged) {
        _contentKey = key;
        _items = [items copy];
        for (SearchResultRowView *row in _rowViews) [row removeFromSuperview];
        [_rowViews removeAllObjects];

        CGFloat width = MAX(200, NSWidth(self.view.bounds));
        CGFloat rowHeight = 58;
        CGFloat rowGap = 4;
        CGFloat padX = 12;
        CGFloat padY = 12;
        CGFloat y = padY;
        for (LauncherResultItem *item in _items) {
            SearchResultRowView *row = [[SearchResultRowView alloc] initWithFrame:NSMakeRect(padX, y, width - padX * 2, rowHeight)];
            row.autoresizingMask = NSViewWidthSizable;
            [row configureWithItem:item highlighted:[item.identifier isEqualToString:_selectedIdentifier]];
            [_documentView addSubview:row];
            [_rowViews addObject:row];
            y += rowHeight + rowGap;
        }
        CGFloat contentHeight = _items.count ? (y - rowGap + padY) : 0;
        _documentView.frame = NSMakeRect(0, 0, width, MAX(contentHeight, NSHeight(_scrollView.contentView.bounds)));
    } else {
        for (NSUInteger i = 0; i < _rowViews.count && i < _items.count; i++) {
            LauncherResultItem *item = _items[i];
            BOOL selected = [item.identifier isEqualToString:_selectedIdentifier];
            [_rowViews[i] configureWithItem:item highlighted:selected];
            if (selected) {
                [_documentView scrollRectToVisible:NSInsetRect(_rowViews[i].frame, 0, -8)];
            }
        }
    }
}

- (NSRect)screenFrameForIdentifier:(NSString *)identifier {
    if (!identifier.length) return NSZeroRect;
    for (SearchResultRowView *row in _rowViews) {
        if (![row.itemIdentifier isEqualToString:identifier]) continue;
        NSRect visible = NSIntersectionRect(row.bounds, row.visibleRect);
        if (NSIsEmptyRect(visible)) return NSZeroRect;
        return [row.window convertRectToScreen:[row convertRect:visible toView:nil]];
    }
    return NSZeroRect;
}
@end
