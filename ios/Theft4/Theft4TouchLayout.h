#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Posted (main thread) whenever the shared touch layout model changes.
FOUNDATION_EXPORT NSNotificationName const Theft4TouchLayoutDidChangeNotification;

// User-adjustable touch pad layout. Positions are normalized (0..1) against
// the game window's landscape safe area, exactly like the built-in pad table.
// The layout is a live shared model: the on-screen pad reads it on every
// layout pass, so a saved change applies without restarting the game.
@class Theft4TouchControlSpec;
@class Theft4TouchLayoutSettings;

// One control row: label, normalized x/y/w/h, Xbox button bitmask, trigger.
@interface Theft4TouchControlSpec : NSObject
@property(nonatomic, copy) NSString *label;
@property(nonatomic) CGFloat x, y, w, h;
@property(nonatomic) uint16_t button;
@property(nonatomic) int trigger;
- (instancetype)copyOfSelf;
@end

// How the on-screen right (camera/aim) stick behaves:
// Floating — appears where the finger touches the right side of the screen;
// a quick tap on it presses R3. Fixed — a permanent circle at the resting
// spot; drag it to aim. Off — no visual; the legacy background swipe aims.
typedef NS_ENUM(NSInteger, Theft4TouchRightStickMode) {
    Theft4TouchRightStickModeFloating = 0,
    Theft4TouchRightStickModeFixed = 1,
    Theft4TouchRightStickModeOff = 2,
};

// Pad appearance/feel settings (the "Touch Pad v2" approved values):
// opacity 0.45, floating right stick, haptics on, press glow on.
@interface Theft4TouchLayoutSettings : NSObject
// 0.10...0.90; default 0.45.
@property(nonatomic) CGFloat opacity;
// Default Theft4TouchRightStickModeFloating.
@property(nonatomic) Theft4TouchRightStickMode rightStickMode;
// Light haptic on button press, stronger tap on R3. Default YES.
@property(nonatomic) BOOL hapticsEnabled;
// Pressed controls scale to 90% and get an amber glow. Default YES.
@property(nonatomic) BOOL pressAnimationEnabled;
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

// Appearance/feel settings, live + persisted (touch_settings.json).
@property(nonatomic, readonly) Theft4TouchLayoutSettings *settings;

// Replaces the live settings and persists them.
- (void)saveSettings:(Theft4TouchLayoutSettings *)settings;

// Reverts the settings to the approved v2 defaults (opacity 0.45,
// floating stick, haptics on, press glow on) and persists them.
- (void)resetSettingsToDefaults;

// YES when a custom layout is persisted on this device.
@property(nonatomic, readonly) BOOL hasCustomLayout;
@end

// Right (camera) stick geometry, shared by the in-game pad and the layout
// editor so both draw the stick at exactly the same place/size.
@interface Theft4TouchLayout (RightStickGeometry)
// .20 of the smaller area dimension, minimum 120pt.
+ (CGFloat)rightStickDiameterForArea:(CGRect)area;
// Where the floating-stick affordance ring rests (right of center).
+ (CGPoint)floatingRestCenterInArea:(CGRect)area;
// The permanent circle used by the Fixed mode.
+ (CGRect)fixedStickRectInArea:(CGRect)area;
@end
