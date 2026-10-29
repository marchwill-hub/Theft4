#import "Theft4TouchLayout.h"
#import <CoreGraphics/CoreGraphics.h>

NSNotificationName const Theft4TouchLayoutDidChangeNotification =
    @"Theft4TouchLayoutDidChangeNotification";

// Built-in table: identical to Theft4TouchControls' original static layout.
// Order is fixed: index 0 is the movement stick, then buttons.
static const struct {
    const char *label;
    CGFloat x, y, w, h;
    uint16_t button;
    int trigger;
} kDefaultControls[17] = {
    {"Move", .055, .56, .190, .315, 0, 0},
    {"Back", .390, .045, .080, .112, 0x20, 0},
    {"Start", .495, .045, .085, .112, 0x10, 0},
    {"LB", .660, .050, .085, .112, 0x100, 0},
    {"RB", .765, .050, .085, .112, 0x200, 0},
    {"LT", .095, .405, .120, .110, 0, 1},
    {"Y", .760, .455, .065, .115, 0x8000, 0},
    {"X", .700, .585, .065, .115, 0x4000, 0},
    {"B", .820, .585, .065, .115, 0x2000, 0},
    {"A", .760, .715, .065, .115, 0x1000, 0},
    {"RT", .860, .405, .120, .110, 0, 2},
    {"\u2191", .315, .68, .055, .085, 0x1, 0},
    {"\u2193", .315, .86, .055, .085, 0x2, 0},
    {"\u2190", .258, .77, .055, .085, 0x4, 0},
    {"\u2192", .372, .77, .055, .085, 0x8, 0},
    {"L3", .440, .85, .065, .10, 0x40, 0},
    {"R3", .530, .85, .065, .10, 0x80, 0},
};
static const NSInteger kControlCount = 17;

@implementation Theft4TouchControlSpec
- (instancetype)copyOfSelf {
    Theft4TouchControlSpec *copy = [Theft4TouchControlSpec new];
    copy.label = [self.label copy];
    copy.x = self.x; copy.y = self.y; copy.w = self.w; copy.h = self.h;
    copy.button = self.button; copy.trigger = self.trigger;
    return copy;
}
@end

@implementation Theft4TouchLayoutSettings
- (instancetype)init {
    if ((self = [super init])) {
        // Approved Touch Pad v2 defaults (mockup sign-off, 2026-10-28).
        _opacity = 0.45;
        _rightStickMode = Theft4TouchRightStickModeFloating;
        _hapticsEnabled = YES;
        _pressAnimationEnabled = YES;
    }
    return self;
}
- (instancetype)copyOfSelf {
    Theft4TouchLayoutSettings *copy = [Theft4TouchLayoutSettings new];
    copy.opacity = self.opacity;
    copy.rightStickMode = self.rightStickMode;
    copy.hapticsEnabled = self.hapticsEnabled;
    copy.pressAnimationEnabled = self.pressAnimationEnabled;
    return copy;
}
@end

@interface Theft4TouchLayout () {
    NSMutableArray<Theft4TouchControlSpec *> *_specs;
    NSInteger _revision;
    Theft4TouchLayoutSettings *_settings;
}
+ (NSString *)storagePath;
+ (NSString *)settingsPath;
@end

@implementation Theft4TouchLayout

+ (Theft4TouchLayout *)shared {
    static Theft4TouchLayout *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [Theft4TouchLayout new]; });
    return shared;
}

+ (NSArray<Theft4TouchControlSpec *> *)defaultSpecs {
    NSMutableArray<Theft4TouchControlSpec *> *specs = [NSMutableArray new];
    for (NSInteger i = 0; i < kControlCount; ++i) {
        Theft4TouchControlSpec *spec = [Theft4TouchControlSpec new];
        spec.label = [NSString stringWithUTF8String:kDefaultControls[i].label];
        spec.x = kDefaultControls[i].x; spec.y = kDefaultControls[i].y;
        spec.w = kDefaultControls[i].w; spec.h = kDefaultControls[i].h;
        spec.button = kDefaultControls[i].button;
        spec.trigger = kDefaultControls[i].trigger;
        [specs addObject:spec];
    }
    return specs;
}

+ (NSString *)storagePath {
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory()];
    NSURL *dir = [NSURL fileURLWithPath:@"Library/Application Support/Theft4"
                                relativeToURL:home];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                  error:nil];
    return [[dir URLByAppendingPathComponent:@"touch_layout.json"] path];
}

+ (NSString *)settingsPath {
    NSURL *dir = [NSURL fileURLWithPath:NSHomeDirectory()];
    return [[dir URLByAppendingPathComponent:
        @"Library/Application Support/Theft4/touch_settings.json"] path];
}

- (instancetype)init {
    if ((self = [super init])) {
        _specs = [[self.class defaultSpecs] mutableCopy];
        _settings = [Theft4TouchLayoutSettings new];
        NSArray *saved = [self readSavedSpecs];
        if (saved.count == kControlCount) _specs = [saved mutableCopy];
        Theft4TouchLayoutSettings *savedSettings = [self readSavedSettings];
        if (savedSettings) _settings = savedSettings;
    }
    return self;
}

- (BOOL)hasCustomLayout {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self.class storagePath]];
}

- (NSArray<Theft4TouchControlSpec *> *)readSavedSpecs {
    NSData *data = [NSData dataWithContentsOfFile:[self.class storagePath]];
    if (!data) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSArray class]] ||
        [(NSArray *)parsed count] != kControlCount) return nil;
    NSArray *rows = parsed;
    NSMutableArray<Theft4TouchControlSpec *> *specs = [NSMutableArray new];
    for (NSInteger i = 0; i < kControlCount; ++i) {
        id row = rows[i];
        if (![row isKindOfClass:[NSDictionary class]]) return nil;
        NSDictionary *entry = row;
        Theft4TouchControlSpec *spec = [Theft4TouchControlSpec new];
        spec.label = entry[@"label"] ? [entry[@"label"] copy] : nil;
        spec.x = [entry[@"x"] doubleValue];
        spec.y = [entry[@"y"] doubleValue];
        spec.w = [entry[@"w"] doubleValue];
        spec.h = [entry[@"h"] doubleValue];
        spec.button = (uint16_t)[entry[@"button"] unsignedIntValue];
        spec.trigger = [entry[@"trigger"] integerValue];
        if (!spec.label || spec.w < .02 || spec.h < .02 ||
            spec.x < -.5 || spec.y < -.5 || spec.x > 1.5 || spec.y > 1.5)
            return nil;
        [specs addObject:spec];
    }
    return specs;
}

- (void)writeSpecs:(NSArray<Theft4TouchControlSpec *> *)specs {
    NSMutableArray *rows = [NSMutableArray new];
    for (Theft4TouchControlSpec *spec in specs) {
        [rows addObject:@{
            @"label": spec.label ?: @"",
            @"x": @(spec.x), @"y": @(spec.y), @"w": @(spec.w), @"h": @(spec.h),
            @"button": @(spec.button), @"trigger": @(spec.trigger),
        }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    if (data) [data writeToFile:[self.class storagePath]
                   atomically:YES];
}

- (void)applySpecs:(NSArray<Theft4TouchControlSpec *> *)specs {
    if (specs.count != kControlCount) return;
    _specs = [specs mutableCopy];
    _revision += 1;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:Theft4TouchLayoutDidChangeNotification object:self];
}

- (void)saveSpecs:(NSArray<Theft4TouchControlSpec *> *)specs {
    if (specs.count != kControlCount) return;
    [self applySpecs:specs];
    [self writeSpecs:specs];
}

- (void)resetToDefaults {
    [[NSFileManager defaultManager] removeItemAtPath:[self.class storagePath] error:nil];
    _specs = [[self.class defaultSpecs] mutableCopy];
    _revision += 1;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:Theft4TouchLayoutDidChangeNotification object:self];
}

- (Theft4TouchLayoutSettings *)readSavedSettings {
    NSData *data = [NSData dataWithContentsOfFile:[self.class settingsPath]];
    if (!data) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *row = parsed;
    if (row[@"opacity"] == nil) return nil;
    Theft4TouchLayoutSettings *settings = [Theft4TouchLayoutSettings new];
    settings.opacity = MIN(0.90, MAX(0.10, [row[@"opacity"] doubleValue]));
    NSInteger mode = [row[@"rightStickMode"] integerValue];
    if (mode < 0 || mode > 2) return nil;
    settings.rightStickMode = (Theft4TouchRightStickMode)mode;
    settings.hapticsEnabled = [row[@"hapticsEnabled"] boolValue];
    // Legacy files predate the glow flag; treat absence as "on" (v2 default).
    settings.pressAnimationEnabled = row[@"pressAnimationEnabled"]
        ? [row[@"pressAnimationEnabled"] boolValue] : YES;
    return settings;
}

- (void)saveSettings:(Theft4TouchLayoutSettings *)settings {
    if (!settings) return;
    _settings = [settings copyOfSelf];
    _settings.opacity = MIN(0.90, MAX(0.10, _settings.opacity));
    if (_settings.rightStickMode > Theft4TouchRightStickModeOff)
        _settings.rightStickMode = Theft4TouchRightStickModeFloating;
    _revision += 1;
    NSDictionary *row = @{
        @"opacity": @(_settings.opacity),
        @"rightStickMode": @(_settings.rightStickMode),
        @"hapticsEnabled": @(_settings.hapticsEnabled),
        @"pressAnimationEnabled": @(_settings.pressAnimationEnabled),
    };
    NSURL *dir = [[NSURL fileURLWithPath:[self.class settingsPath]]
        URLByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                  error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    [data writeToFile:[self.class settingsPath] atomically:YES];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:Theft4TouchLayoutDidChangeNotification object:self];
}

- (void)resetSettingsToDefaults {
    [[NSFileManager defaultManager] removeItemAtPath:[self.class settingsPath] error:nil];
    [self saveSettings:[Theft4TouchLayoutSettings new]];
}
@end

@implementation Theft4TouchLayout (RightStickGeometry)
+ (CGFloat)rightStickDiameterForArea:(CGRect)area {
    return MAX(120.0, MIN(area.size.width, area.size.height) * 0.20);
}
+ (CGPoint)floatingRestCenterInArea:(CGRect)area {
    return CGPointMake(area.origin.x + area.size.width * 0.77,
                       area.origin.y + area.size.height * 0.285);
}
+ (CGRect)fixedStickRectInArea:(CGRect)area {
    CGFloat d = [self rightStickDiameterForArea:area];
    CGPoint center = CGPointMake(area.origin.x + area.size.width * 0.685,
                                 area.origin.y + area.size.height * 0.30);
    return CGRectMake(center.x - d / 2.0, center.y - d / 2.0, d, d);
}
@end

@implementation Theft4GhostView
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _title = @"";
        _ringColor = [UIColor colorWithWhite:1 alpha:.55];
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    UIBezierPath *path =
        [UIBezierPath bezierPathWithOvalInRect:CGRectInset(rect, 1.5, 1.5)];
    path.lineWidth = 2;
    path.lineDashPattern = @[@5, @5];
    [self.ringColor setStroke];
    [path stroke];
    NSDictionary *attrs = @{
        NSFontAttributeName:
            [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: self.ringColor,
    };
    CGSize size = [self.title sizeWithAttributes:attrs];
    [self.title
        drawAtPoint:CGPointMake((rect.size.width - size.width) / 2.0,
                                (rect.size.height - size.height) / 2.0)
      withAttributes:attrs];
}
@end
