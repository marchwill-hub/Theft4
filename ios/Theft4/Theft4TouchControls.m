// Layout and analog math adapted from XeniOS touch_layout_ios_defaults.cc and
// touch_input_resolver.cc, copyright 2026 Ben Vanik. BSD-3-Clause; see bundled
// XeniOS-Touch-LICENSE.txt. UIKit capture/bridge integration is Theft4-specific.
#import "Theft4TouchControls.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include "theft4_touch_input.h"
#import "Theft4TouchLayout.h"

// The pad layout is user-adjustable: positions and sizes come from the shared
// Theft4TouchLayout model (built-in defaults or the user's saved editor
// layout). This view re-reads it on every layout pass, so a saved change
// applies live without restarting the game.
static const NSInteger kPadControlCount = 17;

static inline Theft4TouchControlSpec *PadSpec(NSInteger i) {
    return [[Theft4TouchLayout shared].specs objectAtIndex:i];
}

@interface Theft4TouchControls () {
    NSMutableArray<UILabel *> *_labels;
    NSMapTable<UITouch *, NSNumber *> *_captures;
    UIView *_stickKnob;
    NSTimer *_lookTimer;
    CGPoint _lookDelta;
    int16_t _lookX, _lookY;
    CFTimeInterval _lastTick;
    CGRect _lastBounds;
    UIEdgeInsets _lastInsets;
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
            [_labels addObject:label];
            [self addSubview:label];
        }
        _stickKnob = [UIView new];
        _stickKnob.userInteractionEnabled = NO;
        _stickKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:.25];
        [self addSubview:_stickKnob];
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
    CGRect area = UIEdgeInsetsInsetRect(self.safeAreaInsets, self.bounds);
    for (NSInteger i = 0; i < kPadControlCount; ++i) {
        Theft4TouchControlSpec *c = PadSpec(i);
        if (![_labels[i].text isEqualToString:c.label]) _labels[i].text = c.label;
        CGFloat w = MAX(36, c.w * area.size.width);
        CGFloat h = MAX(36, c.h * area.size.height);
        // Circular movement pad; landscape positions remain proportional.
        if (i == 0) w = h = MIN(w, h);
        _labels[i].frame = CGRectMake(area.origin.x + c.x * area.size.width,
            area.origin.y + c.y * area.size.height, w, h);
        _labels[i].layer.cornerRadius = i == 0 ? w / 2 : MIN(w, h) / 3;
    }
    CGFloat diameter = _labels[0].bounds.size.width * .36;
    _stickKnob.bounds = CGRectMake(0, 0, diameter, diameter);
    _stickKnob.layer.cornerRadius = diameter / 2;
    _stickKnob.center = _labels[0].center;
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
    theft4_touch_reset();
    _stickKnob.center = _labels[0].center;
    for (UILabel *label in _labels)
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:.25];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active) return;
    for (UITouch *touch in touches) {
        CGPoint p = [touch locationInView:self];
        NSInteger capture = -1; // Unoccupied background is swipe-to-look.
        for (NSInteger i = kPadControlCount - 1; i >= 0; --i) {
            if (CGRectContainsPoint(_labels[i].frame, p)) { capture = i; break; }
        }
        // Only one movement and one look capture; buttons are independently held.
        if ((capture == 0 || capture == -1) &&
            [[_captures.objectEnumerator allObjects] containsObject:@(capture)]) continue;
        [_captures setObject:@(capture) forKey:touch];
    }
    [self publishButtonsAndMovement];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_active) return;
    for (UITouch *touch in touches) {
        NSNumber *capture = [_captures objectForKey:touch];
        if (capture && capture.integerValue == -1) {
            CGPoint p = [touch locationInView:self], previous = [touch previousLocationInView:self];
            _lookDelta.x += p.x - previous.x;
            _lookDelta.y += p.y - previous.y;
        }
    }
    [self publishButtonsAndMovement];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        if ([[_captures objectForKey:touch] isEqual:@(-1)]) {
            _lookDelta = CGPointZero;
            _lookX = _lookY = 0;
        }
        [_captures removeObjectForKey:touch];
    }
    [self publishButtonsAndMovement];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (theft4_touch_pad)buttonsAndMovement {
    theft4_touch_pad state = {0};
    for (UILabel *label in _labels)
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:.25];
    _stickKnob.center = _labels[0].center;
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
            _stickKnob.center = CGPointMake(center.x + x * radius * .65, center.y - y * radius * .65);
        } else if (CGRectContainsPoint(CGRectInset(_labels[i].frame, -10, -10), p)) {
            Theft4TouchControlSpec *c = PadSpec(i);
            state.buttons |= c.button;
            if (c.trigger == 1) state.left_trigger = 255;
            if (c.trigger == 2) state.right_trigger = 255;
            _labels[i].backgroundColor = [UIColor colorWithWhite:1 alpha:.35];
        }
    }
    return state;
}
- (void)publishButtonsAndMovement {
    // Immediate releases/buttons; camera deltas are consumed only by the timer.
    theft4_touch_pad state = [self buttonsAndMovement];
    state.rx = _lookX;
    state.ry = _lookY;
    theft4_touch_store(state);
}
- (void)publishTouchState {
    if (!_active) return;
    theft4_touch_pad state = [self buttonsAndMovement];
    CFTimeInterval now = CACurrentMediaTime();
    double elapsed = MAX(1.0 / 240.0, now - _lastTick);
    _lastTick = now;
    // Normalize swipe distance to a 60 Hz sample, independent of touch delivery.
    double scale = 1.0 / (18.0 * elapsed * 60.0);
    state.rx = (int16_t)lround(MAX(-1, MIN(1, _lookDelta.x * scale)) * 32767);
    state.ry = (int16_t)lround(MAX(-1, MIN(1, -_lookDelta.y * scale)) * 32767);
    _lookX = state.rx;
    _lookY = state.ry;
    _lookDelta = CGPointZero;
    theft4_touch_store(state);
}
- (void)touchLayoutDidChange { [self setNeedsLayout]; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_lookTimer invalidate];
}
@end
