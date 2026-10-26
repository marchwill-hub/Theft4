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

@interface Theft4TouchLayoutEditorViewController () {
    Theft4EditorCanvasView *_canvas;
    NSMutableArray<UILabel *> *_controls;
    NSMutableArray<Theft4TouchControlSpec *> *_draft;
    NSInteger _selected;
    UISlider *_xSlider, *_ySlider, *_wSlider, *_hSlider;
    UILabel *_detailTitle, *_detailMetrics;
    UIStackView *_detailPanel;
    UIButton *_saveButton, *_resetButton, *_closeButton;
    UIStackView *_topLeft, *_topRight;
    BOOL _applyingSlider;
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
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(selectControl:)];
        [label addGestureRecognizer:tap];
    }

    UILabel *title = MonoLabel(@"TOUCH LAYOUT EDITOR", 12, 0xE6B56B);
    _closeButton = BarButton(@"CLOSE", 0x243236, 0xE5DECA, NO);
    _resetButton = BarButton(@"RESET", 0x243236, 0xE5DECA, NO);
    _saveButton = BarButton(@"SAVE", 0xE6B56B, 0x111B1D, YES);
    [_closeButton addTarget:self action:@selector(closeEditor)
        forControlEvents:UIControlEventTouchUpInside];
    [_resetButton addTarget:self action:@selector(confirmReset)
        forControlEvents:UIControlEventTouchUpInside];
    [_saveButton addTarget:self action:@selector(saveLayout)
        forControlEvents:UIControlEventTouchUpInside];
    UIStackView *topLeft = [[UIStackView alloc] initWithArrangedSubviews:@[title, _resetButton]];
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

    _detailTitle = MonoLabel(@"", 12, 0xE6B56B);
    _detailMetrics = MonoLabel(@"", 10, 0x9FB6BC);
    UISlider *slider;
    slider = [[UISlider alloc] init]; slider.minimumValue = 0; slider.maximumValue = 1;
    _xSlider = slider;
    slider = [[UISlider alloc] init]; slider.minimumValue = 0; slider.maximumValue = 1;
    _ySlider = slider;
    slider = [[UISlider alloc] init]; slider.minimumValue = .03; slider.maximumValue = .6;
    _wSlider = slider;
    slider = [[UISlider alloc] init]; slider.minimumValue = .03; slider.maximumValue = .6;
    _hSlider = slider;
    for (UISlider *s in @[_xSlider, _ySlider, _wSlider, _hSlider]) {
        s.minimumTrackTintColor = Ink(0xC99755);
        s.thumbTintColor = Ink(0xE6B56B);
        [s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    }
    NSMutableArray<UIView *> *rows = [NSMutableArray new];
    for (UISlider *s in @[_xSlider, _ySlider, _wSlider, _hSlider]) {
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[s]];
        row.axis = UILayoutConstraintAxisHorizontal;
        [rows addObject:row];
    }
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_detailTitle, _detailMetrics]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 4;
    _detailPanel = [[UIStackView alloc] initWithArrangedSubviews:@[text, rows[0], rows[1], rows[2], rows[3]]];
    _detailPanel.axis = UILayoutConstraintAxisVertical;
    _detailPanel.spacing = 6;
    _detailPanel.backgroundColor = [Ink(0x101B1F) colorWithAlphaComponent:.92];
    _detailPanel.layer.cornerRadius = 8;
    _detailPanel.layer.borderWidth = 1;
    _detailPanel.layer.borderColor = [Ink(0x243236) CGColor];
    [self.view addSubview:_detailPanel];

    // Overlay chrome: floating over the canvas (kept out of the pad's
    // coordinate space so the canvas stays 1:1 with the in-game area).
    for (UIView *view in @[_topLeft, _topRight, _detailPanel])
        view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_topLeft.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [_topLeft.leadingAnchor constraintEqualToAnchor:_canvas.leadingAnchor constant:12],
        [_topRight.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [_topRight.trailingAnchor constraintEqualToAnchor:_canvas.trailingAnchor constant:-12],
        [_detailPanel.leadingAnchor constraintEqualToAnchor:_canvas.leadingAnchor constant:12],
        [_detailPanel.trailingAnchor constraintEqualToAnchor:_canvas.trailingAnchor constant:-12],
        [_detailPanel.bottomAnchor constraintEqualToAnchor:_canvas.bottomAnchor constant:-12],
    ]];

    _selected = 0;
    [self updateControlFramesAnimated:NO];
    [self updateDetailPanel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _canvas.frame = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    [self updateControlFramesAnimated:NO];
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

- (void)updateControlFramesAnimated:(BOOL)animated {
    if (_applyingSlider) return;
    void (^updates)(void) = ^{
        for (NSInteger i = 0; i < 17; ++i) {
            UILabel *label = self->_controls[i];
            label.frame = [self controlRectForIndex:i];
            label.layer.cornerRadius = (i == 0) ? label.bounds.size.width / 2
                                                : MIN(label.bounds.size.width, label.bounds.size.height) / 3;
            label.text = self->_draft[i].label;
            if (i == self->_selected) {
                label.layer.borderColor = Ink(0xE6B56B).CGColor;
                label.layer.borderWidth = 3;
            } else {
                label.layer.borderColor = [UIColor colorWithWhite:1 alpha:.55].CGColor;
                label.layer.borderWidth = 1.5;
            }
        }
    };
    if (animated) [UIView animateWithDuration:.15 animations:updates];
    else updates();
}

- (void)updateDetailPanel {
    NSInteger i = _selected;
    if (i < 0) return;
    Theft4TouchControlSpec *spec = _draft[i];
    _applyingSlider = YES;
    _xSlider.minimumValue = 0;
    _xSlider.maximumValue = MAX(0, 1 - spec.w);
    _ySlider.minimumValue = 0;
    _ySlider.maximumValue = MAX(0, 1 - spec.h);
    _wSlider.value = spec.w;
    _hSlider.value = spec.h;
    _xSlider.value = ClampF(spec.x, 0, _xSlider.maximumValue);
    _ySlider.value = ClampF(spec.y, 0, _ySlider.maximumValue);
    _applyingSlider = NO;
    _detailTitle.text = [NSString stringWithFormat:@"%@  —  DRAG OR USE SLIDERS", spec.label];
    _detailMetrics.text = [NSString stringWithFormat:
        @"X %.3f   Y %.3f   W %.3f   H %.3f   (0…1 of safe area)",
        spec.x, spec.y, spec.w, spec.h];
}

- (void)selectControl:(UITapGestureRecognizer *)gesture {
    _selected = (NSInteger)gesture.view.tag;
    [self updateControlFramesAnimated:NO];
    [self updateDetailPanel];
}

- (void)panControl:(UIPanGestureRecognizer *)gesture {
    NSInteger i = (NSInteger)gesture.view.tag;
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint delta = [gesture translationInView:_canvas];
        [gesture setTranslation:CGPointZero inView:_canvas];
        Theft4TouchControlSpec *spec = _draft[i];
        spec.x = ClampF(spec.x + delta.x / MAX(1, _canvas.bounds.size.width), 0, 1 - spec.w);
        spec.y = ClampF(spec.y + delta.y / MAX(1, _canvas.bounds.size.height), 0, 1 - spec.h);
        [self updateControlFramesAnimated:NO];
        [self updateDetailPanel];
    }
}

- (void)sliderChanged:(UISlider *)sender {
    NSInteger i = _selected;
    if (i < 0) return;
    Theft4TouchControlSpec *spec = _draft[i];
    BOOL stick = i == 0;
    if (sender == _xSlider) spec.x = sender.value;
    else if (sender == _ySlider) spec.y = sender.value;
    else if (sender == _wSlider) { spec.w = sender.value; if (stick) spec.h = sender.value; }
    else if (sender == _hSlider) { spec.h = sender.value; if (stick) spec.w = sender.value; }
    spec.x = ClampF(spec.x, 0, 1 - spec.w);
    spec.y = ClampF(spec.y, 0, 1 - spec.h);
    [self updateControlFramesAnimated:NO];
    [self updateDetailPanel];
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
            [self updateControlFramesAnimated:YES];
            [self updateDetailPanel];
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
