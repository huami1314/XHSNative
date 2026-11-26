//
//  XHSNative
//
//  iOS 26 以下的那一份：XHSNative.xm 里 Native 组的方法在这边换成插件自己画的版本，
//  另外加几处低系统才要补的。只在 26 以下加载。
//  低系统适配：@5hux1n（#6）
//
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "XHSNativeConfig.h"
#import "XHSNativeHeaders.h"
#import "XHSNativeHelper.h"
#import "XHSNativeLegacy.h"

@interface XYTabBarItem : UITabBarItem
@end

@interface XYPageScrollView : UIScrollView
@end

@interface XYAdsGoodsNoteBottom : UIView
@end

@interface XYAdsLeadsBottomBar : UIView
@end

#pragma mark - 底栏

// 没有 UITab，底栏直接用系统 UITabBar 的按钮，按顺序换 viewControllers；
// 外面的胶囊、选中块、搜索格、收起都是插件画的，见 layoutLegacyTabBar

// 两个角标入口进来时打个标记，setBadgeValue 据此区分。这个文件的 %ctor 排在 XHSNative.xm 之后（Makefile 里的顺序），
// showBadgeWithValue 这里包在外层
static BOOL gInMeBadge, gInShowBadgeForTabId;

%hook UITabBar

- (void)setStandardAppearance:(UITabBarAppearance *)appearance {
    if (![XHSNativeHelper isOurTabBar:self]) return %orig;
    UITabBarAppearance *clear = [UITabBarAppearance new];
    [XHSNativeLegacy styleTabBarAppearance:clear];
    %orig(clear);
}

// 低系统不给 scrollEdgeAppearance 的话，滚到底会换回白底
- (void)setScrollEdgeAppearance:(UITabBarAppearance *)appearance {
    if (![XHSNativeHelper isOurTabBar:self]) return %orig;
    UITabBarAppearance *clear = [UITabBarAppearance new];
    [XHSNativeLegacy styleTabBarAppearance:clear];
    %orig(clear);
}

- (void)setBackgroundColor:(UIColor *)color {
    %orig([XHSNativeHelper isOurTabBar:self] ? UIColor.clearColor : color);
}

- (void)layoutSubviews {
    %orig;
    [XHSNativeLegacy layoutLegacyTabBar:self];
}

%end

// 小红书的标签项把 title 写死成空，显示文字时取回系统的
%hook XYTabBarItem

- (NSString *)title {
    if (!XHSNativeConfig.shared.isTabTitleShown) return %orig;
    struct objc_super sup = {self, UITabBarItem.class};
    return ((NSString *(*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(title));
}

- (void)setBadgeValue:(NSString *)badgeValue {
    %orig;
    if (XHSNativeConfig.shared.pages.count) [XHSNativeLegacy layoutLegacyTabBar:XHSNativeConfig.shared.tabBarController.tabBar];
}

%end

%hook XYTabbarController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [XHSNativeLegacy setLegacyTabBarMinimized:NO];
    [self.tabBar setNeedsLayout];
    [XHSNativeLegacy layoutLegacyTabBar:self.tabBar];
}

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *legacy = [self customtabBar];
    if (legacy && XHSNativeConfig.shared.pages.count) {
        legacy.alpha = 0;
        legacy.hidden = YES;
        legacy.userInteractionEnabled = NO;
    }
    if (XHSNativeConfig.shared.tabsDirty && ![XHSNativeLegacy isControllerTabBarHidden:self]) [XHSNativeHelper rebuildTabs];
    [XHSNativeLegacy layoutLegacyTabBar:self.tabBar];
}

- (void)setSelectedIndex:(NSUInteger)index {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if (!config.pages || index >= config.pages.count || ![XHSNativeHelper isAppAddress:__builtin_return_address(0)]) return %orig;
    UIViewController *page = [XHSNativeLegacy legacyPageForName:config.pageNames[index]];
    if (page) self.selectedViewController = page;  // 找不到说明这个标签被用户藏了
}

- (void)setSelectedViewController:(UIViewController *)page {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSUInteger index = config.pages ? [config.pages indexOfObjectIdenticalTo:page] : NSNotFound;
    if (index != NSNotFound && !config.rebuilding && ![XHSNativeLegacy legacyPageForName:config.pageNames[index]]) return;
    %orig;
}

// 角标的下标按小红书自己那条底栏算。它那条没有市集、用户又藏了市集时，消息的角标会落在第 4 个上，改回消息。
// 设好之后按名字把所有角标同步到系统底栏的按钮上
- (void)setBadgeValue:(NSString *)value forItemAtIndex:(NSInteger)index {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSArray *names = [XHSNativeHelper legacyTabNames:self];
    if (self == config.tabBarController && index == 3 && [config isTabHidden:@"shopping"] && ![names containsObject:@"shopping"] && !gInMeBadge && !gInShowBadgeForTabId) {
        NSUInteger message = [names indexOfObject:@"message"];
        if (message != NSNotFound) index = message;
    }
    %orig(value, index);
    if (self != config.tabBarController || index < 0 || index >= (NSInteger)names.count) return;
    NSDictionary<NSNumber *, NSString *> *badges = self.badgeValueDict;
    for (NSString *name in config.pageNames) {
        NSUInteger legacyIndex = [names indexOfObject:name];
        UIViewController *page = [XHSNativeLegacy legacyPageForName:name];
        if (legacyIndex == NSNotFound || !page) continue;
        id badge = legacyIndex == (NSUInteger)index ? value : badges[@(legacyIndex)];
        page.tabBarItem.badgeValue = [badge isKindOfClass:NSString.class] && [badge length] ? badge : nil;
        [XHSNativeHelper refreshBadge:page.tabBarItem];
    }
}

// setTabBarHidden:animated: 是 iOS 18 才有的
- (void)setCustomTabBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    if ([self respondsToSelector:@selector(setTabBarHidden:animated:)]) [self setTabBarHidden:hidden animated:animated];
    else self.tabBar.hidden = hidden;
}

%end

%hook XYPHHomeTabbarController

- (void)showMeBadge:(id)badge {
    gInMeBadge = YES;
    %orig;
    gInMeBadge = NO;
}

- (void)hideMeBadge:(id)badge {
    gInMeBadge = YES;
    %orig;
    gInMeBadge = NO;
}

- (void)showBadgeWithValue:(NSString *)value forTabBarId:(NSString *)name {
    gInShowBadgeForTabId = YES;
    %orig;
    gInShowBadgeForTabId = NO;
}

// 重复点当前标签：先记下点之前选的是哪页，滑动切页不算
static char kPreviousPageKey;

- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectViewController:(UIViewController *)page {
    if (controller == self) objc_setAssociatedObject(self, &kPreviousPageKey, self.selectedViewController, OBJC_ASSOCIATION_ASSIGN);
    return %orig;
}

- (void)tabBarController:(UITabBarController *)controller didSelectViewController:(UIViewController *)page {
    UIViewController *previous = objc_getAssociatedObject(self, &kPreviousPageKey);
    objc_setAssociatedObject(self, &kPreviousPageKey, nil, OBJC_ASSOCIATION_ASSIGN);
    %orig;
    if (controller == self && page == previous) [XHSNativeHelper reselectPage:page];
}

%end

// 设置改了但底栏当时被盖住，等返回转场结束、底栏归位后再重排
%hook XYPHNavigationViewController

- (void)viewDidLayoutSubviews {
    %orig;
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    if (!controller || self.parentViewController != controller || !XHSNativeConfig.shared.tabsDirty) return;
    if (!self.transitionCoordinator) {
        if (![XHSNativeLegacy isControllerTabBarHidden:controller]) [XHSNativeLegacy rebuildLegacyTabs];
        return;
    }
    [self.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (context.isCancelled) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (XHSNativeConfig.shared.tabsDirty && ![XHSNativeLegacy isControllerTabBarHidden:controller]) [XHSNativeLegacy rebuildLegacyTabs];
        });
    }];
}

%end

#pragma mark - 首页

// 左右切频道时把新出现的列表也拉到顶栏下面
%hook XYPageScrollView

- (void)layoutSubviews {
    %orig;
    UIView *homeBar = XHSNativeConfig.shared.homeBar;
    if (homeBar && self.pagingEnabled && [self isDescendantOfView:homeBar.superview]) [XHSNativeLegacy extendHomeFeedUnderNaviBar:homeBar];
}

%end

#pragma mark - 个人页

%hook XYPFProfileV2NavigationBar

- (void)layoutSubviews {
    %orig;
    [XHSNativeLegacy layoutProfileBar:self];
}

%end

#pragma mark - 搜索页

%hook XYNativeSearchBar

- (void)didMoveToWindow {
    %orig;
    UIView *bar = self;
    if (!bar.window) return;
    [XHSNativeLegacy prepareLegacySearchBar:bar];
    [bar setNeedsLayout];
}

- (void)layoutSubviews {
    [XHSNativeLegacy prepareLegacySearchBar:self];
    %orig;
    [XHSNativeLegacy layoutLegacySearchBar:self];
}

%end

#pragma mark - 图文笔记 / 视频

// 广告笔记的底栏是另外两个类
%hook XYAdsGoodsNoteBottom

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) [XHSNativeLegacy layoutAdNoteBottom:self];
}

- (void)layoutSubviews {
    %orig;
    [XHSNativeLegacy layoutAdNoteBottom:self];
}

%end

%hook XYAdsLeadsBottomBar

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) [XHSNativeLegacy layoutAdNoteBottom:self];
}

- (void)layoutSubviews {
    %orig;
    [XHSNativeLegacy layoutAdNoteBottom:self];
}

%end

// 关掉对应的玻璃开关后，把之前改过的样子换回去
%hook XYNoteDetailPage

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIView *view = ((UIViewController *)self).view;
    if ([XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote]) [view setNeedsLayout];
    else [XHSNativeLegacy restoreLegacyDecorationsInView:view];
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote]) [XHSNativeLegacy restoreLegacyDecorationsInView:((UIViewController *)self).view];
}

%end

%hook XYVFHeadView

- (void)layoutSubviews {
    %orig;
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassVideo]) [XHSNativeLegacy restoreLegacyDecorationsInView:self];
}

%end

%hook XYVFBottomEngageView

- (void)layoutSubviews {
    %orig;
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassVideo]) [XHSNativeLegacy restoreLegacyDecorationsInView:self];
}

%end

%ctor {
    if ([XHSNativeHelper supportsGlass]) return;
    %init(XYNativeSearchBar = objc_getClass("XYSearchBar.XYSearchBarV2"),
          XYAdsGoodsNoteBottom = objc_getClass("XYAdsBusiness.AdsGoodsNoteBottomView"),
          XYNoteDetailPage = objc_getClass("XYNoteModule.NoteDetailPageInterface"),
          XYVFHeadView = objc_getClass("XYOldNoteModule.VFHeadView"),
          XYVFBottomEngageView = objc_getClass("XYOldNoteModule.VFBottomEngageView"));
}
