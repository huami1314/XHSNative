//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/24
//
#import "XHSNativeConfig.h"

NSString *const kXHSNativeSearchTab = @"XHSNative.searchTab";
NSString *const kXHSNativeSwapPublish = @"XHSNative.swapPublish";
NSString *const kXHSNativeTabTitles = @"XHSNative.tabTitles";
NSString *const kXHSNativeHideChannelLine = @"XHSNative.hideChannelLine";
NSString *const kXHSNativeDoubleTapZoom = @"XHSNative.doubleTapZoom";
NSString *const kXHSNativeMinimize = @"XHSNative.minimize";
NSString *const kXHSNativeDisableDots = @"XHSNative.disableDots";
NSString *const kXHSNativeNoWatermark = @"XHSNative.noWatermark";
NSString *const kXHSNativeIgnoreNoSave = @"XHSNative.ignoreNoSave";
NSString *const kXHSNativeGlassNote = @"XHSNative.glass.note";
NSString *const kXHSNativeGlassSearch = @"XHSNative.glass.search";
NSString *const kXHSNativeGlassComments = @"XHSNative.glass.comments";
NSString *const kXHSNativeGlassProfile = @"XHSNative.glass.profile";
NSString *const kXHSNativeGlassChat = @"XHSNative.glass.chat";
NSString *const kXHSNativeGlassMessages = @"XHSNative.glass.messages";
NSString *const kXHSNativeGlassVideo = @"XHSNative.glass.video";

NSString *const kXHSNativeBarHome = @"home";
NSString *const kXHSNativeBarNoteTop = @"noteTop";
NSString *const kXHSNativeBarNoteBottom = @"noteBottom";
NSString *const kXHSNativeBarVideoTop = @"videoTop";
NSString *const kXHSNativeBarVideoBottom = @"videoBottom";
NSString *const kXHSNativeBarComment = @"comment";
NSString *const kXHSNativeBarProfile = @"profile";
NSString *const kXHSNativeBarTab = @"tab";
NSString *const kXHSNativeBarSearch = @"search";

static NSString *const kTabOrder = @"XHSNative.tabOrder";
static NSString *const kTabHidden = @"XHSNative.tabHidden";
static NSString *const kChannelHidden = @"XHSNative.channelHidden";
static NSString *const kChannelOrder = @"XHSNative.channelOrder";
static NSString *const kChannelNames = @"XHSNative.channelNames";
static NSString *const kFillPrefix = @"XHSNative.fill.";
static NSString *const kBlur = @"XHSNative.blur";
static NSString *const kTabIconSize = @"XHSNative.tabIconSize";
static NSString *const kTabTitleSize = @"XHSNative.tabTitleSize";

@implementation XHSNativeConfig

+ (instancetype)shared {
    static XHSNativeConfig *config;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ config = [XHSNativeConfig new]; });
    return config;
}

+ (NSArray<NSString *> *)allTabs {
    return @[@"index", @"shopping", @"message", @"me"];
}

- (BOOL)boolForKey:(NSString *)key {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? [value boolValue] : YES;
}

- (BOOL)isDotsDisabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:kXHSNativeDisableDots];
}

- (BOOL)isTabTitleShown {
    return [NSUserDefaults.standardUserDefaults boolForKey:kXHSNativeTabTitles];
}

- (BOOL)isChannelLineHidden {
    return [NSUserDefaults.standardUserDefaults boolForKey:kXHSNativeHideChannelLine];
}

- (BOOL)isNoWatermarkEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:kXHSNativeNoWatermark];
}

- (BOOL)isSaveRestrictionIgnored {
    return [NSUserDefaults.standardUserDefaults boolForKey:kXHSNativeIgnoreNoSave];
}

- (BOOL)isPublishSwapped {
    return [NSUserDefaults.standardUserDefaults boolForKey:kXHSNativeSwapPublish];
}

- (BOOL)isDoubleTapZoomEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:kXHSNativeDoubleTapZoom];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}

- (NSArray<NSString *> *)tabOrder {
    NSArray<NSString *> *all = XHSNativeConfig.allTabs;
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *name in [NSUserDefaults.standardUserDefaults stringArrayForKey:kTabOrder])
        if ([all containsObject:name] && ![order containsObject:name]) [order addObject:name];
    for (NSString *name in all)
        if (![order containsObject:name]) [order addObject:name];
    return order;
}

- (void)setTabOrder:(NSArray<NSString *> *)order {
    [NSUserDefaults.standardUserDefaults setObject:order forKey:kTabOrder];
}

- (BOOL)isTabHidden:(NSString *)name {
    if ([name isEqualToString:@"index"]) return NO;  // 首页不能藏，发布和搜索都挂在它上面
    return [[NSUserDefaults.standardUserDefaults stringArrayForKey:kTabHidden] containsObject:name];
}

- (void)setTab:(NSString *)name hidden:(BOOL)hidden {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSString *> *names = [([defaults stringArrayForKey:kTabHidden] ?: @[]) mutableCopy];
    [names removeObject:name];
    if (hidden) [names addObject:name];
    [defaults setObject:names forKey:kTabHidden];
}

- (BOOL)isChannelHidden:(NSUInteger)page {
    return [[NSUserDefaults.standardUserDefaults arrayForKey:kChannelHidden] containsObject:@(page)];
}

- (void)setChannel:(NSUInteger)page hidden:(BOOL)hidden {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSNumber *> *pages = [([defaults arrayForKey:kChannelHidden] ?: @[]) mutableCopy];
    [pages removeObject:@(page)];
    if (hidden) [pages addObject:@(page)];
    [defaults setObject:pages forKey:kChannelHidden];
}

- (NSString *)nameForChannel:(NSUInteger)page {
    NSString *name = [NSUserDefaults.standardUserDefaults dictionaryForKey:kChannelNames][@(page).stringValue];
    return [name isKindOfClass:NSString.class] && name.length ? name : nil;
}

- (void)setName:(NSString *)name forChannel:(NSUInteger)page {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *names = [([defaults dictionaryForKey:kChannelNames] ?: @{}) mutableCopy];
    names[@(page).stringValue] = name.length ? name : nil;
    [defaults setObject:names forKey:kChannelNames];
}

// 频道顺序，存的是频道编号。存的不全或有不认识的，按 关注 发现 同城 补齐
- (NSArray<NSNumber *> *)channelOrder {
    NSArray<NSNumber *> *all = @[@0, @1, @2];
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (id page in [NSUserDefaults.standardUserDefaults arrayForKey:kChannelOrder])
        if ([all containsObject:page] && ![order containsObject:page]) [order addObject:page];
    for (NSNumber *page in all)
        if (![order containsObject:page]) [order addObject:page];
    return order;
}

- (void)setChannelOrder:(NSArray<NSNumber *> *)order {
    [NSUserDefaults.standardUserDefaults setObject:order forKey:kChannelOrder];
}

- (CGFloat)fillForBar:(NSString *)bar {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:[kFillPrefix stringByAppendingString:bar]];
    if (value) return MIN(MAX([value doubleValue], 0), 100);
    // 笔记底栏下面滚的是评论文字，默认压一半，其余默认纯玻璃
    return [bar isEqualToString:kXHSNativeBarNoteBottom] ? 50 : 0;
}

- (void)setFill:(CGFloat)fill forBar:(NSString *)bar {
    [NSUserDefaults.standardUserDefaults setDouble:fill forKey:[kFillPrefix stringByAppendingString:bar]];
}

static CGFloat number(NSString *key, CGFloat fallback, CGFloat low, CGFloat high) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return value ? MIN(MAX([value doubleValue], low), high) : fallback;
}

- (CGFloat)blurPercent {
    return number(kBlur, 60, 0, 100);
}

- (void)setBlurPercent:(CGFloat)blur {
    [NSUserDefaults.standardUserDefaults setDouble:blur forKey:kBlur];
}

- (CGFloat)tabIconSize {
    return number(kTabIconSize, 28, 16, 32);
}

- (void)setTabIconSize:(CGFloat)size {
    [NSUserDefaults.standardUserDefaults setDouble:size forKey:kTabIconSize];
}

- (CGFloat)tabTitleSize {
    return number(kTabTitleSize, 10, 8, 14);
}

- (void)setTabTitleSize:(CGFloat)size {
    [NSUserDefaults.standardUserDefaults setDouble:size forKey:kTabTitleSize];
}

- (void)reset {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"XHSNative."]) [defaults removeObjectForKey:key];
}

@end
