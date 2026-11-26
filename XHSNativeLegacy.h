//
//  XHSNative
//
//  iOS 26 以下的仿液态玻璃，只在低系统上调用。见 XHSNativeLegacy.m
//
#import <UIKit/UIKit.h>

@class XYPFProfileV2NavigationBar;

@interface XHSNativeLegacy : NSObject

#pragma mark - 仿玻璃和渐隐边缘

+ (UIView *)plateOn:(UIView *)owner key:(const void *)key below:(UIView *)below frame:(CGRect)frame bar:(NSString *)bar;
+ (BOOL)isGlassView:(UIView *)view;
+ (void)clearLegacyBackground:(UIView *)view owner:(NSObject *)owner;
+ (void)restoreLegacyDecorationsInView:(UIView *)root;
+ (void)applyLegacySettings;
+ (void)applySoftEdgeFadeOn:(UIView *)bar key:(const void *)key fromTop:(BOOL)fromTop extraHeight:(CGFloat)extraHeight;
+ (void)attachScrollView:(UIScrollView *)list toBar:(UIView *)bar;

#pragma mark - 底栏

+ (UIViewController *)legacyPageForName:(NSString *)name;
+ (BOOL)isControllerTabBarHidden:(UITabBarController *)controller;
+ (void)rebuildLegacyTabs;
+ (void)layoutLegacyTabBar:(UITabBar *)bar;
+ (void)setLegacyTabBarMinimized:(BOOL)minimized;
+ (void)handleScrollPan:(UIPanGestureRecognizer *)pan inPage:(UIViewController *)page;
+ (void)styleTabBarAppearance:(UITabBarAppearance *)appearance;
+ (void)applyTabBarTitleFont:(UITabBar *)bar;

#pragma mark - 首页 / 个人页 / 笔记页 / 搜索页

+ (void)layoutHomeBar:(UIView *)bar;
+ (void)plateHomeBar:(UIView *)bar menu:(UIView *)menu button:(UIView *)button;
+ (void)extendHomeFeedUnderNaviBar:(UIView *)naviBar;
+ (void)layoutProfileBar:(XYPFProfileV2NavigationBar *)bar;
+ (void)adjustNoteBottomInStack:(UIView *)stack;
+ (void)layoutAdNoteBottom:(UIView *)adBar;
+ (void)prepareLegacySearchBar:(UIView *)bar;
+ (void)layoutLegacySearchBar:(UIView *)bar;

@end
