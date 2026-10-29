#import "Theft4TouchLayoutEditor.h"
#import "Theft4TouchLayout.h"
#include <math.h>

static UIColor *Ink(unsigned rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                         green:((rgb >> 8) & 0xFF) / 255.0
                          blue:(rgb & 0xFF) / 255.0
                         alpha:1.0];
}

static CGFloat ClampF(CGFloat v, CGFloat lo, CGFloat hi) {
    return MIN(hi, MAX(lo, v));
}

static inline UIColor *PadAmberColor(void) {
    return Ink(0xE6B56B);
}

static UILabel *MonoLabel(NSString *text, CGFloat size, unsigned color) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightSemibold];
    label.textColor = Ink(color);
    label.backgroundColor = [UIColor clearColor];
    return label;
}

static UIButton *BarButton(NSString *title, unsigned background, unsigned foreground,
                           BOOL accent) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.cornerStyle = UIButtonConfigurationCornerStyleFixed;
    config.background.cornerRadius = 4;
    config.baseForegroundColor = Ink(foreground);
    config.background.backgroundColor = Ink(background);
    config.contentInsets = NSDirectionalEdgeInsetsMake(11, 16, 11, 16);
    button.configuration = config;
    (void)accent;
    return button;
}

// Canvas background with a 10% reference grid.
@interface Theft4EditorCanvasView : UIView
@end
@implementation Theft4EditorCanvasView
- (void)drawRect:(CGRect)rect {
    [Ink(0x081115) setFill];
    UIRectFill(rect);
    [[Ink(0xD9D5C7) colorWithAlphaComponent:.07] setStroke];
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = 1;
    for (NSInteger i = 1; i < 10; ++i) {
        CGFloat x = rect.size.width * i / 10.0;
        [path moveToPoint:CGPointMake(x, 0)];
        [path addLineToPoint:CGPointMake(x, rect.size.height)];
    }
    for (NSInteger i = 1; i < 5; ++i) {
        CGFloat y = rect.size.height * i / 5.0;
        [path moveToPoint:CGPointMake(0, y)];
        [path addLineToPoint:CGPointMake(rect.size.width, y)];
    }
    [path stroke];
}
@end

// The editor is a bare canvas: drag any control to move it, pinch a control
// (or double-tap it for a temporary size slider) to resize it, then SAVE.
// Tapping the empty canvas dismisses the size slider. No panels — nothing
// sits between the finger and the controls.
@interface Theft4TouchLayoutEditorViewController () {
    Theft4EditorCanvasView *_canvas;
    NSMutableArray<UILabel *> *_controls;
    NSMutableArray<Theft4TouchControlSpec *> *_draft;
    UIButton *_saveButton, *_resetButton, *_closeButton;
    UIStackView *_topLeft, *_topRight;
    UISlider *_sizeSlider;
    NSInteger _sizeSliderIndex;
    CGFloat _sizeBaseW, _sizeBaseH;
    // Touch Pad v2 settings bar (live preview + live persistence).
    UIStackView *_settingsBar;
    UISlider *_opacitySlider;
    UILabel *_opacityValue;
    UISegmentedControl *_stickMode;
    UIButton *_hapticsButton;
    UIButton *_glowButton;
    UIView *_fixedGhost;
    Theft4GhostView *_floatingGhost;
}
@end

@implementation Theft4TouchLayoutEditorViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
- (BOOL)shouldAutorotate { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = Ink(0x050B0E);

    // The canvas is exactly the view's safe area: the same normalized
    // coordinate space the in-game pad lays out against, so what you see
    // here is what you get in the game.
    _canvas = [Theft4EditorCanvasView new];
    [self.view addSubview:_canvas];

    _draft = [NSMutableArray new];
    for (Theft4TouchControlSpec *spec in Theft4TouchLayout.shared.specs)
        [_draft addObject:[spec copyOfSelf]];

    _controls = [NSMutableArray new];
    for (NSInteger i = 0; i < 17; ++i) {
        UILabel *label = [UILabel new];
        label.tag = i;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        label.adjustsFontSizeToFitWidth = YES;
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:.25];
        label.layer.borderColor = [UIColor colorWithWhite:1 alpha:.55].CGColor;
        label.layer.borderWidth = 1.5;
        label.layer.masksToBounds = YES;
        label.userInteractionEnabled = YES;
        [_controls addObject:label];
        [_canvas addSubview:label];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(panControl:)];
        [label addGestureRecognizer:pan];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
            initWithTarget:self action:@selector(pinchControl:)];
        [label addGestureRecognizer:pinch];
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(doubleTapControl:)];
        doubleTap.numberOfTapsRequired = 2;
        [label addGestureRecognizer:doubleTap];
        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(dismissSizeSlider:)];
        [label addGestureRecognizer:singleTap];
    }
    UITapGestureRecognizer *canvasTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissSizeSlider:)];
    [_canvas addGestureRecognizer:canvasTap];

    [self buildSettingsBar];
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(settingsChanged)
               name:Theft4TouchLayoutDidChangeNotification object:nil];

    UILabel *title = MonoLabel(@"TOUCH LAYOUT EDITOR", 12, 0xE6B56B);
    UILabel *buildTag = MonoLabel(@"BUILD 154", 10, 0x5F7176);
    _closeButton = BarButton(@"CLOSE", 0x243236, 0xE5DECA, NO);
    _resetButton = BarButton(@"RESET", 0x243236, 0xE5DECA, NO);
    _saveButton = BarButton(@"SAVE", 0xE6B56B, 0x111B1D, YES);
    [_closeButton addTarget:self action:@selector(closeEditor)
        forControlEvents:UIControlEventTouchUpInside];
    [_resetButton addTarget:self action:@selector(confirmReset)
        forControlEvents:UIControlEventTouchUpInside];
    [_saveButton addTarget:self action:@selector(saveLayout)
        forControlEvents:UIControlEventTouchUpInside];
    UIStackView *topLeft = [[UIStackView alloc] initWithArrangedSubviews:@[title, buildTag, _resetButton]];
    topLeft.axis = UILayoutConstraintAxisHorizontal;
    topLeft.spacing = 10;
    topLeft.alignment = UIStackViewAlignmentCenter;
    UIStackView *topRight = [[UIStackView alloc] initWithArrangedSubviews:@[_saveButton, _closeButton]];
    topRight.axis = UILayoutConstraintAxisHorizontal;
    topRight.spacing = 10;
    _topLeft = topLeft;
    _topRight = topRight;
    [self.view addSubview:topLeft];
    [self.view addSubview:topRight];

    // The corner buttons float over the canvas corners and stay small, so
    // they never cover the control area.
    for (UIView *view in @[_topLeft, _topRight])
        view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_topLeft.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [_topLeft.leadingAnchor constraintEqualToAnchor:_canvas.leadingAnchor constant:12],
        [_topRight.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [_topRight.trailingAnchor constraintEqualToAnchor:_canvas.trailingAnchor constant:-12],
    ]];

    [self updateControlFrames];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _canvas.frame = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    [self updateControlFrames];
    // The stick affordances depend on the canvas size, which only exists
    // after the first layout pass.
    [self updateStickAffordances];
}

// Positions a control the same way the in-game pad does.
- (CGRect)controlRectForIndex:(NSInteger)i {
    Theft4TouchControlSpec *spec = _draft[i];
    CGRect area = _canvas.bounds;
    CGFloat w = MAX(36, spec.w * area.size.width);
    CGFloat h = MAX(36, spec.h * area.size.height);
    if (i == 0) w = h = MIN(w, h); // movement pad is circular
    return CGRectMake(spec.x * area.size.width, spec.y * area.size.height, w, h);
}

- (void)updateControlFrames {
    CGFloat op = Theft4TouchLayout.shared.settings.opacity;
    for (NSInteger i = 0; i < 17; ++i) {
        UILabel *label = _controls[i];
        label.frame = [self controlRectForIndex:i];
        label.layer.cornerRadius = (i == 0) ? label.bounds.size.width / 2
                                            : MIN(label.bounds.size.width, label.bounds.size.height) / 3;
        label.text = _draft[i].label;
        // Same opacity-scaled styling as the in-game pad (mockup: amber
        // border, black fill).
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45 * op];
        label.layer.borderColor =
            [PadAmberColor() colorWithAlphaComponent:MIN(1.0, 0.9 * op)].CGColor;
    }
}

// --- Touch Pad v2 settings bar -------------------------------------------
- (void)buildSettingsBar {
    Theft4TouchLayoutSettings *s = Theft4TouchLayout.shared.settings;
    _opacitySlider = [UISlider new];
    _opacitySlider.minimumValue = 0.10;
    _opacitySlider.maximumValue = 0.90;
    _opacitySlider.value = s.opacity;
    _opacitySlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_opacitySlider.widthAnchor constraintEqualToConstant:140].active = YES;
    [_opacitySlider addTarget:self action:@selector(opacitySliderChanged:)
        forControlEvents:UIControlEventValueChanged];
    _opacityValue = MonoLabel(@"", 11, 0xE5DECA);

    _stickMode = [[UISegmentedControl alloc]
        initWithItems:@[@"FLOAT", @"FIXED", @"OFF"]];
    _stickMode.selectedSegmentIndex = (NSInteger)s.rightStickMode;
    _stickMode.translatesAutoresizingMaskIntoConstraints = NO;
    [_stickMode.widthAnchor constraintEqualToConstant:190].active = YES;
    [_stickMode addTarget:self action:@selector(stickModeChanged:)
        forControlEvents:UIControlEventValueChanged];

    _hapticsButton =
        BarButton(s.hapticsEnabled ? @"HAPTICS: ON" : @"HAPTICS: OFF",
                  s.hapticsEnabled ? 0x243236 : 0x3A2B22, 0xE5DECA, NO);
    [_hapticsButton addTarget:self action:@selector(toggleHaptics:)
        forControlEvents:UIControlEventTouchUpInside];
    _glowButton =
        BarButton(s.pressAnimationEnabled ? @"GLOW: ON" : @"GLOW: OFF",
                  s.pressAnimationEnabled ? 0x243236 : 0x3A2B22, 0xE5DECA, NO);
    [_glowButton addTarget:self action:@selector(toggleGlow:)
        forControlEvents:UIControlEventTouchUpInside];
    UIButton *resetPad = BarButton(@"RESET PAD", 0x243236, 0xE5DECA, NO);
    [resetPad addTarget:self action:@selector(confirmResetPadSettings)
        forControlEvents:UIControlEventTouchUpInside];

    // Two rows so the bar always fits the native landscape width (the
    // single-row v2 bar overflowed the foldable display and Auto Layout
    // mis-placed it over the title).
    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[
        MonoLabel(@"PAD", 11, 0xE6B56B),
        MonoLabel(@"OPACITY", 11, 0x8FA3A8),
        _opacitySlider,
        _opacityValue,
    ]];
    row1.axis = UILayoutConstraintAxisHorizontal;
    row1.spacing = 10;
    row1.alignment = UIStackViewAlignmentCenter;
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[
        MonoLabel(@"CAMERA STICK", 11, 0x8FA3A8),
        _stickMode,
        _hapticsButton,
        _glowButton,
        resetPad,
    ]];
    row2.axis = UILayoutConstraintAxisHorizontal;
    row2.spacing = 10;
    row2.alignment = UIStackViewAlignmentCenter;
    _settingsBar = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    _settingsBar.axis = UILayoutConstraintAxisVertical;
    _settingsBar.spacing = 8;
    _settingsBar.translatesAutoresizingMaskIntoConstraints = NO;
    _settingsBar.layoutMarginsRelativeArrangement = YES;
    _settingsBar.layoutMargins = UIEdgeInsetsMake(8, 12, 8, 12);
    _settingsBar.backgroundColor =
        [Ink(0x0A1418) colorWithAlphaComponent:.92];
    _settingsBar.layer.cornerRadius = 8;
    _settingsBar.layer.borderWidth = 1;
    _settingsBar.layer.borderColor = Ink(0x1C2A30).CGColor;
    [self.view addSubview:_settingsBar];
    [NSLayoutConstraint activateConstraints:@[
        [_settingsBar.centerXAnchor constraintEqualToAnchor:_canvas.centerXAnchor],
        [_settingsBar.bottomAnchor constraintEqualToAnchor:_canvas.bottomAnchor
            constant:-10],
        [_settingsBar.widthAnchor constraintLessThanOrEqualToAnchor:
            _canvas.widthAnchor constant:-24],
    ]];

    // Camera-stick affordances drawn on the canvas (same geometry the game
    // uses, via the shared RightStickGeometry helpers).
    _fixedGhost = [UIView new];
    _fixedGhost.userInteractionEnabled = NO;
    _fixedGhost.backgroundColor = [UIColor colorWithWhite:1 alpha:.08];
    _fixedGhost.layer.borderColor =
        [UIColor colorWithWhite:1 alpha:.55].CGColor;
    _fixedGhost.layer.borderWidth = 2.0;
    [_canvas addSubview:_fixedGhost];
    // Dashed "R-STICK" ghost (mockup hint de repouso) — the text lives
    // inside the circle, so there is no free-floating label to overlap.
    _floatingGhost = [Theft4GhostView new];
    _floatingGhost.title = @"R-STICK";
    _floatingGhost.ringColor = [UIColor colorWithWhite:1 alpha:.55];
    _floatingGhost.alpha = 0.55;
    _floatingGhost.userInteractionEnabled = NO;
    [_canvas addSubview:_floatingGhost];
    [self updateStickAffordances];
    [self updateOpacityLabel];
}
- (void)updateOpacityLabel {
    _opacityValue.text = [NSString stringWithFormat:@"%.0f%%",
                          _opacitySlider.value * 100.0];
}
- (void)saveSettingsWithBlock:(void (^)(Theft4TouchLayoutSettings *))edit {
    Theft4TouchLayoutSettings *s = [Theft4TouchLayout.shared.settings copyOfSelf];
    edit(s);
    // Live persistence: the in-game pad picks the change up immediately
    // through the shared model notification.
    [Theft4TouchLayout.shared saveSettings:s];
}
- (void)opacitySliderChanged:(UISlider *)slider {
    [self saveSettingsWithBlock:^(Theft4TouchLayoutSettings *s) {
        s.opacity = slider.value;
    }];
    [self updateOpacityLabel];
}
- (void)stickModeChanged:(UISegmentedControl *)seg {
    [self saveSettingsWithBlock:^(Theft4TouchLayoutSettings *s) {
        s.rightStickMode = (Theft4TouchRightStickMode)seg.selectedSegmentIndex;
    }];
}
- (void)toggleHaptics:(UIButton *)button {
    [self saveSettingsWithBlock:^(Theft4TouchLayoutSettings *s) {
        s.hapticsEnabled = !s.hapticsEnabled;
    }];
    [self syncSettingsButtons];
}
- (void)toggleGlow:(UIButton *)button {
    [self saveSettingsWithBlock:^(Theft4TouchLayoutSettings *s) {
        s.pressAnimationEnabled = !s.pressAnimationEnabled;
    }];
    [self syncSettingsButtons];
}
- (void)syncSettingsButtons {
    Theft4TouchLayoutSettings *s = Theft4TouchLayout.shared.settings;
    [_hapticsButton setTitle:(s.hapticsEnabled ? @"HAPTICS: ON" : @"HAPTICS: OFF")
        forState:UIControlStateNormal];
    [_glowButton setTitle:(s.pressAnimationEnabled ? @"GLOW: ON" : @"GLOW: OFF")
        forState:UIControlStateNormal];
}
// The shared model notification fires for both spec and settings changes;
// refresh the canvas preview (opacity) and the stick affordances.
- (void)settingsChanged {
    [self updateControlFrames];
    [self updateStickAffordances];
}
- (void)updateStickAffordances {
    CGRect area = _canvas.bounds;
    if (area.size.width < 10) return; // not laid out yet
    Theft4TouchRightStickMode mode =
        Theft4TouchLayout.shared.settings.rightStickMode;
    CGFloat d = [Theft4TouchLayout rightStickDiameterForArea:area];
    _fixedGhost.hidden = (mode != Theft4TouchRightStickModeFixed);
    _floatingGhost.hidden = (mode != Theft4TouchRightStickModeFloating);
    if (mode == Theft4TouchRightStickModeFixed) {
        CGRect r = [Theft4TouchLayout fixedStickRectInArea:area];
        _fixedGhost.frame = r;
        _fixedGhost.layer.cornerRadius = d / 2.0;
        _fixedGhost.alpha = 0.55;
    } else if (mode == Theft4TouchRightStickModeFloating) {
        CGPoint c = [Theft4TouchLayout floatingRestCenterInArea:area];
        _floatingGhost.frame =
            CGRectMake(c.x - d / 2.0, c.y - d / 2.0, d, d);
        [_floatingGhost setNeedsDisplay];
    }
}
- (void)confirmResetPadSettings {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset Pad Settings?"
            message:@"Restores the Touch Pad v2 defaults: opacity 45%, floating camera stick, haptics on, press glow on."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
        style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            [Theft4TouchLayout.shared resetSettingsToDefaults];
            Theft4TouchLayoutSettings *s = Theft4TouchLayout.shared.settings;
            _opacitySlider.value = s.opacity;
            _stickMode.selectedSegmentIndex = (NSInteger)s.rightStickMode;
            [self updateOpacityLabel];
            [self syncSettingsButtons];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)panControl:(UIPanGestureRecognizer *)gesture {
    NSInteger i = (NSInteger)gesture.view.tag;
    if (gesture.state != UIGestureRecognizerStateChanged) return;
    CGPoint delta = [gesture translationInView:_canvas];
    [gesture setTranslation:CGPointZero inView:_canvas];
    Theft4TouchControlSpec *spec = _draft[i];
    spec.x = ClampF(spec.x + delta.x / MAX(1, _canvas.bounds.size.width), 0, 1 - spec.w);
    spec.y = ClampF(spec.y + delta.y / MAX(1, _canvas.bounds.size.height), 0, 1 - spec.h);
    [self updateControlFrames];
}

// Pinch scales the control under the fingers, proportionally.
- (void)pinchControl:(UIPinchGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateChanged) return;
    NSInteger i = (NSInteger)gesture.view.tag;
    CGFloat s = gesture.scale;
    gesture.scale = 1;
    if (s <= 0.01 || s >= 100) return;
    Theft4TouchControlSpec *spec = _draft[i];
    spec.w = ClampF(spec.w * s, 0.015, 0.95);
    spec.h = ClampF(spec.h * s, 0.015, 0.95);
    [self updateControlFrames];
}

// Double-tap opens a small size slider anchored near the selected control.
- (void)doubleTapControl:(UITapGestureRecognizer *)gesture {
    [self showSizeSliderForIndex:(NSInteger)gesture.view.tag];
}

- (void)showSizeSliderForIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_draft.count) return;
    _sizeSliderIndex = i;
    Theft4TouchControlSpec *spec = _draft[i];
    _sizeBaseW = spec.w;
    _sizeBaseH = spec.h;
    if (!_sizeSlider) {
        _sizeSlider = [UISlider new];
        _sizeSlider.minimumValue = 0.25;
        _sizeSlider.maximumValue = 3.0;
        _sizeSlider.minimumValueImage =
            [[UIImage systemImageNamed:@"minus"] imageWithTintColor:Ink(0xE5DECA)
                renderingMode:UIImageRenderingModeAlwaysOriginal];
        [_sizeSlider addTarget:self action:@selector(sizeSliderChanged:)
            forControlEvents:UIControlEventValueChanged];
        [_canvas addSubview:_sizeSlider];
    }
    _sizeSlider.hidden = NO;
    _sizeSlider.value = 1.0;
    CGRect r = [self controlRectForIndex:i];
    CGFloat w = MIN(220, MAX(120, r.size.width * 2));
    CGFloat x = r.origin.x + (r.size.width - w) / 2;
    CGFloat y = r.origin.y + r.size.height + 10;
    if (y + 32 > _canvas.bounds.size.height) y = r.origin.y - 42;
    x = ClampF(x, 4, MAX(4, _canvas.bounds.size.width - w - 4));
    y = ClampF(y, 4, MAX(4, _canvas.bounds.size.height - 36));
    _sizeSlider.frame = CGRectMake(x, y, w, 30);
    [_canvas bringSubviewToFront:_sizeSlider];
}

- (void)sizeSliderChanged:(UISlider *)slider {
    if (_sizeSliderIndex < 0 || _sizeSliderIndex >= (NSInteger)_draft.count) return;
    CGFloat v = slider.value;
    Theft4TouchControlSpec *spec = _draft[_sizeSliderIndex];
    spec.w = ClampF(_sizeBaseW * v, 0.015, 0.95);
    spec.h = ClampF(_sizeBaseH * v, 0.015, 0.95);
    [self updateControlFrames];
}

// Tapping anywhere else (canvas or a control) hides the size slider.
- (void)dismissSizeSlider:(UITapGestureRecognizer *)gesture {
    _sizeSlider.hidden = YES;
    _sizeSliderIndex = -1;
}

- (void)saveLayout {
    [Theft4TouchLayout.shared saveSpecs:_draft];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Layout Saved"
        message:@"Your controls are saved on this device. The in-game pad applies them immediately."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset Layout?"
        message:@"This discards your saved layout and restores the built-in control positions."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
        handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            [Theft4TouchLayout.shared resetToDefaults];
            [self rebuildDraft];
            [self updateControlFrames];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)rebuildDraft {
    _draft = [NSMutableArray new];
    for (Theft4TouchControlSpec *spec in Theft4TouchLayout.shared.specs)
        [_draft addObject:[spec copyOfSelf]];
}

- (void)closeEditor { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end
