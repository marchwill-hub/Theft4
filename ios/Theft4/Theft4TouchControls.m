// Layout and analog math adapted from XeniOS touch_layout_ios_defaults.cc and
// touch_input_resolver.cc, copyright 2026 Ben Vanik. BSD-3-Clause; see bundled
// XeniOS-Touch-LICENSE.txt. UIKit capture/bridge integration is Theft4-specific.
//
// Touch Pad v2 (build 152):
//  - global pad opacity (Theft4TouchLayoutSettings.opacity);
//  - press feedback: controls scale to 90% and an amber ring glows OUTSIDE
//    their bounds (the finger covers the center), per Apple's WWDC24 touch
//    guidance;
//  - haptics: light impact on button press, medium when a camera stick
//    engages, selection click on an R3 stick tap;
//  - visible right (camera) stick in three modes:
//      Floating — materializes where the finger touches the right side of
//                 the screen; drag = analog camera, quick tap = R3;
//      Fixed    — a permanent circle (see RightStickGeometry); drag = analog
//                 camera, quick tap = R3;
//      Off      — no visual; the legacy background swipe aims.
//  Left-side background touches stay swipe-look in every mode. The bridge
//  contract (theft4_touch_pad: lx/ly/rx/ry int16, buttons, triggers) is
//  unchanged — the sticks feed the same axes a physical gamepad would.
#import "Theft4TouchControls.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include "theft4_touch_input.h"
#import "Theft4TouchLayout.h"

static const NSInteger kPadControlCount = 17;

// Background capture kinds (negative so they never collide with a control
// index).
static const NSInteger kCaptureLook = -1;       // legacy swipe-look
static const NSInteger kCaptureFloatStick = -2; // floating camera stick
static const NSInteger kCaptureFixedStick = -3; // fixed camera stick

// Pressed-state timing (seconds), R3 tap thresholds, click length in frames.
static const NSTimeInterval kPressIn = 0.08;
static const NSTimeInterval kPressOut = 0.12;
static const NSTimeInterval kStickTapWindow = 0.25;
static const CGFloat kStickTapTravel = 10.0;
static const NSInteger kR3TapFrames = 4;
// Faint affordance ring shown while the floating stick is idle.
static const CGFloat kFloatingGhostAlpha = 0.10;

static inline Theft4TouchControlSpec *PadSpec(NSInteger i) {
    return [[Theft4TouchLayout shared].specs objectAtIndex:i];
}

static inline UIColor *PadAmber(void) {
    return [UIColor colorWithRed:0xE6 / 255.0 green:0xB5 / 255.0 blue:0x6B / 255.0
                         alpha:1.0];
}

// Context color for the camera-stick ring: amber while it steers (drive
// context), white while it aims or sits neutral.
static inline UIColor *CameraStickColor(BOOL steering) {
    return steering ? PadAmber() : [UIColor colorWithWhite:1 alpha:.55];
}

@interface Theft4TouchControls () {
    NSMutableArray<UILabel *> *_labels;
    NSMutableArray<UIView *> *_glows;
    NSMapTable<UITouch *, NSNumber *> *_captures;
    UIView *_stickKnob;
    NSTimer *_lookTimer;
    CGPoint _lookDelta;
    int16_t _lookX, _lookY;
    CFTimeInterval _lastTick;
    CGRect _lastBounds;
    UIEdgeInsets _lastInsets;
    // Cached settings (refreshed on every layout pass).
    CGFloat _opacity;
    BOOL _pressAnim;
    BOOL _hapticsOn;
    Theft4TouchRightStickMode _stickMode;
    BOOL _glowOn[kPadControlCount];
    UIImpactFeedbackGenerator *_hapticLight;
    UIImpactFeedbackGenerator *_hapticMedium;
    UISelectionFeedbackGenerator *_hapticSelect;
    // Camera stick visuals + drag bookkeeping.
    UIView *_rightBase;
    UIView *_rightKnob;
    CGPoint _floatOrigin;
    CFTimeInterval _floatBegan;
    CGFloat _floatMaxTravel;
    CFTimeInterval _fixedBegan;
    CGFloat _fixedMaxTravel;
    NSInteger _r3TapFrames;
    CGRect _fixedStickRect;
    // Contextual stick roles (build 153).
    BOOL _driveContext; // RT or LT held
    BOOL _aimContext;   // X (aim) held
}
@end

@implementation Theft4TouchControls
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.hidden = YES;
        self.accessibilityIdentifier = @"game.touchControls";
        _captures = [NSMapTable strongToStrongObjectsMapTable];
        _labels = [NSMutableArray new];
        _glows = [NSMutableArray new];
        Theft4TouchLayoutSettings *s = [Theft4TouchLayout shared].settings;
        _opacity = s.opacity;
        _pressAnim = s.pressAnimationEnabled;
        _hapticsOn = s.hapticsEnabled;
        _stickMode = s.rightStickMode;
        _hapticLight =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        _hapticMedium =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        _hapticSelect = [[UISelectionFeedbackGenerator alloc] init];
        [[NSNotificationCenter defaultCenter]
            addObserver:self selector:@selector(touchLayoutDidChange)
                   name:Theft4TouchLayoutDidChangeNotification object:nil];
        for (NSInteger i = 0; i < kPadControlCount; ++i) {
            UILabel *label = [UILabel new];
            label.text = PadSpec(i).label;
            label.textAlignment = NSTextAlignmentCenter;
            label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            label.adjustsFontSizeToFitWidth = YES;
            label.textColor = UIColor.whiteColor;
            label.backgroundColor = [UIColor colorWithWhite:0 alpha:.25];
            label.layer.borderColor = [UIColor colorWithWhite:1 alpha:.55].CGColor;
            label.layer.borderWidth = 1.5;
            label.layer.masksToBounds = YES;
            label.userInteractionEnabled = NO;
            [self addSubview:label];
            UIView *glow = [UIView new];
            glow.userInteractionEnabled = NO;
            glow.backgroundColor = [UIColor clearColor];
            glow.layer.borderWidth = 3.0;
            glow.layer.borderColor = PadAmber().CGColor;
            glow.alpha = 0;
            [self insertSubview:glow belowSubview:label];
            [_labels addObject:label];
            [_glows addObject:glow];
        }
        _stickKnob = [UIView new];
        _stickKnob.userInteractionEnabled = NO;
        _stickKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:.25];
        [self addSubview:_stickKnob];
        _rightBase = [UIView new];
        _rightBase.userInteractionEnabled = NO;
        _rightBase.backgroundColor = [UIColor colorWithWhite:1 alpha:.08];
        _rightBase.layer.borderColor = [UIColor colorWithWhite:1 alpha:.55].CGColor;
        _rightBase.layer.borderWidth = 2.0;
        _rightBase.alpha = 0;
        _rightBase.hidden = YES;
        [self addSubview:_rightBase];
        _rightKnob = [UIView new];
        _rightKnob.userInteractionEnabled = NO;
        _rightKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:.35];
        _rightKnob.alpha = 0;
        _rightKnob.hidden = YES;
        [self addSubview:_rightKnob];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGRectEqualToRect(_lastBounds, self.bounds) ||
        !UIEdgeInsetsEqualToEdgeInsets(_lastInsets, self.safeAreaInsets)) {
        [self releaseAllTouches];
        _lastBounds = self.bounds;
        _lastInsets = self.safeAreaInsets;
    }
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    // Re-read settings on every layout pass (notification-driven).
    Theft4TouchLayoutSettings *s = [Theft4TouchLayout shared].settings;
    if (s.opacity != _opacity || s.rightStickMode != _stickMode ||
        s.pressAnimationEnabled != _pressAnim || s.hapticsEnabled != _hapticsOn) {
        _opacity = s.opacity;
        _stickMode = s.rightStickMode;
        _pressAnim = s.pressAnimationEnabled;
        _hapticsOn = s.hapticsEnabled;
        [self releaseAllTouches]; // drop captures tied to the old mode
    }
    for (NSInteger i = 0; i < kPadControlCount; ++i) {
        Theft4TouchControlSpec *c = PadSpec(i);
        UILabel *label = _labels[i];
        if (![label.text isEqualToString:c.label]) label.text = c.label;
        CGFloat w = MAX(36, c.w * area.size.width);
        CGFloat h = MAX(36, c.h * area.size.height);
        // Circular movement pad; landscape positions remain proportional.
        if (i == 0) w = h = MIN(w, h);
        label.frame = CGRectMake(area.origin.x + c.x * area.size.width,
            area.origin.y + c.y * area.size.height, w, h);
        label.layer.cornerRadius = i == 0 ? w / 2 : MIN(w, h) / 3;
        // Opacity-scaled styling: at the 0.45 default this reproduces the
        // original 0.25 fill / 0.55 border exactly.
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55 * _opacity];
        label.layer.borderColor =
            [UIColor colorWithWhite:1 alpha:MIN(1.0, 1.22 * _opacity)].CGColor;
        UIView *glow = _glows[i];
        glow.frame = CGRectInset(label.frame, -6, -6);
        glow.layer.cornerRadius = label.layer.cornerRadius + 6;
    }
    CGFloat diameter = _labels[0].bounds.size.width * .36;
    _stickKnob.bounds = CGRectMake(0, 0, diameter, diameter);
    _stickKnob.layer.cornerRadius = diameter / 2;
    _stickKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55 * _opacity];
    _stickKnob.center = _labels[0].center;
    _fixedStickRect = [Theft4TouchLayout fixedStickRectInArea:area];
    [self updateCameraStickVisuals];
}
- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    self.hidden = !active;
    [self releaseAllTouches];
    [_lookTimer invalidate];
    _lookTimer = nil;
    if (active) {
        _lastTick = CACurrentMediaTime();
        __weak Theft4TouchControls *weakSelf = self;
        _lookTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES
            block:^(NSTimer *timer) { [weakSelf publishTouchState]; }];
        [NSRunLoop.mainRunLoop addTimer:_lookTimer forMode:NSRunLoopCommonModes];
    }
}
- (void)releaseAllTouches {
    [_captures removeAllObjects];
    _lookDelta = CGPointZero;
    _lookX = _lookY = 0;
    _r3TapFrames = 0;
    _floatMaxTravel = _fixedMaxTravel = 0;
    _driveContext = _aimContext = NO;
    for (NSInteger i = 0; i < kPadControlCount; ++i) {
        if (_glowOn[i]) [self setPressedVisual:i pressed:NO];
        _glowOn[i] = NO;
    }
    [self hideCameraStick];
    theft4_touch_reset();
    _stickKnob.center = _labels[0].center;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active) return;
    if (_hapticsOn) {
        [_hapticLight prepare];
        [_hapticMedium prepare];
        [_hapticSelect prepare];
    }
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CFTimeInterval now = CACurrentMediaTime();
    for (UITouch *touch in touches) {
        CGPoint p = [touch locationInView:self];
        NSInteger capture = kCaptureLook; // Unoccupied background is swipe-to-look.
        for (NSInteger i = kPadControlCount - 1; i >= 0; --i) {
            if (CGRectContainsPoint(_labels[i].frame, p)) { capture = i; break; }
        }
        if (capture == kCaptureLook) {
            if (_stickMode == Theft4TouchRightStickModeFloating &&
                p.x >= area.origin.x + area.size.width / 2.0) {
                capture = kCaptureFloatStick;
                _floatOrigin = p;
                _floatBegan = now;
                _floatMaxTravel = 0;
                [self placeCameraStickAt:p animate:YES knobOffset:CGPointZero radius:0];
                if (_hapticsOn) [_hapticMedium impactOccurred];
            } else if (_stickMode == Theft4TouchRightStickModeFixed &&
                       CGRectContainsPoint(CGRectInset(_fixedStickRect, -14, -14), p)) {
                capture = kCaptureFixedStick;
                _fixedBegan = now;
                _fixedMaxTravel = 0;
                if (_hapticsOn) [_hapticMedium impactOccurred];
            }
        }
        // Only one movement, one look, one floating and one fixed stick;
        // buttons are independently held.
        if ((capture == 0 || capture == kCaptureLook ||
             capture == kCaptureFloatStick || capture == kCaptureFixedStick) &&
            [[_captures.objectEnumerator allObjects] containsObject:@(capture)])
            continue;
        [_captures setObject:@(capture) forKey:touch];
        if (capture >= 0 && _hapticsOn) [_hapticLight impactOccurred];
    }
    [self publishButtonsAndMovement];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active) return;
    for (UITouch *touch in touches) {
        NSNumber *capture = [_captures objectForKey:touch];
        if (!capture) continue;
        CGPoint p = [touch locationInView:self],
                previous = [touch previousLocationInView:self];
        if (capture.integerValue == kCaptureLook) {
            _lookDelta.x += p.x - previous.x;
            _lookDelta.y += p.y - previous.y;
        } else if (capture.integerValue == kCaptureFloatStick) {
            _floatMaxTravel = MAX(_floatMaxTravel,
                                  hypot(p.x - _floatOrigin.x, p.y - _floatOrigin.y));
        } else if (capture.integerValue == kCaptureFixedStick) {
            _fixedMaxTravel = MAX(_fixedMaxTravel,
                                  hypot(p.x - _fixedStickRect.center.x,
                                        p.y - _fixedStickRect.center.y));
        }
    }
    [self publishButtonsAndMovement];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CFTimeInterval now = CACurrentMediaTime();
    for (UITouch *touch in touches) {
        NSNumber *capture = [_captures objectForKey:touch];
        NSInteger kind = capture ? capture.integerValue : kCaptureLook;
        if (kind == kCaptureLook) {
            _lookDelta = CGPointZero;
            _lookX = _lookY = 0;
        } else if (kind == kCaptureFloatStick || kind == kCaptureFixedStick) {
            BOOL quickTap =
                (now - (kind == kCaptureFloatStick ? _floatBegan : _fixedBegan) <
                 kStickTapWindow) &&
                ((kind == kCaptureFloatStick ? _floatMaxTravel : _fixedMaxTravel) <
                 kStickTapTravel);
            if (quickTap) {
                // A quick tap on the camera stick clicks R3 (stick click).
                _r3TapFrames = kR3TapFrames;
                if (_hapticsOn) [_hapticSelect selectionChanged];
            }
            [self hideCameraStick];
        }
        [_captures removeObjectForKey:touch];
    }
    [self publishButtonsAndMovement];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

// Pressed styling: brightened fill always; scale + outer amber glow when the
// press animation is enabled. Animates only on state transitions.
- (void)setPressedVisual:(NSInteger)i pressed:(BOOL)pressed {
    UILabel *label = _labels[i];
    UIView *glow = _glows[i];
    if (pressed) {
        label.backgroundColor =
            [UIColor colorWithWhite:0 alpha:MIN(1.0, 0.55 * _opacity + 0.35)];
        if (_pressAnim) {
            [UIView animateWithDuration:kPressIn animations:^{
                label.transform = CGAffineTransformMakeScale(0.90, 0.90);
                glow.alpha = 0.85;
            }];
        }
    } else {
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55 * _opacity];
        if (_pressAnim) {
            [UIView animateWithDuration:kPressOut animations:^{
                label.transform = CGAffineTransformIdentity;
                glow.alpha = 0;
            }];
        }
    }
}

- (theft4_touch_pad)buttonsAndMovement {
    theft4_touch_pad state = {0};
    BOOL pressed[kPadControlCount] = {0};
    for (UITouch *touch in _captures) {
        NSInteger i = [[_captures objectForKey:touch] integerValue];
        if (i < 0) continue;
        CGPoint p = [touch locationInView:self];
        if (i == 0) {
            CGPoint center = _labels[0].center;
            CGFloat radius = MAX(1, _labels[0].bounds.size.width * .48);
            CGFloat x = (p.x - center.x) / radius, y = (center.y - p.y) / radius;
            CGFloat magnitude = hypot(x, y);
            CGFloat strength = MIN(1, MAX(0, (magnitude - .14) / .86));
            if (magnitude > 0) { x = x / magnitude * strength; y = y / magnitude * strength; }
            state.lx = (int16_t)lround(x * 32767);
            state.ly = (int16_t)lround(y * 32767);
            _stickKnob.center =
                CGPointMake(center.x + x * radius * .65, center.y - y * radius * .65);
            if (strength > 0) pressed[0] = YES;
        } else if (CGRectContainsPoint(CGRectInset(_labels[i].frame, -10, -10), p)) {
            Theft4TouchControlSpec *c = PadSpec(i);
            state.buttons |= c.button;
            if (c.trigger == 1) state.left_trigger = 255;
            if (c.trigger == 2) state.right_trigger = 255;
            pressed[i] = YES;
        }
    }
    for (NSInteger i = 0; i < kPadControlCount; ++i) {
        if (pressed[i] != _glowOn[i]) {
            _glowOn[i] = pressed[i];
            [self setPressedVisual:i pressed:pressed[i]];
        }
    }
    // Contextual stick roles (build 153): X (aim) held = aim context;
    // RT/LT held = drive context. The camera stick follows the active
    // context, updated on every press/hold/release pass.
    _aimContext = (state.buttons & 0x4000) != 0;
    _driveContext = (state.right_trigger > 0) || (state.left_trigger > 0);
    return state;
}

// While a floating/fixed stick is held it is the direct analog vector (like
// a physical gamepad). Role by context (build 153):
//   X (aim) held, or neutral  -> aims the camera (rx/ry);
//   RT/LT held without aim    -> steers the vehicle (lx/ly): acceleration /
//   reverse keep coming from the triggers, so throttle, reverse and steering
//   act as three independent inputs at once (like the physical controller).
- (void)applyCameraStickToState:(theft4_touch_pad *)state {
    for (UITouch *touch in _captures) {
        NSInteger kind = [[_captures objectForKey:touch] integerValue];
        if (kind != kCaptureFloatStick && kind != kCaptureFixedStick) continue;
        CGPoint p = [touch locationInView:self];
        CGPoint origin = kind == kCaptureFloatStick
            ? _floatOrigin : _fixedStickRect.center;
        CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:
            UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets)];
        CGFloat radius = MAX(1, d / 2.0);
        CGFloat dx = p.x - origin.x, dy = p.y - origin.y;
        CGFloat mag = hypot(dx, dy);
        CGFloat norm = MIN(1.0, mag / radius);
        CGFloat vx = (mag > 0) ? dx / mag * norm : 0.0;
        CGFloat vy = (mag > 0) ? -dy / mag * norm : 0.0;
        if (_driveContext && !_aimContext) {
            // Steer: left-axis analog. Same arbitration as the stock
            // MergeStick — the larger deflection wins, so a simultaneously
            // held movement pad is never silently clobbered.
            int16_t sx = (int16_t)lround(vx * 32767);
            int16_t sy = (int16_t)lround(vy * 32767);
            int64_t stickMag = (int64_t)sx * sx + (int64_t)sy * sy;
            int64_t curMag = (int64_t)state->lx * state->lx +
                             (int64_t)state->ly * state->ly;
            if (stickMag > curMag) { state->lx = sx; state->ly = sy; }
        } else {
            state->rx = (int16_t)lround(vx * 32767);
            state->ry = (int16_t)lround(vy * 32767);
        }
        [self placeCameraStickAt:origin animate:NO knobOffset:CGPointMake(dx, dy)
            radius:radius];
        return;
    }
}

- (void)publishButtonsAndMovement {
    // Immediate releases/buttons; camera deltas are consumed only by the timer.
    theft4_touch_pad state = [self buttonsAndMovement];
    state.rx = _lookX;
    state.ry = _lookY;
    theft4_touch_store(state);
    [self updateCameraStickVisuals];
}
- (void)publishTouchState {
    if (!_active) return;
    theft4_touch_pad state = [self buttonsAndMovement];
    BOOL stickDriven = NO;
    CFTimeInterval now = CACurrentMediaTime();
    double elapsed = MAX(1.0 / 240.0, now - _lastTick);
    _lastTick = now;
    for (UITouch *touch in _captures) {
        NSInteger kind = [[_captures objectForKey:touch] integerValue];
        if (kind == kCaptureFloatStick || kind == kCaptureFixedStick) {
            [self applyCameraStickToState:&state];
            stickDriven = YES;
            break;
        }
    }
    if (stickDriven) {
        // The stick owns the camera while held; drop any swipe accumulated
        // by a second finger so it cannot jump on release.
        _lookDelta = CGPointZero;
    } else {
        // Normalize swipe distance to a 60 Hz sample, independent of touch
        // delivery.
        double scale = 1.0 / (18.0 * elapsed * 60.0);
        state.rx = (int16_t)lround(MAX(-1, MIN(1, _lookDelta.x * scale)) * 32767);
        state.ry = (int16_t)lround(MAX(-1, MIN(1, -_lookDelta.y * scale)) * 32767);
        _lookX = state.rx;
        _lookY = state.ry;
        _lookDelta = CGPointZero;
    }
    if (_r3TapFrames > 0) {
        state.buttons |= 0x80; // R3
        _r3TapFrames -= 1;
    }
    theft4_touch_store(state);
    [self updateCameraStickVisuals];
}

// --- Camera stick visuals -------------------------------------------------
- (void)placeCameraStickAt:(CGPoint)origin animate:(BOOL)animate
                knobOffset:(CGPoint)offset radius:(CGFloat)radius {
    CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:
        UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets)];
    _rightBase.bounds = CGRectMake(0, 0, d, d);
    _rightBase.layer.cornerRadius = d / 2;
    _rightKnob.bounds = CGRectMake(0, 0, d * 0.36, d * 0.36);
    _rightKnob.layer.cornerRadius = d * 0.18;
    _rightBase.layer.borderColor =
        CameraStickColor(_driveContext && !_aimContext).CGColor;
    _rightBase.hidden = NO;
    _rightKnob.hidden = NO;
    if (radius > 0) {
        CGFloat mag = hypot(offset.x, offset.y);
        if (mag > radius) offset = CGPointMake(offset.x / mag * radius,
                                               offset.y / mag * radius);
    }
    if (animate) {
        [UIView animateWithDuration:0.09 animations:^{
            _rightBase.center = origin;
            _rightBase.alpha = 1.0;
            _rightKnob.center = origin;
            _rightKnob.alpha = 1.0;
        }];
    } else {
        _rightBase.center = origin;
        _rightBase.alpha = 1.0;
        _rightKnob.center = CGPointMake(origin.x + offset.x, origin.y + offset.y);
        _rightKnob.alpha = 1.0;
    }
}
- (void)hideCameraStick {
    CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:
        UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets)];
    _rightBase.bounds = CGRectMake(0, 0, d, d);
    _rightBase.layer.cornerRadius = d / 2;
    _rightKnob.bounds = CGRectMake(0, 0, d * 0.36, d * 0.36);
    _rightKnob.layer.cornerRadius = d * 0.18;
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    if (_stickMode == Theft4TouchRightStickModeFixed) {
        // The permanent circle stays; only the knob animates back to center.
        _rightBase.center = _fixedStickRect.center;
        _rightBase.layer.borderColor =
            CameraStickColor(_driveContext && !_aimContext).CGColor;
        _rightBase.alpha = 0.55;
        [UIView animateWithDuration:0.12 animations:^{
            _rightKnob.center = _fixedStickRect.center;
            _rightKnob.alpha = 0.55;
        }];
        return;
    }
    if (_stickMode == Theft4TouchRightStickModeFloating) {
        // Idle: faint affordance ring at the rest position (brighter —
        // "armed" — while a trigger is held and the stick steers).
        [UIView animateWithDuration:0.12 animations:^{
            _rightBase.center = [Theft4TouchLayout floatingRestCenterInArea:area];
            _rightBase.alpha = (_driveContext && !_aimContext)
                ? 0.30 : kFloatingGhostAlpha;
            _rightKnob.alpha = 0;
        }];
        return;
    }
    [UIView animateWithDuration:0.12 animations:^{
        _rightBase.alpha = 0;
        _rightKnob.alpha = 0;
    }];
}
- (void)updateCameraStickVisuals {
    // Called on layout changes and every 60 Hz tick; keeps the ghost /
    // fixed-stick visuals consistent with the current mode when idle.
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    BOOL stickHeld = NO;
    for (NSNumber *c in _captures.objectEnumerator) {
        if (c.integerValue == kCaptureFloatStick ||
            c.integerValue == kCaptureFixedStick) stickHeld = YES;
    }
    if (_stickMode == Theft4TouchRightStickModeOff) {
        if (!_rightBase.hidden || _rightBase.alpha > 0) {
            _rightBase.hidden = YES;
            _rightKnob.hidden = YES;
            _rightBase.alpha = 0;
            _rightKnob.alpha = 0;
        }
        return;
    }
    if (stickHeld) return; // placeCameraStickAt drives the visuals while held
    BOOL steering = _driveContext && !_aimContext;
    CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:area];
    _rightBase.bounds = CGRectMake(0, 0, d, d);
    _rightBase.layer.cornerRadius = d / 2;
    _rightKnob.bounds = CGRectMake(0, 0, d * 0.36, d * 0.36);
    _rightKnob.layer.cornerRadius = d * 0.18;
    _rightBase.layer.borderColor = CameraStickColor(steering).CGColor;
    _rightBase.hidden = NO;
    if (_stickMode == Theft4TouchRightStickModeFixed) {
        _rightKnob.hidden = NO;
        _rightBase.center = _fixedStickRect.center;
        _rightKnob.center = _fixedStickRect.center;
        _rightBase.alpha = 0.55;
        _rightKnob.alpha = 0.55;
        return;
    }
    _rightKnob.hidden = NO;
    _rightBase.center = [Theft4TouchLayout floatingRestCenterInArea:area];
    // Armed (a trigger is held): the ghost ring brightens to invite the
    // steering touch.
    _rightBase.alpha = steering ? 0.30 : kFloatingGhostAlpha;
    _rightKnob.alpha = 0;
}
- (void)touchLayoutDidChange { [self setNeedsLayout]; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_lookTimer invalidate];
}
@end
