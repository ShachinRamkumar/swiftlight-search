#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface LauncherResultItem : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *completion;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *actionLabel;
@property(nonatomic, copy, nullable) NSString *applicationBundleIdentifier;
@property(nonatomic) BOOL application;
@property(nonatomic, strong, nullable) NSImage *icon;
@end

@interface SearchNativeUI : NSObject
+ (NSViewController *)completionController;
+ (nullable NSString *)resultIdentifierAtWindowPoint:(NSPoint)point inView:(NSView *)view;
+ (void)updateCompletionController:(NSViewController *)controller
                             query:(NSAttributedString *)query
                      selectedItem:(nullable LauncherResultItem *)item
                           focused:(BOOL)focused;
@end

@interface SearchResultsController : NSViewController
@property(nonatomic, copy, nullable) void (^openItem)(NSString *identifier);
- (void)updateItems:(NSArray<LauncherResultItem *> *)items
              query:(NSString *)query
 selectedIdentifier:(nullable NSString *)identifier;
/// The on-screen frame of a visible row, or NSZeroRect when it is scrolled out of view.
- (NSRect)screenFrameForIdentifier:(NSString *)identifier;
@end

@interface PanelPresentation : NSObject
+ (void)resetWindow:(NSWindow *)window;
+ (CAAnimationGroup *)scaleAnimationForOpening:(BOOL)opening collapsed:(BOOL)collapsed;
+ (void)animateWindow:(NSWindow *)window
              opening:(BOOL)opening
             duration:(double)duration
           completion:(void (^)(void))completion;
@end

NS_ASSUME_NONNULL_END
