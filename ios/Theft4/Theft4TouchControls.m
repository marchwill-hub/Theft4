// Layout and analog math adapted from XeniOS touch_layout_ios_defaults.cc and
// touch_input_resolver.cc, copyright 2026 Ben Vanik. BSD-3-Clause; see bundled
// XeniOS-Touch-LICENSE.txt. UIKit capture/bridge integration is Theft4-specific.
//
// Touch Pad v2 (build 154) — aligned to the approved mockup + user spec:
//  - Left stick FLOATS: a dashed "L-STICK" ghost rests at the Move spec
//    position; touch the left half of the screen and it materializes at the
//    touch point. Drag = analog (on foot = movement, in a car = steering —
//    the game resolves the axis, so throttle + steering work at once while
//    RT/LT is held). Quick tap = L3 flash. While RT/LT is held the ghost and
//    active ring turn amber ("armed to steer").
//  - Right stick: Floating / Fixed / Off (RightStickGeometry). Drag = camera
//    (rx/ry — the game resolves aim vs camera; the ring turns amber while X
//    is held). Quick tap = R3 flash.
//  - Press feedback per the mockup: 90% scale + amber fill/border + outer
//    glow ring; LT/RT additionally fill vertically while held.
//  - Global pad opacity (Theft4TouchLayoutSettings.opacity).
//  - Haptics: light on button press, medium on stick engage, selection on a
//    stick tap.
// State construction is a single pass (buildPadState) shared by the touch
// event path and the 60 Hz timer, so a finger moving a stick can never store
// a zeroed axis and cancel its own steering/camera signal.
// The bridge contract (theft4_touch_pad: lx/ly/rx/ry int16, buttons,
// triggers) is unchanged — both sticks feed the same axes a physical
// gamepad would.
#import "Theft4TouchControls.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include "theft4_touch_input.h"
#import "Theft4TouchLayout.h"

static const NSInteger kPadControlCount = 17;

// Background capture kinds (negative so they never collide with a control
// index).
static const NSInteger kCaptureLook = -1;       // legacy swipe-look (right side)
static const NSInteger kCaptureFloatStick = -2; // floating camera stick
static const NSInteger kCaptureFixedStick = -3; // fixed camera stick
static const NSInteger kCaptureMoveStick = -4;  // floating movement stick

// Pressed-state timing (seconds), stick tap thresholds, tap length in frames.
static const NSTimeInterval kPressIn = 0.08;
static const NSTimeInterval kStickTapWindow = 0.25;
static const CGFloat kStickTapTravel = 10.0;
static const NSInteger kStickTapFrames = 4;
// Dashed ghost visibility; armed ghosts brighten past this.
static const CGFloat kFloatingGhostAlpha = 0.30;
static const CGFloat kArmedGhostAlpha = 0.50;
// Left/right zone split (mockup: the right zone starts at 45% of the width).
static const CGFloat kLeftHalf = 0.45;

static inline Theft4TouchControlSpec *PadSpec(NSInteger i) {
    return [[Theft4TouchLayout shared].specs objectAtIndex:i];
}

static inline UIColor *PadAmber(void) {
    return [UIColor colorWithRed:0xE6 / 255.0 green:0xB5 / 255.0 blue:0x6B / 255.0
                         alpha:1.0];
}

// CGRect has no `center` member in Objective-C (Swift overlay only) —
// explicit midpoint.
static inline CGPoint RectCenter(CGRect r) {
    return CGPointMake(r.origin.x + r.size.width / 2.0,
                       r.origin.y + r.size.height / 2.0);
}

@interface Theft4TouchControls () {
    NSMutableArray<UILabel *> *_labels;
    NSMutableArray<UIView *> *_glows;
    NSMapTable<UITouch *, NSNumber *> *_captures;
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
    // LT/RT vertical fill (mockup "fillable").
    UIView *_triggerFillLT;
    UIView *_triggerFillRT;
    // Floating movement stick (left side).
    CGPoint _moveOrigin;
    CFTimeInterval _moveBegan;
    CGFloat _moveMaxTravel;
    UIView *_leftBase;
    UIView *_stickKnob;
    Theft4GhostView *_leftGhost;
    // Camera stick (right side).
    CGPoint _floatOrigin;
    CFTimeInterval _floatBegan;
    CGFloat _floatMaxTravel;
    CFTimeInterval _fixedBegan;
    CGFloat _fixedMaxTravel;
    NSInteger _r3TapFrames;
    NSInteger _l3TapFrames;
    CGRect _fixedStickRect;
    UIView *_rightBase;
    UIView *_rightKnob;
    Theft4GhostView *_rightGhost;
    // R3/L3 tap flash label.
    UILabel *_flashLabel;
    // Context flags (visual only — the game resolves axis semantics):
    BOOL _driveContext; // RT or LT held -> the L stick steers
    BOOL _aimContext;   // X held -> aiming
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
            label.backgroundColor = [UIColor colorWithWhite:0 alpha:.45 * _opacity];
            label.layer.borderColor =
                [PadAmber() colorWithAlphaComponent:.9 * _opacity].CGColor;
            label.layer.borderWidth = 1.5;
            label.layer.masksToBounds = YES;
            label.userInteractionEnabled = NO;
            if (i == 0) label.hidden = YES; // the floating L-STICK replaces it
            [self addSubview:label];
            [_labels addObject:label];
            UIView *glow = [UIView new];
            glow.userInteractionEnabled = NO;
            glow.backgroundColor = [UIColor clearColor];
            glow.layer.borderWidth = 3.0;
            glow.layer.borderColor = PadAmber().CGColor;
            glow.alpha = 0;
            [self insertSubview:glow belowSubview:label];
            [_glows addObject:glow];
        }
        _triggerFillLT = [self makeFillInLabel:5];
        _triggerFillRT = [self makeFillInLabel:10];
        _leftBase = [self makeStickBase];
        _stickKnob = [self makeKnob:0.55];
        _leftGhost = [Theft4GhostView new];
        _leftGhost.title = @"L-STICK";
        _leftGhost.ringColor = [UIColor colorWithWhite:1 alpha:.55];
        _leftGhost.userInteractionEnabled = NO;
        [self addSubview:_leftGhost];
        _rightGhost = [Theft4GhostView new];
        _rightGhost.title = @"R-STICK";
        _rightGhost.ringColor = [UIColor colorWithWhite:1 alpha:.55];
        _rightGhost.userInteractionEnabled = NO;
        [self addSubview:_rightGhost];
        _rightBase = [self makeStickBase];
        _rightKnob = [self makeKnob:0.35];
        _flashLabel = [UILabel new];
        _flashLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
        _flashLabel.textColor = PadAmber();
        _flashLabel.alpha = 0;
        _flashLabel.userInteractionEnabled = NO;
        [self addSubview:_flashLabel];
    }
    return self;
}
- (UIView *)makeFillInLabel:(NSInteger)i {
    UIView *fill = [UIView new];
    fill.backgroundColor = [PadAmber() colorWithAlphaComponent:.5];
    fill.userInteractionEnabled = NO;
    fill.hidden = YES;
    [_labels[i] addSubview:fill];
    return fill;
}
- (UIView *)makeStickBase {
    UIView *v = [UIView new];
    v.userInteractionEnabled = NO;
    v.backgroundColor = [UIColor colorWithWhite:1 alpha:.08];
    v.layer.borderWidth = 2.0;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:.55].CGColor;
    v.hidden = YES;
    [self addSubview:v];
    return v;
}
- (UIView *)makeKnob:(CGFloat)alpha {
    UIView *v = [UIView new];
    v.userInteractionEnabled = NO;
    v.backgroundColor = [PadAmber() colorWithAlphaComponent:alpha];
    v.layer.borderWidth = 1.5;
    v.layer.borderColor = PadAmber().CGColor;
    v.hidden = YES;
    [self addSubview:v];
    return v;
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
        if (i == 0) w = h = MIN(w, h); // circular rest size
        label.frame = CGRectMake(area.origin.x + c.x * area.size.width,
            area.origin.y + c.y * area.size.height, w, h);
        label.layer.cornerRadius = i == 0 ? w / 2 : MIN(w, h) / 3;
        // Mockup styling: amber border, black fill, both scaled by opacity.
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:.45 * _opacity];
        label.layer.borderColor =
            [PadAmber() colorWithAlphaComponent:.9 * _opacity].CGColor;
        UIView *glow = _glows[i];
        glow.frame = CGRectInset(label.frame, -6, -6);
        glow.layer.cornerRadius = label.layer.cornerRadius + 6;
    }
    _leftGhost.frame = _labels[0].frame;
    _fixedStickRect = [Theft4TouchLayout fixedStickRectInArea:area];
    [self layoutFills];
    [self updateStickVisuals];
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
    _r3TapFrames = _l3TapFrames = 0;
    _moveMaxTravel = _floatMaxTravel = _fixedMaxTravel = 0;
    _driveContext = _aimContext = NO;
    for (NSInteger i = 0; i < kPadControlCount; ++i) {
        if (_glowOn[i]) [self setPressedVisual:i pressed:NO];
        _glowOn[i] = NO;
    }
    _flashLabel.alpha = 0;
    theft4_touch_reset();
    [self updateStickVisuals];
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
    CGFloat halfX = area.origin.x + area.size.width * kLeftHalf;
    for (UITouch *touch in touches) {
        CGPoint p = [touch locationInView:self];
        NSInteger capture = kCaptureLook; // fallback: swipe-look
        // Buttons first (index 0 is the floating L stick, not a button).
        for (NSInteger i = kPadControlCount - 1; i >= 1; --i) {
            if (CGRectContainsPoint(_labels[i].frame, p)) { capture = i; break; }
        }
        if (capture == kCaptureLook) {
            if (p.x < halfX) {
                // Left half: the movement stick materializes where the
                // finger lands (movement on foot, steering in a car).
                capture = kCaptureMoveStick;
                _moveOrigin = p;
                _moveBegan = now;
                _moveMaxTravel = 0;
                if (_hapticsOn) [_hapticMedium impactOccurred];
            } else if (_stickMode == Theft4TouchRightStickModeFloating) {
                capture = kCaptureFloatStick;
                _floatOrigin = p;
                _floatBegan = now;
                _floatMaxTravel = 0;
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
        if ((capture == kCaptureLook || capture == kCaptureFloatStick ||
             capture == kCaptureFixedStick || capture == kCaptureMoveStick) &&
            [[[_captures objectEnumerator] allObjects] containsObject:@(capture)])
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
        } else if (capture.integerValue == kCaptureMoveStick) {
            _moveMaxTravel = MAX(_moveMaxTravel,
                                  hypot(p.x - _moveOrigin.x, p.y - _moveOrigin.y));
        } else if (capture.integerValue == kCaptureFloatStick) {
            _floatMaxTravel = MAX(_floatMaxTravel,
                                  hypot(p.x - _floatOrigin.x, p.y - _floatOrigin.y));
        } else if (capture.integerValue == kCaptureFixedStick) {
            CGPoint fc = RectCenter(_fixedStickRect);
            _fixedMaxTravel = MAX(_fixedMaxTravel,
                                  hypot(p.x - fc.x, p.y - fc.y));
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
        } else if (kind == kCaptureMoveStick) {
            BOOL quickTap =
                (now - _moveBegan < kStickTapWindow) &&
                (_moveMaxTravel < kStickTapTravel);
            if (quickTap) {
                _l3TapFrames = kStickTapFrames;
                if (_hapticsOn) [_hapticSelect selectionChanged];
                [self showFlash:@"L3" at:_moveOrigin];
            }
        } else if (kind == kCaptureFloatStick || kind == kCaptureFixedStick) {
            BOOL quickTap =
                (now - (kind == kCaptureFloatStick ? _floatBegan : _fixedBegan) <
                 kStickTapWindow) &&
                ((kind == kCaptureFloatStick ? _floatMaxTravel : _fixedMaxTravel) <
                 kStickTapTravel);
            if (quickTap) {
                _r3TapFrames = kStickTapFrames;
                if (_hapticsOn) [_hapticSelect selectionChanged];
                [self showFlash:@"R3" at:(kind == kCaptureFloatStick
                    ? _floatOrigin : RectCenter(_fixedStickRect))];
            }
        }
        [_captures removeObjectForKey:touch];
    }
    [self publishButtonsAndMovement];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

// A quick "L3"/"R3" label that fades out at the stick position (mockup
// r3flash).
- (void)showFlash:(NSString *)text at:(CGPoint)pt {
    _flashLabel.text = text;
    [_flashLabel sizeToFit];
    _flashLabel.center = pt;
    _flashLabel.alpha = 1.0;
    [UIView animateWithDuration:0.22 animations:^{
        _flashLabel.alpha = 0.0;
    }];
}

// Pressed styling per the mockup: brightened amber fill + border, 90% scale,
// outer glow ring, and (LT/RT) a vertical fill rising from the bottom.
- (void)setPressedVisual:(NSInteger)i pressed:(BOOL)pressed {
    if (i == 0) return; // the floating L stick has its own visuals
    UILabel *label = _labels[i];
    UIView *glow = _glows[i];
    if (pressed) {
        label.backgroundColor =
            [PadAmber() colorWithAlphaComponent:MIN(1.0, 0.22 + 0.5 * _opacity)];
        label.layer.borderColor = PadAmber().CGColor;
    } else {
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:.45 * _opacity];
        label.layer.borderColor =
            [PadAmber() colorWithAlphaComponent:.9 * _opacity].CGColor;
    }
    UIView *fill = (i == 5) ? _triggerFillLT : ((i == 10) ? _triggerFillRT : nil);
    if (fill) {
        fill.hidden = NO;
        [self setFillFrame:fill pressed:pressed animated:_pressAnim];
    }
    if (_pressAnim) {
        [UIView animateWithDuration:kPressIn animations:^{
            label.transform = pressed
                ? CGAffineTransformMakeScale(0.90, 0.90)
                : CGAffineTransformIdentity;
            glow.alpha = pressed ? 0.85 : 0;
        }];
    } else {
        label.transform = CGAffineTransformIdentity;
        glow.alpha = 0;
    }
}
- (void)layoutFills {
    [self setFillFrame:_triggerFillLT pressed:_glowOn[5] animated:NO];
    [self setFillFrame:_triggerFillRT pressed:_glowOn[10] animated:NO];
}
- (void)setFillFrame:(UIView *)fill pressed:(BOOL)pressed animated:(BOOL)animated {
    UILabel *label = (UILabel *)fill.superview;
    CGRect inset = CGRectInset(label.bounds, 4, 4);
    CGFloat fh = inset.size.height * 0.86;
    CGRect target = pressed
        ? CGRectMake(inset.origin.x, label.bounds.size.height - 4 - fh,
                     inset.size.width, fh)
        : CGRectMake(inset.origin.x, label.bounds.size.height - 4,
                     inset.size.width, 0);
    if (animated) {
        [UIView animateWithDuration:kPressIn animations:^{
            fill.frame = target;
        }];
    } else {
        fill.frame = target;
    }
}

// Buttons + triggers from the held finger set (control indices 1..16).
- (theft4_touch_pad)buttonsAndMovement {
    theft4_touch_pad state = {0};
    BOOL pressed[kPadControlCount] = {0};
    for (UITouch *touch in _captures) {
        NSInteger i = [[_captures objectForKey:touch] integerValue];
        if (i < 1) continue; // sticks are handled by buildPadState
        CGPoint p = [touch locationInView:self];
        if (CGRectContainsPoint(CGRectInset(_labels[i].frame, -10, -10), p)) {
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
    // Context flags (visual only): the game resolves what each axis means —
    // with RT/LT held the L stick steers, with X held the R stick aims.
    _aimContext = (state.buttons & 0x4000) != 0;
    _driveContext = (state.right_trigger > 0) || (state.left_trigger > 0);
    return state;
}

// The floating movement stick: the left analog axis (lx/ly). Same deadzone
// curve as the original fixed pad; the game turns it into steering while
// driving and movement on foot.
- (void)applyMoveStick:(UITouch *)touch toState:(theft4_touch_pad *)state {
    CGPoint p = [touch locationInView:self];
    CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:
        UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets)];
    CGFloat radius = MAX(1, d / 2.0);
    CGFloat dx = p.x - _moveOrigin.x, dy = _moveOrigin.y - p.y;
    CGFloat m = hypot(dx, dy);
    CGFloat clamp = (m > radius) ? radius / m : 1.0;
    dx *= clamp; dy *= clamp;
    CGFloat strength = MIN(1, MAX(0, (m / radius - .14) / .86));
    CGFloat x = 0, y = 0;
    if (m > 0) { x = dx / m * strength; y = dy / m * strength; }
    state->lx = (int16_t)lround(x * 32767);
    state->ly = (int16_t)lround(y * 32767);
    // Visuals: solid ring at the materialized position, knob follows.
    _leftGhost.hidden = YES;
    _leftBase.hidden = NO;
    _leftBase.bounds = CGRectMake(0, 0, d, d);
    _leftBase.layer.cornerRadius = d / 2;
    _leftBase.layer.borderColor =
        (_driveContext ? PadAmber() : [UIColor colorWithWhite:1 alpha:.55]).CGColor;
    _leftBase.alpha = 1.0;
    _leftBase.center = _moveOrigin;
    _stickKnob.hidden = NO;
    CGFloat k = d * 0.36;
    _stickKnob.bounds = CGRectMake(0, 0, k, k);
    _stickKnob.layer.cornerRadius = k / 2;
    _stickKnob.center =
        CGPointMake(_moveOrigin.x + dx * .65, _moveOrigin.y - dy * .65);
    _stickKnob.alpha = 1.0;
}

// The camera stick: the right analog axis (rx/ry), linear from the center
// (no deadzone — aim precision), clamped at the ring.
- (void)applyCameraStick:(UITouch *)touch toState:(theft4_touch_pad *)state {
    NSInteger kind = [[_captures objectForKey:touch] integerValue];
    CGPoint p = [touch locationInView:self];
    CGPoint origin = (kind == kCaptureFloatStick)
        ? _floatOrigin : RectCenter(_fixedStickRect);
    CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:
        UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets)];
    CGFloat radius = MAX(1, d / 2.0);
    CGFloat dx = p.x - origin.x, dy = origin.y - p.y;
    CGFloat m = hypot(dx, dy);
    CGFloat norm = MIN(1.0, m / radius);
    CGFloat x = (m > 0) ? dx / m * norm : 0.0;
    CGFloat y = (m > 0) ? dy / m * norm : 0.0;
    state->rx = (int16_t)lround(x * 32767);
    state->ry = (int16_t)lround(y * 32767);
    CGFloat cx = (m > radius) ? dx / m * radius : dx;
    CGFloat cy = (m > radius) ? dy / m * radius : dy;
    _rightGhost.hidden = YES;
    _rightBase.hidden = NO;
    _rightBase.bounds = CGRectMake(0, 0, d, d);
    _rightBase.layer.cornerRadius = d / 2;
    _rightBase.layer.borderColor =
        (_aimContext ? PadAmber() : [UIColor colorWithWhite:1 alpha:.55]).CGColor;
    _rightBase.alpha = 1.0;
    _rightBase.center = origin;
    _rightKnob.hidden = NO;
    CGFloat k = d * 0.36;
    _rightKnob.bounds = CGRectMake(0, 0, k, k);
    _rightKnob.layer.cornerRadius = k / 2;
    _rightKnob.center = CGPointMake(origin.x + cx * .65, origin.y - cy * .65);
    _rightKnob.alpha = 1.0;
}

// Single-pass state construction shared by the touch event path and the 60 Hz
// timer: a finger moving a stick can never store a zeroed axis and cancel
// its own steering/camera signal between timer ticks.
- (theft4_touch_pad)buildPadState:(BOOL)consumeLook elapsed:(double)elapsed {
    theft4_touch_pad state = [self buttonsAndMovement];
    BOOL rightDriven = NO;
    for (UITouch *touch in _captures) {
        NSInteger kind = [[_captures objectForKey:touch] integerValue];
        if (kind == kCaptureMoveStick) {
            [self applyMoveStick:touch toState:&state];
        } else if (kind == kCaptureFloatStick || kind == kCaptureFixedStick) {
            [self applyCameraStick:touch toState:&state];
            rightDriven = YES;
        }
    }
    if (rightDriven) {
        // The stick owns the camera while held; drop any swipe accumulated
        // by a second finger so it cannot jump on release.
        _lookDelta = CGPointZero;
    } else if (consumeLook) {
        // Normalize swipe distance to a 60 Hz sample, independent of touch
        // delivery.
        double scale = 1.0 / (18.0 * elapsed * 60.0);
        state.rx = (int16_t)lround(MAX(-1, MIN(1, _lookDelta.x * scale)) * 32767);
        state.ry = (int16_t)lround(MAX(-1, MIN(1, -_lookDelta.y * scale)) * 32767);
        _lookX = state.rx;
        _lookY = state.ry;
        _lookDelta = CGPointZero;
    } else {
        state.rx = _lookX;
        state.ry = _lookY;
    }
    if (_r3TapFrames > 0) {
        state.buttons |= 0x80; // R3
        if (consumeLook) _r3TapFrames -= 1;
    }
    if (_l3TapFrames > 0) {
        state.buttons |= 0x40; // L3
        if (consumeLook) _l3TapFrames -= 1;
    }
    return state;
}
- (void)publishButtonsAndMovement {
    // Touch events store the FULL state (sticks included) immediately.
    theft4_touch_store([self buildPadState:NO elapsed:0]);
    [self updateStickVisuals];
}
- (void)publishTouchState {
    if (!_active) return;
    CFTimeInterval now = CACurrentMediaTime();
    double elapsed = MAX(1.0 / 240.0, now - _lastTick);
    _lastTick = now;
    theft4_touch_store([self buildPadState:YES elapsed:elapsed]);
    [self updateStickVisuals];
}

// --- Stick visuals ---------------------------------------------------------
// Keeps the dashed ghosts / fixed-stick visuals consistent with the current
// mode and context when idle; the apply* paths drive the visuals while held.
- (void)updateStickVisuals {
    BOOL moveHeld = NO, rightHeld = NO;
    for (NSNumber *c in [_captures objectEnumerator]) {
        if (c.integerValue == kCaptureMoveStick) moveHeld = YES;
        if (c.integerValue == kCaptureFloatStick ||
            c.integerValue == kCaptureFixedStick) rightHeld = YES;
    }
    // Left: solid ring while held, dashed ghost at the Move spec otherwise
    // (amber + brighter while a trigger is held — armed to steer).
    if (moveHeld) {
        _leftGhost.hidden = YES;
    } else {
        _leftBase.hidden = YES;
        _stickKnob.hidden = YES;
        _leftGhost.hidden = NO;
        _leftGhost.ringColor = _driveContext
            ? [PadAmber() colorWithAlphaComponent:.55]
            : [UIColor colorWithWhite:1 alpha:.55];
        _leftGhost.alpha = _driveContext ? kArmedGhostAlpha : kFloatingGhostAlpha;
        [_leftGhost setNeedsDisplay];
    }
    // Right: mode-driven.
    if (_stickMode == Theft4TouchRightStickModeOff) {
        _rightBase.hidden = YES;
        _rightKnob.hidden = YES;
        _rightGhost.hidden = YES;
        return;
    }
    if (rightHeld) return; // applyCameraStick drives the visuals while held
    if (_stickMode == Theft4TouchRightStickModeFixed) {
        // The permanent circle stays solid; knob at rest in the center.
        _rightGhost.hidden = YES;
        CGRect r = _fixedStickRect;
        _rightBase.hidden = NO;
        _rightBase.bounds = CGRectMake(0, 0, r.size.width, r.size.height);
        _rightBase.layer.cornerRadius = r.size.width / 2;
        _rightBase.layer.borderColor = [UIColor colorWithWhite:1 alpha:.55].CGColor;
        _rightBase.center = RectCenter(r);
        _rightBase.alpha = 0.55;
        _rightKnob.hidden = NO;
        _rightKnob.bounds =
            CGRectMake(0, 0, r.size.width * 0.36, r.size.width * 0.36);
        _rightKnob.layer.cornerRadius = r.size.width * 0.18;
        _rightKnob.center = RectCenter(r);
        _rightKnob.alpha = 0.55;
        return;
    }
    // Floating idle: dashed "R-STICK" ghost at the rest position (amber +
    // brighter while X is held — aiming).
    _rightBase.hidden = YES;
    _rightKnob.hidden = YES;
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:area];
    CGPoint rest = [Theft4TouchLayout floatingRestCenterInArea:area];
    _rightGhost.frame = CGRectMake(rest.x - d / 2.0, rest.y - d / 2.0, d, d);
    _rightGhost.ringColor = _aimContext
        ? [PadAmber() colorWithAlphaComponent:.55]
        : [UIColor colorWithWhite:1 alpha:.55];
    _rightGhost.alpha = _aimContext ? kArmedGhostAlpha : kFloatingGhostAlpha;
    [_rightGhost setNeedsDisplay];
}
- (void)touchLayoutDidChange { [self setNeedsLayout]; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_lookTimer invalidate];
}
@end
