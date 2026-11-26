#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "XHSNativeConfig.h"
#import "XHSNativeViewState.h"

@interface TestView : NSObject
@property (nonatomic) double alpha;
@property (nonatomic) BOOL hidden;
@property (nonatomic, strong) NSObject *mask;
@end
@implementation TestView
@end

static void testRestoration(void) {
    NSObject *owner = [NSObject new];
    TestView *view = [TestView new];
    NSObject *hostMask = [NSObject new], *pluginMask = [NSObject new];
    view.alpha = 0.8;
    view.mask = hostMask;

    // 从未启用过的关闭分支不能碰宿主状态。
    [XHSNativeViewState restoreOwner:owner];
    assert(view.alpha == 0.8 && view.mask == hostMask);

    [XHSNativeViewState setValues:@{@"alpha": @0, @"mask": pluginMask} on:view owner:owner];
    [XHSNativeViewState setValues:@{@"alpha": @0.2} on:view owner:owner];
    [XHSNativeViewState restoreProperties:@[@"mask"] on:view owner:owner];
    assert(view.mask == hostMask && view.alpha == 0.2);
    [XHSNativeViewState restoreOwner:owner];
    assert(view.alpha == 0.8 && view.mask == hostMask);

    // 宿主在插件之后写入的值不能被旧快照覆盖。
    [XHSNativeViewState setValues:@{@"alpha": @0} on:view owner:owner];
    view.alpha = 0.7;
    [XHSNativeViewState restoreOwner:owner];
    assert(view.alpha == 0.7);

    // 宿主重新布局后再次适配，应以新的宿主状态为恢复目标。
    [XHSNativeViewState setValues:@{@"alpha": @0} on:view owner:owner];
    view.alpha = 0.6;
    [XHSNativeViewState setValues:@{@"alpha": @0} on:view owner:owner];
    [XHSNativeViewState restoreOwner:owner];
    assert(view.alpha == 0.6);

    view.mask = nil;
    [XHSNativeViewState setValues:@{@"mask": pluginMask} on:view owner:owner];
    [XHSNativeViewState restoreOwner:owner];
    assert(view.mask == nil);

    TestView *plate = [TestView new];
    [XHSNativeViewState addDecoration:plate owner:owner];
    [XHSNativeViewState restoreOwner:owner];
    assert(plate.hidden && !view.hidden);

    __weak TestView *weakView;
    @autoreleasepool {
        TestView *temporary = [TestView new];
        weakView = temporary;
        [XHSNativeViewState setValues:@{@"alpha": @1} on:temporary owner:owner];
    }
    assert(weakView == nil);
    [XHSNativeViewState restoreOwner:owner];
}

static void testConfig(void) {
    NSString *suite = [@"XHSNative.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Method getter = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    IMP original = method_setImplementation(getter, imp_implementationWithBlock(^id { return defaults; }));
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSArray *keys = @[kXHSNativeSearchTab, kXHSNativeMinimize, kXHSNativeGlassNote,
                      kXHSNativeGlassSearch, kXHSNativeGlassComments, kXHSNativeGlassProfile,
                      kXHSNativeGlassChat, kXHSNativeGlassMessages, kXHSNativeGlassVideo];
    // 与上游一致：功能子开关默认开启，特殊行为开关默认关闭
    for (NSString *key in keys) assert([config boolForKey:key]);
    assert(!config.isDotsDisabled && !config.isPublishSwapped && !config.isDoubleTapZoomEnabled);
    [config setBool:NO forKey:kXHSNativeGlassVideo];
    assert(![config boolForKey:kXHSNativeGlassVideo]);
    assert([config boolForKey:kXHSNativeGlassSearch]);

    [config setFill:80 forBar:kXHSNativeBarHome];
    assert([config fillForBar:@"tab"] == 0 && [config fillForBar:@"search"] == 0);
    [config setFill:20 forBar:@"tab"];
    [config setFill:30 forBar:@"search"];
    assert([config fillForBar:kXHSNativeBarHome] == 80);
    assert([config fillForBar:@"tab"] == 20 && [config fillForBar:@"search"] == 30);
    assert([config fillForBar:kXHSNativeBarNoteBottom] == 50);
    [config setTab:@"me" hidden:YES];
    [config setChannel:1 hidden:YES];
    assert([config isTabHidden:@"me"] && [config isChannelHidden:1]);
    [defaults removePersistentDomainForName:suite];
    method_setImplementation(getter, original);
}

int main(void) {
    @autoreleasepool {
        testRestoration();
        testConfig();
        puts("state and config tests passed");
    }
    return 0;
}
