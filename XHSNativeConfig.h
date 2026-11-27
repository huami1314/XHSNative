//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/24
//
#import <UIKit/UIKit.h>

#define XHSNativeVersion @"1.8(11280000)"

@class XYTabbarController;

// 开关，默认都是开的
extern NSString *const kXHSNativeSearchTab;     // 右侧的搜索
extern NSString *const kXHSNativeSwapPublish;   // 交换搜索与发布：发布去底栏右侧，搜索回到首页顶栏，默认关
extern NSString *const kXHSNativeTabTitles;     // 底栏图标下显示文字，默认关
extern NSString *const kXHSNativeHideChannelLine; // 隐藏首页频道下面的红线，默认关
extern NSString *const kXHSNativeDoubleTapZoom; // 双击笔记图片放大，不点赞，默认关
extern NSString *const kXHSNativeMinimize;      // 滚动时收起底栏
extern NSString *const kXHSNativeDisableDots;   // 禁用点点 AI，默认关
extern NSString *const kXHSNativeNoWatermark;   // 无水印保存，默认关
extern NSString *const kXHSNativeIgnoreNoSave;  // 解除保存限制：作者关闭保存的笔记也能保存，默认关
extern NSString *const kXHSNativeGlassNote;
extern NSString *const kXHSNativeGlassSearch;
extern NSString *const kXHSNativeGlassComments;
extern NSString *const kXHSNativeGlassProfile;
extern NSString *const kXHSNativeGlassChat;
extern NSString *const kXHSNativeGlassMessages;
extern NSString *const kXHSNativeGlassVideo;

// 各处玻璃的名字，用来存它们的不透明度
extern NSString *const kXHSNativeBarHome;
extern NSString *const kXHSNativeBarNoteTop;
extern NSString *const kXHSNativeBarNoteBottom;
extern NSString *const kXHSNativeBarVideoTop;
extern NSString *const kXHSNativeBarVideoBottom;
extern NSString *const kXHSNativeBarComment;
extern NSString *const kXHSNativeBarProfile;
extern NSString *const kXHSNativeBarTab;      // 下面两处只有低系统有，玻璃是插件画的
extern NSString *const kXHSNativeBarSearch;

@interface XHSNativeConfig : NSObject

+ (instancetype)shared;
+ (void)setDefaults:(NSUserDefaults *)defaults;

#pragma mark - 运行时状态（不落盘）

@property (nonatomic, weak) XYTabbarController *tabBarController;
@property (nonatomic, weak) UIControl *searchButton;  // 首页顶栏原来的搜索按钮，被收起来了，但还能替用户点
@property (nonatomic, weak) UIView *homeBar;
@property (nonatomic, copy) NSArray<UIViewController *> *pages;  // 小红书自己的页面顺序：首页 市集 消息 我
@property (nonatomic, copy) NSArray<NSString *> *pageNames;
@property (nonatomic, strong) UIViewController *searchPage;      // 搜索标签挂的空页面，它不会真的显示
@property (nonatomic, assign) BOOL rebuilding;
@property (nonatomic, assign) BOOL tabsDirty;  // 底栏被盖住时改了设置，等露出来再重排

#pragma mark - 持久设置（NSUserDefaults）

// 标签的名字：index / shopping / message / me
@property (class, nonatomic, readonly) NSArray<NSString *> *allTabs;

- (BOOL)boolForKey:(NSString *)key;
- (BOOL)isDotsDisabled;
- (BOOL)isNoWatermarkEnabled;
- (BOOL)isSaveRestrictionIgnored;
- (BOOL)isPublishSwapped;
- (BOOL)isTabTitleShown;
- (BOOL)isChannelLineHidden;
- (BOOL)isDoubleTapZoomEnabled;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

- (NSArray<NSString *> *)tabOrder;
- (void)setTabOrder:(NSArray<NSString *> *)order;
- (BOOL)isTabHidden:(NSString *)name;
- (void)setTab:(NSString *)name hidden:(BOOL)hidden;

// 首页顶栏的频道，按小红书的 childVCPageName：0 关注 1 发现 2 同城
- (BOOL)isChannelHidden:(NSUInteger)page;
// 频道的自定义名称，没改过是 nil
- (NSString *)nameForChannel:(NSUInteger)page;
- (void)setName:(NSString *)name forChannel:(NSUInteger)page;
- (NSArray<NSNumber *> *)channelOrder;
- (void)setChannelOrder:(NSArray<NSNumber *> *)order;
- (void)setChannel:(NSUInteger)page hidden:(BOOL)hidden;

// 0 是纯玻璃，100 不透
- (CGFloat)fillForBar:(NSString *)bar;
- (void)setFill:(CGFloat)fill forBar:(NSString *)bar;

// 只有低系统用：插件画的玻璃的模糊程度（0~100），底栏图标和文字的字号
@property (nonatomic, assign) CGFloat blurPercent;
@property (nonatomic, assign) CGFloat tabIconSize;
@property (nonatomic, assign) CGFloat tabTitleSize;

// 清掉所有 XHSNative 的设置
- (void)reset;

@end
