#import <Foundation/Foundation.h>

// Posted (main thread) whenever the shared touch layout model changes.
FOUNDATION_EXPORT NSNotificationName const Theft4TouchLayoutDidChangeNotification;

// User-adjustable touch pad layout. Positions are normalized (0..1) against
// the game window's landscape safe area, exactly like the built-in pad table.
// The layout is a live shared model: the on-screen pad reads it on every
// layout pass, so a saved change applies without restarting the game.
@class Theft4TouchControlSpec;

// One control row: label, normalized x/y/w/h, Xbox button bitmask, trigger.
@interface Theft4TouchControlSpec : NSObject
@property(nonatomic, copy) NSString *label;
@property(nonatomic) CGFloat x, y, w, h;
@property(nonatomic) uint16_t button;
@property(nonatomic) int trigger;
- (instancetype)copyOfSelf;
@end

@interface Theft4TouchLayout : NSObject

// The 17 built-in controls, in fixed order (index 0 is the movement stick).
+ (NSArray<Theft4TouchControlSpec *> *)defaultSpecs;

// Live shared model. Main thread only (UI + game overlay).
+ (Theft4TouchLayout *)shared;

// Current specs (defaults until the user saves a custom layout).
@property(nonatomic, readonly) NSArray<Theft4TouchControlSpec *> *specs;

// Monotonic counter; increments whenever the model changes.
@property(nonatomic, readonly) NSInteger revision;

// Replaces the live model without persisting (used for editor previews).
- (void)applySpecs:(NSArray<Theft4TouchControlSpec *> *)specs;

// Replaces the live model and persists it to the app container.
- (void)saveSpecs:(NSArray<Theft4TouchControlSpec *> *)specs;

// Drops any saved layout; the model reverts to the built-in table.
- (void)resetToDefaults;

// YES when a custom layout is persisted on this device.
@property(nonatomic, readonly) BOOL hasCustomLayout;
@end
