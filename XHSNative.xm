//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/24
//
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "XHSNativeConfig.h"
#import "XHSNativeHeaders.h"
#import "XHSNativeHelper.h"
#import "XHSNativeSave.h"

#pragma mark - 底栏

// 只在 iOS 26 及以上加载的放在 Native 组里，用的是系统的液态玻璃；更早的系统由 XHSNativeLegacyHooks.xm
// 换成插件自己画的仿玻璃，两边各写一份的方法也在那边。其余各系统共用

// 小红书的底栏是自己画的一条，盖在系统 UITabBar 上，再把系统的内容藏掉。
// 这里反过来：藏掉它画的那条，放出系统的，用 UITab 重新排一遍，右侧加系统的搜索标签。
// 页面、选中逻辑、角标仍然走小红书自己的，只是换了显示的那一层。

// 小红书把系统底栏刷成不透明的白底（换主题时还会再刷），页面因此被截在底栏上方。
// 它刷的时机很散，直接在底栏的这几个入口上拦，保持系统默认的悬浮样子
%hook UITabBar

- (void)setBackgroundImage:(UIImage *)image {
    %orig([XHSNativeHelper isOurTabBar:self] ? nil : image);
}

- (void)setTintColor:(UIColor *)color {
    %orig([XHSNativeHelper isOurTabBar:self] ? UIColor.labelColor : color);
}

- (void)setTranslucent:(BOOL)translucent {
    %orig(translucent || [XHSNativeHelper isOurTabBar:self]);
}

%end

// UIKit 开始拖动前会检查 UITabBarItem，即使对应的 UITab 仍是启用状态。
%hook UITabBarItem

- (void)setEnabled:(BOOL)enabled {
    %orig(enabled || [XHSNativeHelper isItemEnabled:self]);
}

%end

%hook XYTabbarController

- (void)xy_suppressSystemTabBarContentIfNeeded {
}

- (BOOL)xy_shouldSkipSystemTabBarFrameAdjustment {
    return YES;
}

- (void)viewDidLoad {
    XHSNativeConfig.shared.tabBarController = self;
    %orig;
    self.tabBar.unselectedItemTintColor = UIColor.labelColor;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)pages animated:(BOOL)animated {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    // 低系统重排标签是直接换 viewControllers，这时不是小红书在设页面
    if (config.rebuilding) return %orig;
    config.pages = nil;
    %orig;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (UIViewController *page in pages) {
        UITabBarItem *item = page.tabBarItem;
        NSString *name = [item respondsToSelector:NSSelectorFromString(@"itemName")] ? [item valueForKey:@"itemName"] : nil;
        [names addObject:name ?: @""];
    }
    config.pageNames = names;
    config.pages = pages;
    [XHSNativeHelper rebuildTabs];
}

// 小红书到处按「第几个页面」来操作，标签换了顺序、多了搜索之后，这几处要按它原来的顺序回答。
// 系统自己也会调这几个方法，那边要的是真实的显示顺序，所以只对来自小红书主程序的调用做换算

- (NSArray<UIViewController *> *)viewControllers {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    return (config.pages && !config.rebuilding && [XHSNativeHelper isAppAddress:__builtin_return_address(0)]) ? config.pages : %orig;
}

- (NSUInteger)selectedIndex {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if (!config.pages || config.rebuilding || ![XHSNativeHelper isAppAddress:__builtin_return_address(0)]) return %orig;
    UIViewController *page = self.selectedViewController;
    NSUInteger index = page ? [config.pages indexOfObjectIdenticalTo:page] : NSNotFound;
    return index == NSNotFound ? 0 : index;
}

%end

%hook XYPHHomeTabbarController

- (void)showBadgeWithValue:(NSString *)value forTabBarId:(NSString *)name {
    if (self == XHSNativeConfig.shared.tabBarController && [XHSNativeHelper hasRebuiltTabs] && name.length) {
        NSArray *names = [XHSNativeHelper legacyTabNames:self];
        NSUInteger index = [names indexOfObject:name];
        if (names && index != NSNotFound) {
            [self setBadgeValue:value forItemAtIndex:index];
            return;
        }
    }
    %orig;
}

- (id<UIViewControllerAnimatedTransitioning>)tabBarController:(UITabBarController *)controller animationControllerForTransitionFromViewController:(UIViewController *)from toViewController:(UIViewController *)to {
    if (controller == self && [XHSNativeHelper hasRebuiltTabs]) return nil;
    return %orig;
}

%end

// 二级页面大多不设 hidesBottomBarWhenPushed（旧底栏是它自己手动藏的），系统底栏会一直浮在上面
%hook XYPHNavigationViewController

- (void)pushViewController:(UIViewController *)page animated:(BOOL)animated {
    if (self.viewControllers.count) page.hidesBottomBarWhenPushed = YES;
    %orig;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)pages animated:(BOOL)animated {
    for (NSUInteger i = 1; i < pages.count; i++) pages[i].hidesBottomBarWhenPushed = YES;
    %orig;
}

%end

%group Native

%hook UITabBar

- (void)setStandardAppearance:(UITabBarAppearance *)appearance {
    %orig([XHSNativeHelper isOurTabBar:self] ? [UITabBarAppearance new] : appearance);
}

- (void)setScrollEdgeAppearance:(UITabBarAppearance *)appearance {
    %orig([XHSNativeHelper isOurTabBar:self] ? nil : appearance);
}

- (void)setBackgroundColor:(UIColor *)color {
    %orig([XHSNativeHelper isOurTabBar:self] ? nil : color);
}

%end

%hook XYTabbarController

- (void)viewDidLayoutSubviews {
    %orig;
    UIView *legacy = [self customtabBar];
    if (legacy.alpha > 0 && [XHSNativeHelper tabNamed:@"index"]) legacy.alpha = 0;
    if (XHSNativeConfig.shared.tabsDirty && !self.isTabBarHidden) [XHSNativeHelper rebuildTabs];
}

- (void)setSelectedIndex:(NSUInteger)index {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if (!config.pages || index >= config.pages.count || ![XHSNativeHelper isAppAddress:__builtin_return_address(0)]) return %orig;
    UITab *tab = [XHSNativeHelper tabNamed:config.pageNames[index]];
    if (tab) self.selectedTab = tab;  // 找不到说明这个标签被用户藏了
}

- (void)setSelectedViewController:(UIViewController *)page {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSUInteger index = config.pages ? [config.pages indexOfObjectIdenticalTo:page] : NSNotFound;
    if (index != NSNotFound && !config.rebuilding && ![XHSNativeHelper tabNamed:config.pageNames[index]]) return;
    %orig;
}

// 角标的下标是按它自己那条底栏算的，中间还夹着加号，所以按名字找回对应的标签
- (void)setBadgeValue:(NSString *)value forItemAtIndex:(NSInteger)index {
    %orig;
    NSArray *names = [XHSNativeHelper legacyTabNames:self];
    if (self != XHSNativeConfig.shared.tabBarController || index < 0 || index >= (NSInteger)names.count) return;
    UITab *tab = [XHSNativeHelper tabNamed:names[index]];
    if (!tab) return;
    tab.badgeValue = value;
    [XHSNativeHelper refreshBadge:tab.viewController.tabBarItem];
}

- (void)setCustomTabBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    [self setTabBarHidden:hidden animated:animated];
}

%end

%hook XYPHHomeTabbarController

%new
- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectTab:(UITab *)tab {
    if ([tab isKindOfClass:UISearchTab.class]) {
        if (XHSNativeConfig.shared.isPublishSwapped) [XHSNativeHelper openPublish];
        else [XHSNativeHelper openSearch];
        return NO;
    }
    // 重选要放行，didSelect 才收得到；小红书自己的 shouldSelect 可能会把它拦掉
    if (tab == controller.selectedTab) return YES;
    if (![self respondsToSelector:@selector(tabBarController:shouldSelectViewController:)]) return YES;
    return [self tabBarController:controller shouldSelectViewController:tab.viewController];
}

%new
- (void)tabBarController:(UITabBarController *)controller didSelectTab:(UITab *)tab previousTab:(UITab *)previous {
    if ([self respondsToSelector:@selector(tabBarController:didSelectViewController:)])
        [self tabBarController:controller didSelectViewController:tab.viewController];
    if (tab == previous) [XHSNativeHelper reselectPage:tab.viewController];
}

%end

// 官方给折叠屏写的那几处玻璃适配（搜索框、消息页导航栏等）顺带打开
%hook XYLiquidGlass

- (BOOL)enable {
    return YES;
}

%end

%hook XYDeviceUtility

+ (BOOL)useLiquidGlass {
    return YES;
}

%end

%end

#pragma mark - 首页顶栏

// 内容延伸到顶栏后面，用系统的 soft 滚动边缘；右上角的搜索进了底栏，位置换成发布。
// 下沉布局是小红书给折叠屏写好的，这里让普通机型也用上。

%hook XYMHomeViewController

- (NSUInteger)defaultLandingTabPage {
    NSUInteger orig = %orig;
    return [XHSNativeHelper landingChannel:orig ofHome:self];
}

%end

%hook XYMHomeDataSource

- (NSArray *)childViewModels {
    NSArray *orig = %orig;
    return [XHSNativeHelper visibleChannels:orig];
}

%end

%hook XYMHomeNaviBar

- (void)homeThemeChanged {
    %orig;
    [XHSNativeHelper stripBarBackground:self];
}

- (void)setIndex:(NSInteger)index {
    %orig;
    [XHSNativeHelper stripBarBackground:self];
    [XHSNativeHelper attachVisibleList];
    // 翻页动画结束后列表才完全到位，再接一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [XHSNativeHelper attachVisibleList]; });
}

- (void)layoutSubviews {
    %orig;
    [XHSNativeHelper layoutHomeBar:self];
}

%end

%group Native

%hook XYMHomeViewController

- (BOOL)homeLiquidGlassEnabled {
    return YES;
}

%end

%hook XYMHomeLayoutAdapter

+ (id)adapterForCurrentDeviceUsingLiquidGlass:(BOOL)glass {
    Class duo = objc_getClass("_TtC12XYHomeModuleP33_C150DC52649AA0F032812B635DA9765C23XYMHomeDuoLayoutAdapter");
    return (glass && duo) ? [[duo alloc] init] : %orig;
}

%end

%hook XYEXLiquidGlassNavigationAdapter

// 小红书自带的磨砂底，不要
- (UIView *)frostedBackgroundView {
    UIView *view = %orig;
    if (view.alpha != 0) view.alpha = 0;
    return view;
}

// 下沉布局接管每个列表的入口
+ (void)layoutScrollView:(UIScrollView *)list inPage:(id)page {
    %orig;
    if (![list isKindOfClass:UIScrollView.class] || [XHSNativeHelper hasSoftTopEdge:list]) return;
    [XHSNativeHelper useSoftTopEdge:list];
    dispatch_async(dispatch_get_main_queue(), ^{ [XHSNativeHelper attachVisibleList]; });
}

%end

// 下沉布局会把列表自己的顶部边缘效果关掉（因为它本来有磨砂底），这里保持打开
%hook UIScrollEdgeEffect

- (void)setHidden:(BOOL)hidden {
    %orig(hidden && ![XHSNativeHelper isPinnedEdgeEffect:self]);
}

%end

%end

#pragma mark - 点点

// 点点的入口：首页左上角、首页左滑、笔记里的「问点点」、分享面板。禁用后都按没有点点处理

%hook XYMainFrameEntranceConfig
- (NSString *)leftSideBarType {
    NSString *orig = %orig;
    return [XHSNativeHelper leftEntranceType:orig];
}
%end

// 上次的入口类型会按账号缓存，启动时先用它
%hook XYMainFrameLeftCache
- (NSString *)type {
    NSString *orig = %orig;
    return [XHSNativeHelper leftEntranceType:orig];
}
%end

%hook XYMHomeNaviBar
- (void)updateHomeMenuFromConfig:(BOOL)animated {
    if ([XHSNativeHelper keepsMenuIcon]) return;
    %orig;
}
%end

%hook XYHomeDotsSwipeInstaller
+ (id)installWithHost:(id)host pager:(id)pager finishPagerHandoff:(id)handoff {
    return XHSNativeConfig.shared.isDotsDisabled ? nil : %orig;
}
%end

%hook XYHomeService
- (BOOL)isDianDianLeftEnable {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
- (BOOL)enableShareToDianDianExp {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
- (BOOL)isDotsEntryEnabledForCategory:(id)category {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
%end

%hook XYPHNoteShareController
- (BOOL)enableShowDianDian {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
- (BOOL)enableShowDianDianWithScene {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
- (BOOL)enableShareToDianDianApp {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
%end

%hook XYPHWebPageShareController
- (BOOL)enableShowDianDian {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
- (BOOL)enableShareToDianDianApp {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
%end

%hook XYPHUserShareController
- (BOOL)enableShowDianDian {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
- (BOOL)enableShareToDianDianApp {
    if (XHSNativeConfig.shared.isDotsDisabled) return NO;
    return %orig;
}
%end

#pragma mark - 滚动联动

// UICollectionView / UITableView 各自重写了 didMoveToWindow，不一定走到 UIScrollView 的实现，三个都挂
%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    [XHSNativeHelper trackScrollView:self];
}
%end

%hook UICollectionView
- (void)didMoveToWindow {
    %orig;
    [XHSNativeHelper trackScrollView:self];
}
%end

%hook UITableView
- (void)didMoveToWindow {
    %orig;
    [XHSNativeHelper trackScrollView:self];
}
%end

#pragma mark - 市集 / 消息 / 我

%hook XYMarketRootInterface
- (void)viewDidLayoutSubviews {
    %orig;
    [XHSNativeHelper extendTabPage:self];
}
%end

%hook XYPMMessageCenterViewController
- (void)viewDidLayoutSubviews {
    %orig;
    [XHSNativeHelper extendTabPage:self];
}
%end

%hook XYPFProfileViewController
- (void)viewDidLayoutSubviews {
    %orig;
    [XHSNativeHelper extendTabPage:self];
}
%end

%group Native

%hook XYPMMessageCenterViewController
- (void)configureNavigationBarLiquidGlass {
    %orig;
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassMessages] || [self valueForKey:@"navigationGlassView"]) return;
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems)
        item.hidesSharedBackground = NO;
}
%end

#pragma mark - 搜索页

%hook XYNativeSearchBar
- (void)didMoveToWindow {
    %orig;
    XYNativeSearchBar *bar = self;
    if (!bar.window || ![XHSNativeConfig.shared boolForKey:kXHSNativeGlassSearch]) return;
    for (UIResponder *r = self; r; r = r.nextResponder) {
        if (![r isKindOfClass:%c(XYPHSearchNavigationViewController)]) continue;
        if (!bar.usesLiquidGlass) bar.usesLiquidGlass = YES;
        break;
    }
}
%end

#pragma mark - 个人页

%hook XYPFProfileV2NavigationBar
- (void)layoutSubviews {
    %orig;
    static char leftKey, rightKey;
    UIView *menu = [self homeMenuButton];
    BOOL enabled = [XHSNativeConfig.shared boolForKey:kXHSNativeGlassProfile] && ![self usesDuoNavigation] && [XHSNativeHelper isVisible:menu] && menu.superview == self;
    if (enabled) [XHSNativeHelper plateOn:self key:&leftKey below:menu frame:CGRectInset(menu.frame, -6, -6) bar:kXHSNativeBarProfile];
    else ((UIView *)objc_getAssociatedObject(self, &leftKey)).hidden = YES;

    CGRect group = CGRectNull;
    UIView *first = nil;
    if (enabled) {
        UIView *share = [self shareButton], *scan = [self scanButton], *edit = [self editButton];
        for (UIView *button in self.subviews) {
            if (button != share && button != scan && button != edit) continue;
            if (![XHSNativeHelper isVisible:button]) continue;
            first = first ?: button;
            group = CGRectUnion(group, button.frame);
        }
    }
    if (first) [XHSNativeHelper plateOn:self key:&rightKey below:first frame:CGRectInset(group, -6, -6) bar:kXHSNativeBarProfile];
    else ((UIView *)objc_getAssociatedObject(self, &rightKey)).hidden = YES;
}
%end

#pragma mark - 私聊输入栏

%hook XYChatBarLayout
- (BOOL)usesGlassAppearance {
    BOOL orig = %orig;
    if (orig) return YES;
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassChat]) return NO;
    for (UIViewController *page = [(UIViewController *)self parentViewController]; page; page = page.parentViewController) {
        if ([page isKindOfClass:%c(XYPMChatBaseViewController)]) return ![(XYPMChatBaseViewController *)page isFloating];
    }
    return NO;
}
%end

%end

#pragma mark - 评论半屏

%hook XYCommentHalfBar
- (void)layoutSubviews {
    %orig;
    static char glassKey;
    for (UIView *input in [(UIView *)self subviews]) {
        if (![input isKindOfClass:objc_getClass("XYNoteBasic.CommentBarStaticViewV2024")]) continue;
        UIView *glass = objc_getAssociatedObject(input, &glassKey);
        if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassComments]) { glass.hidden = YES; return; }
        for (UIView *content in input.subviews) {
            if (content == glass) continue;
            [XHSNativeHelper plateOn:input key:&glassKey below:content frame:input.bounds bar:kXHSNativeBarComment];
            return;
        }
    }
}
%end

#pragma mark - 图文笔记页

%hook XYNoteDetailPage
- (void)viewDidLayoutSubviews {
    %orig;
    [XHSNativeHelper layoutNotePage:self];
}
%end

%hook XYNoteDirectionView
- (void)layoutSubviews {
    %orig;
    [XHSNativeHelper recenterAuthorRow:self];
}
%end

// 双击图片：进大图并放大，不点赞
%hook XYNoteImageView
- (void)browser:(id)browser doubleClickedAt:(NSInteger)index {
    if (!XHSNativeConfig.shared.isDoubleTapZoomEnabled) return %orig;
    [XHSNativeHelper openGalleryZoomedFrom:browser];
}
%end

#pragma mark - 无水印保存

// 小红书保存别人的笔记时，图片在本地画水印，视频和实况等服务器渲染带水印的版本；
// 笔记保存配置的 disableWatermark 为真时（自己的笔记就是这样）直接存原图、原视频。
// disableSave 是作者关闭了保存，分享面板、长按、视频保存都看它。保存仍然走小红书自己的按钮
%hook XYPHMediaSaveConfig
- (BOOL)disableWatermark {
    return XHSNativeConfig.shared.isNoWatermarkEnabled || %orig;
}

- (BOOL)disableSave {
    if (XHSNativeConfig.shared.isSaveRestrictionIgnored) return NO;
    return %orig;
}
%end

// 没有保存配置的笔记补一个默认的，不然读到的 disableWatermark 是空
%hook XYPHBaseNote
- (XYPHMediaSaveConfig *)mediaSaveConfig {
    XYPHMediaSaveConfig *config = %orig;
    if (config || !XHSNativeConfig.shared.isNoWatermarkEnabled) return config;
    return [objc_getClass("XYPHMediaSaveConfig") new];
}
%end

// 视频下载器自己也记着这个值，不去水印时会轮询服务器拿渲染好的带水印视频
%hook XYVFVideoDownloaderManager
- (BOOL)disableWatermark {
    return XHSNativeConfig.shared.isNoWatermarkEnabled || %orig;
}

// 视频流里左右滑的图集笔记，保存的是服务器把整组拼成的一段视频。先问存哪种：
// 当前这张、全部图片（实况存实况，静态图存原图），或者照原来存成视频
- (void)download:(NSString *)url noteId:(NSString *)noteId videoDuration:(NSInteger)duration {
    UIView *slides = XHSNativeConfig.shared.isNoWatermarkEnabled ? [XHSNativeSave slidesOfNote:noteId] : nil;
    UIWindow *window = slides.window;
    if (!window) return %orig;

    void (^done)(BOOL) = ^(BOOL success) {
        if (success) [self showSaveSuccess];
        else [self showSaveFail:nil];
    };
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"下载当前图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [XHSNativeSave saveSlides:slides all:NO completion:done];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"下载所有图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [XHSNativeSave saveSlides:slides all:YES completion:done];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存为视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        %orig;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // 保存是从长按面板点进来的，面板这时正在收起，等它收完再从最上层的页面弹
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *top = window.rootViewController;
        while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
        [top presentViewController:alert animated:YES completion:nil];
    });
}
%end

// 实况的视频那一段不看 disableWatermark：总是先请求 note/live_photo/save，让服务器渲染带水印的视频，
// disableWatermark 只管封面。无水印时跳过这一步，把笔记里原始的实况视频直接交给后面的保存
%hook XYImageSaveService
- (void)requestLivePhotoWatermarkWithImageInfo:(id)imageInfo userId:(NSString *)userId disableWatermark:(BOOL)disableWatermark startTime:(double)startTime {
    NSString *video = nil;
    @try { video = [imageInfo valueForKey:@"livePhotoVideoUrl"]; } @catch (NSException *exception) {}
    if (!XHSNativeConfig.shared.isNoWatermarkEnabled || ![video isKindOfClass:NSString.class] || !video.length) return %orig;
    [self saveLivePhotoWatermarkWithLivePhotoVideoURL:video imageInfo:imageInfo userId:userId disableWatermark:YES startTime:startTime];
}
%end

// 作者关闭下载时，笔记功能开关里 image_download、video_download 不可用，长按面板、分享面板、视频页的保存都按它置灰
%hook XYPHFunctionSwitchInfo
- (BOOL)enable {
    if (!XHSNativeConfig.shared.isSaveRestrictionIgnored) return %orig;
    id type = nil;
    @try { type = [self valueForKey:@"type"]; } @catch (NSException *exception) {}
    if ([type isKindOfClass:NSString.class] && [type hasSuffix:@"_download"]) return YES;
    return %orig;
}
%end

// 评论区的保存：记下加载过的评论，保存时按评论 id 找回原始的视频、实况、图片地址
%hook XYPHNoteComment
- (void)setCommentImages:(NSArray *)images {
    %orig;
    if (images.count) [XHSNativeSave rememberComment:self];
}

- (void)setCommentVideos:(NSArray *)videos {
    %orig;
    if (videos.count) [XHSNativeSave rememberComment:self];
}
%end

// 评论视频、实况原本请求服务器渲染带水印的版本
%hook XYCommentMediaSaveService
- (void)saveVideoWithNoteId:(NSString *)noteId commentId:(NSString *)commentId videoIndex:(NSInteger)index {
    if (XHSNativeConfig.shared.isNoWatermarkEnabled && [XHSNativeSave saveCommentVideoWithCommentId:commentId index:index]) return;
    %orig;
}

- (void)saveLivePhotoWithNoteId:(NSString *)noteId commentId:(NSString *)commentId userId:(NSString *)userId imageUrlString:(NSString *)imageURL inputVideoId:(NSString *)videoId {
    if (XHSNativeConfig.shared.isNoWatermarkEnabled && [XHSNativeSave saveCommentLivePhotoWithCommentId:commentId videoId:videoId imageURL:imageURL]) return;
    %orig;
}
%end

// 评论里的图片走另一套保存，没有不加水印的选项，按作者 id 生成水印后和原图、AI 标识画在一起存成静态图。
// 无水印时直接存原图数据，有动图就存动图；原图没存成退回原流程时，把水印换成透明的一像素，AI 生成内容的标识照样画
%hook XYImageCommentManager
- (void)saveImageWithUrl:(NSString *)url authorId:(NSString *)authorId {
    if (!XHSNativeConfig.shared.isNoWatermarkEnabled) return %orig;
    __weak typeof(self) weakSelf = self;
    if (![XHSNativeSave saveCommentImageWithURL:url completion:^(BOOL success) { [weakSelf showResultWithIsSuccess:success]; }]) %orig;
}

- (UIImage *)buildWaterMarkImageWith:(UIImage *)watermark aigcImage:(UIImage *)aigcImage baseImage:(UIImage *)baseImage outImage:(id)outImage isHdr:(BOOL)isHdr {
    if (!XHSNativeConfig.shared.isNoWatermarkEnabled) return %orig;
    static UIImage *clear;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.opaque = NO;
        clear = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, 1) format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {}];
    });
    return %orig(clear, aigcImage, baseImage, outImage, isHdr);
}
%end

// 小红书自带的「大图里双击放大」，原本是按实验下发的
%hook XYNoteDetailExpManager
- (BOOL)noteGalleryDoubleTapZoomExperimentEnable {
    return XHSNativeConfig.shared.isDoubleTapZoomEnabled || %orig;
}
%end

// 关注按钮原来是红色描边的小药丸，放进玻璃里显得碎。去掉描边只留字，字稍微加重
%hook XYFollowBtn

- (void)layoutSubviews {
    %orig;
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote] || ![NSStringFromClass(self.superview.class) isEqualToString:@"XYNoteModule.NoteDirectionView"]) return;
    if (self.layer.borderWidth != 0) self.layer.borderWidth = 0;
    [XHSNativeHelper clearBackground:self];
    UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    if (![self.titleLabel.font isEqual:font]) self.titleLabel.font = font;
}

%end

#pragma mark - 视频页

%hook XYVFHeadView
- (void)layoutSubviews {
    %orig;
    [XHSNativeHelper layoutVideoHead:self];
}
%end

%hook XYVFBottomEngageView
- (void)layoutSubviews {
    %orig;
    [XHSNativeHelper layoutVideoEngage:self];
}
%end

#pragma mark - 设置界面

// 用小红书自己的设置组件搭：页面是 XYSettingBaseViewController，行是 StandardOption，
// 写法和它的「深色模式」页一样，所以样子、开关、返回都是它原生的。入口是它「设置」页的第一行。

%subclass XHSNativeSettingsPage : XYSettingBaseViewController

%property (nonatomic, strong) id model;
%property (nonatomic, copy) NSString *mode;

- (id)vm {
    XHSNativeSettingsPage *page = self;
    if (!page.model) page.model = [[objc_getClass("SettingViewModel") alloc] init];
    return page.model;
}

- (void)viewDidLoad {
    %orig;
    XHSNativeSettingsPage *page = self;
    if (!page.mode) page.tableView.tableFooterView = [XHSNativeHelper settingsFooterWithWidth:CGRectGetWidth(page.tableView.bounds)];
    if ([XHSNativeHelper isOrderMode:page.mode]) [page.tableView setEditing:YES animated:NO];
    [[page navBar] setValue:[XHSNativeHelper titleForMode:page.mode] forKey:@"title"];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self reloadRows];
}

%new
- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path {
    return [XHSNativeHelper isOrderMode:((XHSNativeSettingsPage *)self).mode];
}

%new
- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return UITableViewCellEditingStyleNone;
}

%new
- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path {
    return NO;
}

%new
- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    if ([source isEqual:destination]) return;
    NSString *mode = ((XHSNativeSettingsPage *)self).mode;
    [XHSNativeHelper moveOrderInMode:mode from:source.row to:destination.row];
    [[(XHSNativeSettingsPage *)self vm] setValue:[XHSNativeHelper orderRowsForMode:mode] forKey:@"options"];
    // 拖动结束后，按新位置重设首尾行的圆角。
    dispatch_async(dispatch_get_main_queue(), ^{ [table reloadData]; });
    [XHSNativeHelper applySettings];
}

%new
- (void)reloadRows {
    XHSNativeSettingsPage *page = self;
    NSArray *rows = [XHSNativeHelper rowsForMode:page.mode];
    ((void (*)(id, SEL, id))objc_msgSend)([page vm], NSSelectorFromString(@"reload:"), rows);
}

- (void)didSelectOption:(id)option {
    [XHSNativeHelper handleTap:[option valueForKey:@"identity"] onPage:self];
}

// 开关拨动。两个参数一个是这一行的选项，一个是带开关的单元格
- (void)didChangeValueFor:(id)first related:(id)second {
    id option = [first respondsToSelector:NSSelectorFromString(@"identity")] ? first : second;
    id cell = option == first ? second : first;
    [XHSNativeHelper handleSwitch:[option valueForKey:@"identity"] on:[[cell valueForKey:@"isOn"] boolValue]];
}

%end

// 入口：往它「设置」页的数据里插一行，排在最前面，自成一组
%hook XYPHSettingTableViewModel

- (void)setOptions:(NSArray *)options {
    if (options.count) {
        NSMutableArray *rows = [options mutableCopy];
        [rows insertObject:[self blank] atIndex:1];
        [rows insertObject:[XHSNativeHelper entryOption] atIndex:1];
        options = rows;
    }
    %orig;
}

%end

%hook XYPHSettingViewController

- (void)didSelectOption:(id)option {
    if (![[option valueForKey:@"identity"] isEqual:[XHSNativeHelper entryIdentity]]) return %orig;
    [self.navigationController pushViewController:[[%c(XHSNativeSettingsPage) alloc] init] animated:YES];
}

%end

%ctor {
    %init(XYMHomeDataSource = objc_getClass("XYHomeModule.XYMHomeDataSource"),
          XYMainFrameEntranceConfig = objc_getClass("XYHomeModule.MainFrameEntranceConfigManager"),
          XYMainFrameLeftCache = objc_getClass("XYModuleInterface.MainFrameLeftCacheModel"),
          XYHomeDotsSwipeInstaller = objc_getClass("XYHomeModule.HomeDotsSwipeInstaller"),
          XYHomeService = objc_getClass("XYHomeModule.HomeServiceImp"),
          XYMarketRootInterface = objc_getClass("XYShopping.MarketRootInterface"),
          XYCommentHalfBar = objc_getClass("_TtCC12XYNoteModule32CommentHalflayerBottomController4View"),
          XYNoteDetailPage = objc_getClass("XYNoteModule.NoteDetailPageInterface"),
          XYNoteDirectionView = objc_getClass("XYNoteModule.NoteDirectionView"),
          XYNoteImageView = objc_getClass("XYNoteModule.NoteImageView"),
          XYImageSaveService = objc_getClass("XYNoteModule.ImageSaveService"),
          XYCommentMediaSaveService = objc_getClass("XYNoteModule.CommentMediaSaveService"),
          XYVFHeadView = objc_getClass("XYOldNoteModule.VFHeadView"),
          XYVFBottomEngageView = objc_getClass("XYOldNoteModule.VFBottomEngageView"));
    // 低系统的那一份在 XHSNativeLegacyHooks.xm 里加载
    if (![XHSNativeHelper supportsGlass]) return;

    [XHSNativeHelper patchOlderSystems];
    %init(Native,
          XYChatBarLayout = objc_getClass("XYMessageUIKit.XYPMMessageShortcutBarLayoutViewController"),
          XYNativeSearchBar = objc_getClass("XYSearchBar.XYSearchBarV2"),
          XYDeviceUtility = objc_getClass("XYUIKit.DeviceUtility"));
}
