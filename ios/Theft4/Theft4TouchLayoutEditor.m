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

    UILabel *title = MonoLabel(@"TOUCH LAYOUT EDITOR", 12, 0xE6B56B);
    UILabel *buildTag = MonoLabel(@"BUILD 148", 10, 0x5F7176);
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
    for (NSInteger i = 0; i < 17; ++i) {
        UILabel *label = _controls[i];
        label.frame = [self controlRectForIndex:i];
        label.layer.cornerRadius = (i == 0) ? label.bounds.size.width / 2
                                            : MIN(label.bounds.size.width, label.bounds.size.height) / 3;
        label.text = _draft[i].label;
    }
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
            [[UIImage imageWithSystemName:@"minus"] imageWithTintColor:Ink(0xE5DECA)
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
@end
