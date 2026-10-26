#import "Theft4TouchLayout.h"

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

@interface Theft4TouchLayout () {
    NSMutableArray<Theft4TouchControlSpec *> *_specs;
    NSInteger _revision;
}
+ (NSString *)storagePath;
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

- (instancetype)init {
    if ((self = [super init])) {
        _specs = [[self.class defaultSpecs] mutableCopy];
        NSArray *saved = [self readSavedSpecs];
        if (saved.count == kControlCount) _specs = [saved mutableCopy];
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
@end
