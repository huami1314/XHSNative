//
//  XHSNative
//
//  iOS 26 以下没有系统的液态玻璃，这里用模糊、底色和两张描边阴影贴图拼一块仿的，
//  再把底栏、边缘效果这些系统给的东西各自做一份。只在低系统上调用。
//  低系统适配：@5hux1n（#6）
//
#import "XHSNativeLegacy.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "XHSNativeConfig.h"
#import "XHSNativeHeaders.h"
#import "XHSNativeHelper.h"
#import "XHSNativeViewState.h"

extern const unsigned char WCShadowStart[], WCShadowEnd[], WCRimStart[], WCRimEnd[];

@interface XHSFakeGlassPlate : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIViewPropertyAnimator *blurAnimator;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIImageView *shadowView;
@property (nonatomic, strong) UIImageView *rimView;
@property (nonatomic, copy) NSString *barName;
@property (nonatomic, assign) CGSize lastArtworkSize;
@property (nonatomic, assign) BOOL blurNeedsRebuild;
@property (nonatomic, assign) BOOL blurSyncScheduled;
- (void)refreshAppearance;
@end

static NSHashTable *allFakeGlassPlates(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static UIImageView *XHSArtwork(const unsigned char *start, const unsigned char *end, CGFloat cap) {
    NSData *data = [NSData dataWithBytesNoCopy:(void *)start length:(uintptr_t)end - (uintptr_t)start freeWhenDone:NO];
    UIImage *image = [UIImage imageWithData:data scale:3];
    return [[UIImageView alloc] initWithImage:[image resizableImageWithCapInsets:UIEdgeInsetsMake(0, cap, 0, cap) resizingMode:UIImageResizingModeStretch]];
}

@implementation XHSFakeGlassPlate

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:nil];
        blurView.layer.cornerCurve = kCACornerCurveContinuous;
        blurView.clipsToBounds = YES;
        blurView.userInteractionEnabled = NO;
        _blur = blurView;
        [self addSubview:_blur];

        _fillView = [UIView new];
        _fillView.userInteractionEnabled = NO;
        [self addSubview:_fillView];

        _shadowView = XHSArtwork(WCShadowStart, WCShadowEnd, 54);
        _shadowView.userInteractionEnabled = NO;
        [self addSubview:_shadowView];

        _rimView = XHSArtwork(WCRimStart, WCRimEnd, 32);
        _rimView.userInteractionEnabled = NO;
        [self addSubview:_rimView];

        [allFakeGlassPlates() addObject:self];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_blurAnimator stopAnimation:YES];
}

- (void)appWillEnterForeground:(NSNotification *)note {
    _blurNeedsRebuild = YES;
    [self refreshAppearance];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        // 视图进窗口后异步重建动画器：绝不能在 didMoveToWindow / 转场动画栈内同步操作 UIViewPropertyAnimator，
        // 否则其暂停态 UIViewAnimationState (speed=0, removedOnCompletion=NO) 会劫持 UITabBar 的 pop 滑入动画并将其永久冻结在屏幕外侧。
        _blurNeedsRebuild = YES;
        [self refreshAppearance];
    }
}

- (void)scheduleBlurSync {
    if (_blurSyncScheduled || !self.window) return;
    _blurSyncScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.blurSyncScheduled = NO;
        if (!strongSelf.window) return;
        XYTabbarController *tbc = XHSNativeConfig.shared.tabBarController;
        id<UIViewControllerTransitionCoordinator> tc = tbc.transitionCoordinator ?: tbc.selectedViewController.transitionCoordinator;
        if (tc) {
            [tc animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
                [strongSelf scheduleBlurSync];
            }];
            return;
        }
        [strongSelf applyBlurFractionNow];
    });
}

- (void)applyBlurFractionNow {
    if (!self.window) return;
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled();
    CGFloat fraction = solid ? 0 : XHSNativeConfig.shared.blurPercent / 100.0;
    _blur.hidden = solid || fraction <= 0.001;
    if (solid || fraction <= 0.001) {
        if (_blurAnimator) {
            [_blurAnimator stopAnimation:YES];
            _blurAnimator = nil;
        }
        _blur.effect = nil;
        _blurNeedsRebuild = NO;
        return;
    }
    if (_blurNeedsRebuild || !_blurAnimator || _blurAnimator.state == UIViewAnimatingStateStopped) {
        if (_blurAnimator) {
            [_blurAnimator stopAnimation:YES];
            _blurAnimator = nil;
        }
        _blur.effect = nil;
        __weak UIVisualEffectView *weakBlur = _blur;
        _blurAnimator = [[UIViewPropertyAnimator alloc] initWithDuration:1 curve:UIViewAnimationCurveLinear animations:^{
            weakBlur.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        }];
        _blurAnimator.pausesOnCompletion = YES;
        _blurNeedsRebuild = NO;
    }
    if (_blurAnimator.state == UIViewAnimatingStateInactive || fabs(_blurAnimator.fractionComplete - fraction) > 0.001) {
        _blurAnimator.fractionComplete = fraction;
    }
}

- (void)refreshAppearance {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled();
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat radius = height / 2;
    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;

    _blur.frame = self.bounds;
    _blur.layer.cornerRadius = radius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _blur.layer.borderWidth = solid ? 0 : (1.0 / UIScreen.mainScreen.scale);
    _blur.layer.borderColor = (dark ? [UIColor colorWithWhite:1.0 alpha:0.22] : [UIColor colorWithWhite:1.0 alpha:0.62]).CGColor;
    [CATransaction commit];
    _fillView.frame = self.bounds;
    _fillView.layer.cornerRadius = radius;
    _fillView.layer.cornerCurve = kCACornerCurveContinuous;

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat scale = height > 0 ? MIN(1.0, height / 60.0) : 1.0;
    CGFloat rimInset = 2.0 * scale;
    CGFloat shadowInset = 24.0 * scale;
    if (height > 0 && width > 0 && !CGSizeEqualToSize(self.bounds.size, _lastArtworkSize)) {
        _lastArtworkSize = self.bounds.size;
        CGFloat rimTargetH = height + 2.0 * rimInset;
        CGFloat rimScale = rimTargetH / 64.0;
        _rimView.transform = CGAffineTransformIdentity;
        _rimView.bounds = CGRectMake(0, 0, (width + 2.0 * rimInset) / rimScale, 64.0);
        _rimView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        _rimView.transform = CGAffineTransformMakeScale(rimScale, rimScale);

        CGFloat shadowTargetH = height + 2.0 * shadowInset;
        CGFloat shadowScale = shadowTargetH / 108.0;
        _shadowView.transform = CGAffineTransformIdentity;
        _shadowView.bounds = CGRectMake(0, 0, (width + 2.0 * shadowInset) / shadowScale, 108.0);
        _shadowView.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        _shadowView.transform = CGAffineTransformMakeScale(shadowScale, shadowScale);
    }

    // 与上游一致的不透明度：0 为纯玻璃，100 为完全不透明
    CGFloat fill = self.barName.length ? [XHSNativeConfig.shared fillForBar:self.barName] : 0;
    CGFloat opacity = solid ? 1.0 : MIN(MAX(fill, 0), 100) / 100.0;
    CGFloat blur = XHSNativeConfig.shared.blurPercent / 100.0;
    CGFloat fraction = blur;
    _blur.hidden = solid || fraction <= 0.001;
    if (self.window && (_blurNeedsRebuild || !_blurAnimator || _blurAnimator.state != UIViewAnimatingStateActive || fabs(_blurAnimator.fractionComplete - fraction) > 0.001)) {
        [self scheduleBlurSync];
    }
    UIColor *neutral = dark ? [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:1] : UIColor.whiteColor;
    CGFloat fillAlpha = solid ? 1.0 : MAX(0.05, opacity);
    _fillView.backgroundColor = [neutral colorWithAlphaComponent:fillAlpha];
    _shadowView.alpha = 0.34 + 0.30 * opacity;
    _rimView.alpha = 0.42 + 0.25 * opacity;
}

- (void)setBounds:(CGRect)bounds {
    bounds.origin = CGPointZero;
    [super setBounds:bounds];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self refreshAppearance];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self refreshAppearance];
}

@end

#pragma mark - 渐隐边缘视图

@interface XHSFakeEdgeFadeView : UIView
@property (nonatomic, assign) BOOL fromTop;
@property (nonatomic, weak) UIScrollView *scrollView;
- (void)updateColors;
- (void)updateVisibility;
@end

@implementation XHSFakeEdgeFadeView

// 跟着列表滚动显隐；首页顶栏那条顺带让二级频道栏跟着收起
- (void)setScrollView:(UIScrollView *)list {
    if (list == _scrollView) return;
    [_scrollView removeObserver:self forKeyPath:@"contentOffset"];
    _scrollView = list;
    [list addObserver:self forKeyPath:@"contentOffset" options:0 context:NULL];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    [self updateVisibility];
    UIView *homeBar = XHSNativeConfig.shared.homeBar;
    if (homeBar && self.superview == homeBar) [XHSNativeLegacy extendHomeFeedUnderNaviBar:homeBar];
}

- (void)dealloc {
    [_scrollView removeObserver:self forKeyPath:@"contentOffset"];
}

+ (Class)layerClass {
    return CAGradientLayer.class;
}

- (void)updateVisibility {
    UIScrollView *list = self.scrollView;
    CGFloat distance = 0;
    if (list.window && list.window == self.window) {
        distance = self.fromTop ? list.contentOffset.y + list.adjustedContentInset.top
            : list.contentSize.height + list.adjustedContentInset.bottom - CGRectGetHeight(list.bounds) - list.contentOffset.y;
        if (self.fromTop && self.superview == XHSNativeConfig.shared.homeBar) {
            for (UIView *view in list.subviews) {
                if (![view respondsToSelector:@selector(originalTopInset)] ||
                    ![view respondsToSelector:@selector(isAnimating)]) continue;
                if (((BOOL (*)(id, SEL))objc_msgSend)(view, @selector(isAnimating))) {
                    distance = 0;
                    break;
                }
                // 结束刷新时，加载 inset 可能比刷新状态晚一帧恢复。
                CGFloat baseInset = ((CGFloat (*)(id, SEL))objc_msgSend)(view, @selector(originalTopInset));
                if (baseInset > 0) distance = MIN(distance, list.contentOffset.y + baseInset);
                break;
            }
        }
    }
    CGFloat alpha = MIN(1, MAX(0, (distance - 0.5) / 16.0));
    if (fabs(self.alpha - alpha) > 0.001) self.alpha = alpha;
}

- (void)updateColors {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIColor *base = dark ? [UIColor colorWithRed:0.06 green:0.06 blue:0.07 alpha:1] : UIColor.whiteColor;
    CAGradientLayer *grad = (CAGradientLayer *)self.layer;
    if (self.fromTop) {
        grad.colors = @[
            (id)[base colorWithAlphaComponent:0.86].CGColor,
            (id)[base colorWithAlphaComponent:0.58].CGColor,
            (id)[base colorWithAlphaComponent:0.22].CGColor,
            (id)[base colorWithAlphaComponent:0.0].CGColor
        ];
        grad.locations = @[@0.0, @0.40, @0.74, @1.0];
    } else {
        grad.colors = @[
            (id)[base colorWithAlphaComponent:0.0].CGColor,
            (id)[base colorWithAlphaComponent:0.22].CGColor,
            (id)[base colorWithAlphaComponent:0.58].CGColor,
            (id)[base colorWithAlphaComponent:0.86].CGColor
        ];
        grad.locations = @[@0.0, @0.26, @0.60, @1.0];
    }
    grad.startPoint = CGPointMake(0.5, 0.0);
    grad.endPoint = CGPointMake(0.5, 1.0);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateColors];
}

@end

#pragma mark - 低版本底栏状态

static char kLegacyTabStateKey;

@interface XHSFakeTabBarState : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UITabBar *bar;
@property (nonatomic, strong) XHSFakeGlassPlate *capsule;
@property (nonatomic, strong) UIView *selection;
@property (nonatomic, strong) XHSFakeGlassPlate *searchPlate;
@property (nonatomic, strong) UIButton *searchButton;
@property (nonatomic, assign) BOOL lastSwapped;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UITapGestureRecognizer *expandTap;
@property (nonatomic, strong) UILongPressGestureRecognizer *homeLongPress;
@property (nonatomic, assign) NSUInteger displayedIndex;
@property (nonatomic, assign) CGFloat dragStartLensX;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL minimized;
@property (nonatomic, assign) BOOL updating;
@end

@implementation XHSFakeTabBarState

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.homeLongPress) {
        UIViewController *homePage = [XHSNativeLegacy legacyPageForName:@"index"];
        NSUInteger homeIdx = homePage ? [self.bar.items indexOfObjectIdenticalTo:homePage.tabBarItem] : NSNotFound;
        if (homeIdx == NSNotFound || homeIdx >= self.bar.items.count) return NO;
        if (self.bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft)
            homeIdx = self.bar.items.count - 1 - homeIdx;
        CGPoint loc = [gestureRecognizer locationInView:self.bar];
        if (self.minimized) {
            return self.bar.selectedItem == homePage.tabBarItem && CGRectContainsPoint(self.capsule.frame, loc);
        }
        NSMutableArray<UIView *> *buttons = [NSMutableArray array];
        for (UIView *view in self.bar.subviews) {
            if ([NSStringFromClass(view.class) isEqualToString:@"UITabBarButton"]) [buttons addObject:view];
        }
        [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : (a.frame.origin.x > b.frame.origin.x ? NSOrderedDescending : NSOrderedSame);
        }];
        return homeIdx < buttons.count && CGRectContainsPoint(buttons[homeIdx].frame, loc);
    }
    if (gestureRecognizer == self.expandTap) {
        if (!self.minimized) return NO;
        CGPoint loc = [gestureRecognizer locationInView:self.bar];
        return CGRectContainsPoint(self.capsule.frame, loc);
    }
    if (gestureRecognizer != self.panGesture || self.minimized) return NO;
    CGPoint loc = [gestureRecognizer locationInView:self.bar];
    if (!CGRectContainsPoint(self.capsule.frame, loc)) return NO;
    CGPoint vel = [self.panGesture velocityInView:self.bar];
    return fabs(vel.x) > fabs(vel.y);
}

- (void)handleExpandTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded && self.minimized) {
        [XHSNativeLegacy setLegacyTabBarMinimized:NO];
    }
}

- (void)handleHomeLongPress:(UILongPressGestureRecognizer *)press {
    if (press.state == UIGestureRecognizerStateBegan) [XHSNativeHelper openSettings];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UITabBar *bar = self.bar;
    XYTabbarController *tabBarController = XHSNativeConfig.shared.tabBarController;
    if (!bar || !bar.items.count) return;
    NSUInteger count = bar.items.count;
    CGFloat capW = CGRectGetWidth(self.capsule.bounds);
    CGFloat width = count ? MIN(84, MAX(0, (capW - 6) / count)) : 0;
    CGFloat step = count > 1 ? (capW - 6 - width) / (count - 1) : 0;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        CGPoint center = self.selection.layer.presentationLayer ? self.selection.layer.presentationLayer.position : self.selection.center;
        [self.selection.layer removeAllAnimations];
        self.selection.center = center;
        self.dragStartLensX = center.x - CGRectGetWidth(self.selection.bounds) / 2;
        void (^scaleUp)(void) = ^{
            self.selection.transform = CGAffineTransformMakeScale(1.06, 1.06);
        };
        if (UIAccessibilityIsReduceMotionEnabled()) scaleUp();
        else [UIView animateWithDuration:0.15 animations:scaleUp];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = [pan translationInView:self.capsule].x;
        CGFloat maxX = MAX(3, capW - 3 - width);
        CGFloat newX = MIN(maxX, MAX(3, self.dragStartLensX + dx));
        self.selection.center = CGPointMake(newX + width / 2, self.selection.center.y);
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        BOOL committed = (pan.state == UIGestureRecognizerStateEnded);
        self.dragging = NO;
        CGFloat midX = CGRectGetMidX(self.selection.frame);
        NSInteger target = step > 0 ? (NSInteger)llround((midX - 3 - width / 2.0) / step) : 0;
        target = MIN((NSInteger)count - 1, MAX(0, target));
        if (bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) {
            target = (NSInteger)count - 1 - target;
        }
        void (^resetScale)(void) = ^{
            self.selection.transform = CGAffineTransformIdentity;
        };
        if (UIAccessibilityIsReduceMotionEnabled()) {
            resetScale();
        } else {
            [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:resetScale completion:nil];
        }
        if (committed && (NSUInteger)target < tabBarController.viewControllers.count) {
            UIViewController *vc = tabBarController.viewControllers[target];
            if (tabBarController.selectedViewController != vc) {
                BOOL allowed = ![tabBarController respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] ||
                    [(id)tabBarController tabBarController:tabBarController shouldSelectViewController:vc];
                if (allowed) {
                    tabBarController.selectedViewController = vc;
                    if ([tabBarController respondsToSelector:@selector(tabBarController:didSelectViewController:)])
                        [((id)tabBarController) tabBarController:tabBarController didSelectViewController:vc];
                }
            }
        }
        [XHSNativeLegacy layoutLegacyTabBar:bar];
    }
}

@end

@interface XHSChannelFoldState : NSObject
@property (nonatomic, assign) BOOL hasLastScrolled;
@property (nonatomic, assign) CGFloat lastScrolled;
@property (nonatomic, assign) CGFloat foldOffset;
@property (nonatomic, weak) UIScrollView *trackedScrollView;
@end
@implementation XHSChannelFoldState
@end

@implementation XHSNativeLegacy

+ (UIView *)plateOn:(UIView *)owner key:(const void *)key below:(UIView *)below frame:(CGRect)frame bar:(NSString *)bar {
    XHSFakeGlassPlate *fake = objc_getAssociatedObject(owner, key);
    if (!fake) {
        fake = [[XHSFakeGlassPlate alloc] initWithFrame:frame];
        fake.barName = bar;
        objc_setAssociatedObject(owner, key, fake, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [XHSNativeViewState addDecoration:fake owner:owner];
    BOOL empty = CGRectIsEmpty(frame) || !below.superview;
    if (fake.hidden != empty) fake.hidden = empty;
    if (empty) return fake;

    if (below.superview.clipsToBounds)
        [XHSNativeViewState setValues:@{@"clipsToBounds": @NO} on:below.superview owner:owner];
    NSArray<UIView *> *siblings = below.superview.subviews;
    NSUInteger index = [siblings indexOfObjectIdenticalTo:below];
    if (fake.superview != below.superview || index == 0 || siblings[index - 1] != fake) {
        [below.superview insertSubview:fake belowSubview:below];
    }
    if (!CGRectEqualToRect(fake.frame, frame)) fake.frame = frame;
    fake.barName = bar;
    [fake refreshAppearance];
    return fake;
}

+ (void)refreshAllPlates {
    for (XHSFakeGlassPlate *glass in allFakeGlassPlates()) {
        [glass refreshAppearance];
    }
}

+ (void)clearLegacyBackground:(UIView *)view owner:(NSObject *)owner {
    if (view && view.backgroundColor && ![view.backgroundColor isEqual:UIColor.clearColor]) {
        [XHSNativeViewState setValues:@{@"backgroundColor": UIColor.clearColor} on:view owner:owner ?: view];
    }
}

+ (void)restoreLegacyDecorationsInView:(UIView *)root {
    if (!root) return;
    for (NSObject *owner in XHSNativeViewState.owners) {
        if ([owner isKindOfClass:UIView.class] && [(UIView *)owner isDescendantOfView:root]) {
            [XHSNativeViewState restoreOwner:owner];
        }
    }
}

+ (void)applyLegacySettings {
    [self refreshAllPlates];
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    UITabBar *tabBar = controller.tabBar;
    BOOL tabBarHidden = controller ? [self isControllerTabBarHidden:controller] : NO;
    for (NSObject *owner in XHSNativeViewState.owners) {
        if (![owner isKindOfClass:UIView.class]) continue;
        UIView *view = (UIView *)owner;
        // 底栏被二级设置页隐藏时不触发 UITabBar / UITabBarController 根视图重排，避免干扰 hidesBottomBarWhenPushed 归位
        if (tabBarHidden && view == tabBar) continue;
        [view setNeedsLayout];
        for (UIResponder *r = view; r; r = r.nextResponder) {
            if ([r isKindOfClass:UIViewController.class]) {
                if (!tabBarHidden || r != controller) [((UIViewController *)r).view setNeedsLayout];
                break;
            }
        }
    }
}

+ (BOOL)isGlassView:(UIView *)view {
    return [view isKindOfClass:UIVisualEffectView.class] || [view isKindOfClass:XHSFakeGlassPlate.class] || [view isKindOfClass:XHSFakeEdgeFadeView.class];
}

+ (void)applySoftEdgeFadeOn:(UIView *)bar key:(const void *)key fromTop:(BOOL)fromTop extraHeight:(CGFloat)extraHeight {
    if (!bar || CGRectIsEmpty(bar.bounds)) return;
    XHSFakeEdgeFadeView *fade = objc_getAssociatedObject(bar, key);
    if (!fade) {
        fade = [XHSFakeEdgeFadeView new];
        fade.userInteractionEnabled = NO;
        fade.fromTop = fromTop;
        objc_setAssociatedObject(bar, key, fade, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [XHSNativeViewState addDecoration:fade owner:bar];
    fade.hidden = NO;
    fade.fromTop = fromTop;
    [fade updateColors];
    CGRect frame = fromTop
        ? CGRectMake(0, 0, CGRectGetWidth(bar.bounds), CGRectGetHeight(bar.bounds) + extraHeight)
        : CGRectMake(0, -extraHeight, CGRectGetWidth(bar.bounds), CGRectGetHeight(bar.bounds) + extraHeight);
    if (fade.superview != bar) [bar insertSubview:fade atIndex:0];
    else if (bar.subviews.firstObject != fade) [bar sendSubviewToBack:fade];
    if (!CGRectEqualToRect(fade.frame, frame)) fade.frame = frame;
    [fade updateVisibility];
}

+ (void)attachScrollView:(UIScrollView *)list toBar:(UIView *)bar {
    for (UIView *view in bar.subviews) {
        if (![view isKindOfClass:XHSFakeEdgeFadeView.class]) continue;
        XHSFakeEdgeFadeView *fade = (id)view;
        fade.scrollView = list;
        [fade updateVisibility];
    }
}

+ (UIButton *)glassIconButtonWithSymbol:(NSString *)symbolName label:(NSString *)label handler:(void (^)(void))handler {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.image = [UIImage systemImageNamed:symbolName];
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseForegroundColor = UIColor.labelColor;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *action) { handler(); }]];
    button.accessibilityLabel = label;
    return button;
}

+ (UIViewController *)legacyPageForName:(NSString *)name {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if ([config isTabHidden:name]) return nil;
    NSUInteger index = [config.pageNames indexOfObject:name];
    return (index != NSNotFound && index < config.pages.count) ? config.pages[index] : nil;
}

+ (BOOL)isControllerTabBarHidden:(UITabBarController *)controller {
    if ([controller respondsToSelector:@selector(isTabBarHidden)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(controller, @selector(isTabBarHidden));
    }
    UITabBar *bar = controller.tabBar;
    if (!bar || !bar.window || bar.hidden || bar.alpha < 0.01) return YES;
    if (controller.presentedViewController || controller.transitionCoordinator) return YES;
    UIViewController *selected = controller.selectedViewController;
    if (selected.transitionCoordinator) return YES;
    if ([selected isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)selected;
        if (nav.transitionCoordinator) return YES;
        UIGestureRecognizerState popState = nav.interactivePopGestureRecognizer.state;
        if (popState == UIGestureRecognizerStateBegan || popState == UIGestureRecognizerStateChanged) return YES;
        if (nav.viewControllers.count > 1 && nav.topViewController.hidesBottomBarWhenPushed) return YES;
    }
    if (controller.view.window) {
        if (fabs(CGRectGetMinX(bar.frame) - CGRectGetMinX(controller.view.bounds)) > 1.0) return YES;
        if (CGRectGetMinY(bar.frame) >= CGRectGetMaxY(controller.view.bounds) - 1.0) return YES;
    }
    for (NSString *key in bar.layer.animationKeys) {
        if (![key isEqualToString:@"UIPacingAnimationForAnimatorsKey"]) return YES;
    }
    return NO;
}

+ (void)rebuildLegacyTabs {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    XYTabbarController *controller = config.tabBarController;
    if (!controller || !config.pages.count) return;

    NSArray *legacyNames = [XHSNativeHelper legacyTabNames:controller];
    NSDictionary<NSNumber *, NSString *> *badgeDict = [controller respondsToSelector:@selector(badgeValueDict)] ? controller.badgeValueDict : nil;
    UIViewController *selected = controller.selectedViewController;
    NSMutableArray<UIViewController *> *ordered = [NSMutableArray array];
    NSDictionary<NSString *, NSString *> *tabTitles = @{@"index": @"首页", @"shopping": @"市集", @"message": @"消息", @"me": @"我"};
    BOOL showTitles = config.isTabTitleShown;
    NSDictionary *titleAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:config.tabTitleSize weight:UIFontWeightMedium]};
    for (NSString *name in config.tabOrder) {
        NSUInteger index = [config.pageNames indexOfObject:name];
        if (index == NSNotFound || [config isTabHidden:name]) continue;
        UIViewController *page = config.pages[index];
        page.tabBarItem.title = nil;
        if (showTitles) page.tabBarItem.title = tabTitles[name];
        [page.tabBarItem setTitleTextAttributes:titleAttrs forState:UIControlStateNormal];
        [page.tabBarItem setTitleTextAttributes:titleAttrs forState:UIControlStateSelected];
        page.tabBarItem.image = [XHSNativeHelper tabIcon:name selected:NO];
        page.tabBarItem.selectedImage = [XHSNativeHelper tabIcon:name selected:YES];
        page.tabBarItem.imageInsets = showTitles ? UIEdgeInsetsZero : UIEdgeInsetsMake(6, 0, -6, 0);
        page.tabBarItem.titlePositionAdjustment = showTitles ? UIOffsetMake(0, -2) : UIOffsetZero;
        NSUInteger badgeIndex = [legacyNames indexOfObject:name];
        if (legacyNames && badgeIndex != NSNotFound) {
            id raw = badgeDict[@(badgeIndex)];
            page.tabBarItem.badgeValue = ([raw isKindOfClass:NSString.class] && [raw length]) ? raw : nil;
        }
        [ordered addObject:page];
    }

    config.rebuilding = YES;
    NSArray<UIViewController *> *current = controller.viewControllers;
    config.rebuilding = NO;

    // 仅在可见标签集合或顺序实际变化时才调用 setViewControllers:；
    // 切换「滚动时收起」等开关时不动控制器栈，且在返回转场完全结束、底栏归位到 x=0 前绝不重排，避免打断转场导致底栏卡在屏幕外侧
    if (![current isEqualToArray:ordered]) {
        config.tabsDirty = [self isControllerTabBarHidden:controller];
        if (config.tabsDirty) return;
        config.rebuilding = YES;
        [controller setViewControllers:ordered animated:NO];
        if (selected && [ordered containsObject:selected]) controller.selectedViewController = selected;
        config.rebuilding = NO;
    } else {
        config.tabsDirty = NO;
    }

    for (UITabBarItem *item in controller.tabBar.items) {
        if (item.badgeValue) [XHSNativeHelper refreshBadge:item];
    }
    [self applyTabBarTitleFont:controller.tabBar];
    if (ordered.count) controller.customtabBar.alpha = 0;
    if (![config boolForKey:kXHSNativeMinimize]) [self setLegacyTabBarMinimized:NO];
    if (![self isControllerTabBarHidden:controller]) {
        [controller.tabBar setNeedsLayout];
        [self layoutLegacyTabBar:controller.tabBar];
    }
}

+ (void)setLegacyTabBarMinimized:(BOOL)minimized {
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    if (!controller) return;
    UITabBar *bar = controller.tabBar;
    XHSFakeTabBarState *state = objc_getAssociatedObject(bar, &kLegacyTabStateKey);
    if (!state) return;
    BOOL minimizeEnabled = [XHSNativeConfig.shared boolForKey:kXHSNativeMinimize];
    if (!minimizeEnabled) minimized = NO;
    if (state.minimized == minimized) return;
    state.minimized = minimized;
    void (^applyMinimize)(void) = ^{
        [self layoutLegacyTabBar:bar];
    };
    if (!minimizeEnabled) {
        // 设置页遮住底栏时只更新状态，等 UIKit 下次布局再展开。
        if (![self isControllerTabBarHidden:controller]) [UIView performWithoutAnimation:applyMinimize];
    } else if (UIAccessibilityIsReduceMotionEnabled()) {
        applyMinimize();
    } else {
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:applyMinimize completion:nil];
    }
}

+ (void)layoutLegacyTabBar:(UITabBar *)bar {
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    if (!controller || bar != controller.tabBar || !bar.window) return;
    XHSFakeTabBarState *state = objc_getAssociatedObject(bar, &kLegacyTabStateKey);
    if (state.updating || state.dragging) return;
    if (state && ![XHSNativeConfig.shared boolForKey:kXHSNativeMinimize]) state.minimized = NO;
    BOOL swapped = XHSNativeConfig.shared.isPublishSwapped;
    if (!state) {
        state = [XHSFakeTabBarState new];
        state.bar = bar;
        state.displayedIndex = NSNotFound;

        state.capsule = [XHSFakeGlassPlate new];
        state.capsule.barName = kXHSNativeBarTab;

        state.selection = [UIView new];
        state.selection.userInteractionEnabled = NO;
        [state.capsule addSubview:state.selection];

        state.searchPlate = [XHSFakeGlassPlate new];
        state.searchPlate.barName = kXHSNativeBarTab;

        state.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:state action:@selector(handlePan:)];
        state.panGesture.delegate = state;
        [bar addGestureRecognizer:state.panGesture];

        state.expandTap = [[UITapGestureRecognizer alloc] initWithTarget:state action:@selector(handleExpandTap:)];
        state.expandTap.delegate = state;
        [bar addGestureRecognizer:state.expandTap];

        state.homeLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:state action:@selector(handleHomeLongPress:)];
        state.homeLongPress.minimumPressDuration = 0.45;
        state.homeLongPress.delegate = state;
        [bar addGestureRecognizer:state.homeLongPress];

        objc_setAssociatedObject(bar, &kLegacyTabStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!state.searchButton || state.lastSwapped != swapped) {
        [state.searchButton removeFromSuperview];
        state.lastSwapped = swapped;
        state.searchButton = [self glassIconButtonWithSymbol:(swapped ? @"plus" : @"magnifyingglass")
                                                      label:(swapped ? @"发布" : @"搜索")
                                                    handler:^{
            if (XHSNativeConfig.shared.isPublishSwapped) [XHSNativeHelper openPublish];
            else [XHSNativeHelper openSearch];
        }];
    }

    state.updating = YES;
    void (^applyLayout)(void) = ^{
        CGFloat barWidth = CGRectGetWidth(bar.bounds);
        CGFloat barHeight = CGRectGetHeight(bar.bounds);
        CGFloat safeBottom = bar.safeAreaInsets.bottom;
        CGFloat height = MIN(56, MAX(0, barHeight - 2));
        CGFloat y = MAX(2, safeBottom > 0 ? barHeight - MAX(0, safeBottom - 8) - height : barHeight - height);
        BOOL showSearch = [XHSNativeConfig.shared boolForKey:kXHSNativeSearchTab] || swapped;
        CGFloat sideInset = 18;
        CGFloat searchGap = 10;
        CGFloat searchSize = height;
        NSUInteger count = bar.items.count;
        CGFloat maxCapsuleWidth = showSearch ? MAX(0, barWidth - 2 * sideInset - searchSize - searchGap)
                                             : MAX(0, barWidth - 2 * sideInset);
        CGFloat fullCapsuleWidth = count ? MIN(maxCapsuleWidth, MAX(height, count * 84.0 + 6.0)) : height;
        CGFloat capsuleWidth = state.minimized ? height : fullCapsuleWidth;
        CGRect capsuleFrame = CGRectMake(sideInset, y, capsuleWidth, height);

        for (UIView *view in bar.subviews) {
            NSString *clsName = NSStringFromClass(view.class);
            if ([clsName isEqualToString:@"_UIBarBackground"]) {
                if (!view.hidden) view.hidden = YES;
            } else if ([clsName isEqualToString:@"XYTabBar"]) {
                view.alpha = 0;
                view.hidden = YES;
                view.userInteractionEnabled = NO;
            }
        }
        static char kTabFadeKey;
        [self applySoftEdgeFadeOn:bar key:&kTabFadeKey fromTop:NO extraHeight:10];
        UIViewController *selectedPage = controller.selectedViewController;
        if ([selectedPage isKindOfClass:UINavigationController.class]) selectedPage = ((UINavigationController *)selectedPage).topViewController;
        UIScrollView *bottomList = nil;
        if (selectedPage.isViewLoaded) [XHSNativeHelper findListIn:selectedPage.view underBar:bar best:&bottomList];
        [self attachScrollView:bottomList toBar:bar];

        if (state.capsule.superview != bar) [bar insertSubview:state.capsule atIndex:MIN(1, bar.subviews.count)];
        state.capsule.hidden = NO;
        state.capsule.alpha = 1.0;
        if (!CGRectEqualToRect(state.capsule.frame, capsuleFrame)) state.capsule.frame = capsuleFrame;
        [state.capsule refreshAppearance];

        state.searchPlate.hidden = !showSearch;
        state.searchButton.hidden = !showSearch;
        if (showSearch) {
            CGFloat searchX = barWidth - sideInset - searchSize;
            CGRect searchFrame = CGRectMake(searchX, y, searchSize, searchSize);
            if (state.searchPlate.superview != bar) [bar addSubview:state.searchPlate];
            if (state.searchButton.superview != bar) [bar addSubview:state.searchButton];
            if (!CGRectEqualToRect(state.searchPlate.frame, searchFrame)) state.searchPlate.frame = searchFrame;
            if (!CGRectEqualToRect(state.searchButton.frame, searchFrame)) state.searchButton.frame = searchFrame;
            [state.searchPlate refreshAppearance];
            [bar bringSubviewToFront:state.searchPlate];
            [bar bringSubviewToFront:state.searchButton];
        }

        CGFloat width = count ? MIN(84, MAX(0, (fullCapsuleWidth - 6) / count)) : 0;
        CGFloat step = count > 1 ? (fullCapsuleWidth - 6 - width) / (count - 1) : 0;

        NSMutableArray<UIView *> *buttons = [NSMutableArray array];
        for (UIView *view in bar.subviews) {
            if ([NSStringFromClass(view.class) isEqualToString:@"UITabBarButton"]) [buttons addObject:view];
        }
        [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : (a.frame.origin.x > b.frame.origin.x ? NSOrderedDescending : NSOrderedSame);
        }];

        NSUInteger selected = bar.selectedItem ? [bar.items indexOfObjectIdenticalTo:bar.selectedItem] : NSNotFound;
        NSUInteger physicalSelected = selected < count && bar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft
            ? count - 1 - selected : selected;
        for (NSUInteger i = 0; i < buttons.count && i < count; i++) {
            UIView *btn = buttons[i];
            if (btn.hidden) btn.hidden = NO;
            btn.layer.sublayerTransform = CATransform3DIdentity;
            if (state.minimized) {
                BOOL isActive = (i == physicalSelected) || (selected == NSNotFound && i == 0);
                btn.alpha = isActive ? 1.0 : 0.0;
                btn.userInteractionEnabled = NO;
                CGRect btnFrame = CGRectMake(sideInset, CGRectGetMinY(capsuleFrame) + 3, height, height - 6);
                if (!CGRectEqualToRect(btn.frame, btnFrame)) btn.frame = btnFrame;
            } else {
                btn.alpha = 1.0;
                btn.userInteractionEnabled = YES;
                CGRect btnFrame = CGRectMake(CGRectGetMinX(capsuleFrame) + 3 + i * step, CGRectGetMinY(capsuleFrame) + 3, width, height - 6);
                if (!CGRectEqualToRect(btn.frame, btnFrame)) btn.frame = btnFrame;
            }
        }

        BOOL dark = bar.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        if (selected < count && !state.minimized) {
            CGRect target = CGRectMake(3 + physicalSelected * step, 3, width, height - 6);
            CALayer *lens = state.selection.layer;
            NSString *key = @"xhs.selection.slide";
            BOOL changed = state.displayedIndex != NSNotFound && state.displayedIndex != selected;
            BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
            if (!CGRectEqualToRect(state.selection.frame, target)) {
                CGFloat start = lens.position.x;
                if ([lens animationForKey:key] && lens.presentationLayer) start = lens.presentationLayer.position.x;
                BOOL slide = changed && CGSizeEqualToSize(state.selection.bounds.size, target.size) && !reduceMotion;
                state.selection.frame = target;
                if (slide) {
                    CABasicAnimation *motion = [CABasicAnimation animationWithKeyPath:@"position.x"];
                    motion.fromValue = @(start);
                    motion.toValue = @(CGRectGetMidX(target));
                    motion.duration = 0.28;
                    motion.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                    [lens addAnimation:motion forKey:key];
                } else {
                    [lens removeAnimationForKey:key];
                }
            }
            if (reduceMotion) [lens removeAnimationForKey:key];
            state.displayedIndex = selected;
            state.selection.layer.cornerRadius = (height - 6) / 2;
            state.selection.layer.cornerCurve = kCACornerCurveContinuous;
            state.selection.backgroundColor = [UIColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.16 : 0.08];
            state.selection.alpha = 1.0;
            state.selection.hidden = NO;
        } else {
            state.displayedIndex = selected;
            [state.selection.layer removeAnimationForKey:@"xhs.selection.slide"];
            state.selection.alpha = 0.0;
        }
    };
    BOOL inTransition = (controller.transitionCoordinator != nil || controller.selectedViewController.transitionCoordinator != nil);
    if ([UIView areAnimationsEnabled] && !inTransition) applyLayout();
    else [UIView performWithoutAnimation:applyLayout];
    state.updating = NO;
}

// 透明底，字号用设置里的
+ (void)styleTabBarAppearance:(UITabBarAppearance *)appearance {
    [appearance configureWithTransparentBackground];
    UIFont *font = [UIFont systemFontOfSize:XHSNativeConfig.shared.tabTitleSize weight:UIFontWeightMedium];
    NSArray<UITabBarItemAppearance *> *layouts = @[appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance];
    for (UITabBarItemAppearance *layout in layouts) {
        NSMutableDictionary *normal = [layout.normal.titleTextAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
        normal[NSFontAttributeName] = font;
        layout.normal.titleTextAttributes = normal;
        NSMutableDictionary *selected = [layout.selected.titleTextAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
        selected[NSFontAttributeName] = font;
        layout.selected.titleTextAttributes = selected;
    }
}

+ (void)applyTabBarTitleFont:(UITabBar *)bar {
    if (!bar) return;
    UIFont *font = [UIFont systemFontOfSize:XHSNativeConfig.shared.tabTitleSize weight:UIFontWeightMedium];
    NSDictionary *attrs = @{NSFontAttributeName: font};
    for (UITabBarItem *item in bar.items) {
        [item setTitleTextAttributes:attrs forState:UIControlStateNormal];
        [item setTitleTextAttributes:attrs forState:UIControlStateSelected];
    }
    UITabBarAppearance *standard = [UITabBarAppearance new];
    [self styleTabBarAppearance:standard];
    bar.standardAppearance = standard;
    bar.scrollEdgeAppearance = [standard copy];
}

+ (void)handleScrollPan:(UIPanGestureRecognizer *)pan inPage:(UIViewController *)page {
    UIScrollView *list = (UIScrollView *)pan.view;
    [self attachScrollView:list toBar:XHSNativeConfig.shared.tabBarController.tabBar];
    if (pan.state == UIGestureRecognizerStateChanged && [XHSNativeConfig.shared boolForKey:kXHSNativeMinimize]) {
        XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
        if (controller && page.navigationController.parentViewController == controller && ![self isControllerTabBarHidden:controller]) {
            CGFloat vy = [pan velocityInView:list].y;
            if (vy < -180) [self setLegacyTabBarMinimized:YES];
            else if (vy > 180) [self setLegacyTabBarMinimized:NO];
        }
    }
    UIView *homeBar = XHSNativeConfig.shared.homeBar;
    if (homeBar && [list isDescendantOfView:homeBar.superview]) {
        [self extendHomeFeedUnderNaviBar:homeBar];
    }
}

#pragma mark - 首页延伸 / 二级频道栏 / 悬浮提示

static void adjustFloatingPillsUnderBar(UIView *container, UIView *root, UIView *skip, CGFloat barBottom, CGFloat maxW, UIView *owner) {
    for (UIView *v in container.subviews) {
        if (v == skip) continue;
        CGFloat w = CGRectGetWidth(v.bounds);
        CGFloat h = CGRectGetHeight(v.bounds);
        if (!v.hidden && v.alpha > 0.01 && ![v isKindOfClass:UIScrollView.class] && h >= 24 && h <= 56 && w > 60 && w < maxW - 40) {
            CGFloat rawY = v.center.y - h / 2.0;
            CGFloat rootY = [root convertPoint:CGPointMake(0, rawY) fromView:container].y;
            if (rootY < barBottom + 4) {
                [XHSNativeViewState setValues:@{@"transform": [NSValue valueWithCGAffineTransform:CGAffineTransformMakeTranslation(0, barBottom + 8 - rootY)]} on:v owner:owner];
                continue;
            }
        }
        [XHSNativeViewState restoreProperties:@[@"transform"] on:v owner:owner];
    }
}

static UIScrollView *findActiveFeedScrollView(UIView *root) {
    if ([root isKindOfClass:UIScrollView.class]) {
        UIScrollView *sv = (UIScrollView *)root;
        if (!sv.hidden && sv.alpha > 0.01 && CGRectGetHeight(sv.bounds) >= 200 && !sv.pagingEnabled) {
            if (!sv.window) return sv;
            CGRect winRect = [sv convertRect:sv.bounds toView:nil];
            if (CGRectGetWidth(CGRectIntersection(winRect, sv.window.bounds)) > CGRectGetWidth(sv.window.bounds) * 0.5) {
                return sv;
            }
        }
    }
    for (UIView *sub in root.subviews) {
        UIScrollView *found = findActiveFeedScrollView(sub);
        if (found) return found;
    }
    return nil;
}

static BOOL syncPullToRefreshInset(UIScrollView *sv, CGFloat targetTop, CGFloat *refreshHeightOut) {
    BOOL loading = NO;
    CGFloat refreshH = 60;
    for (UIView *sub in sv.subviews) {
        if ([sub respondsToSelector:@selector(originalTopInset)] && [sub respondsToSelector:@selector(setOriginalTopInset:)]) {
            if (CGRectGetHeight(sub.bounds) > 0) refreshH = CGRectGetHeight(sub.bounds);
            CGFloat curOrig = ((CGFloat (*)(id, SEL))objc_msgSend)(sub, @selector(originalTopInset));
            if (fabs(curOrig - targetTop) > 0.5) {
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(sub, @selector(setOriginalTopInset:), targetTop);
            }
            if ([sub respondsToSelector:@selector(isAnimating)] && ((BOOL (*)(id, SEL))objc_msgSend)(sub, @selector(isAnimating))) {
                loading = YES;
            } else if ([sub respondsToSelector:@selector(state)]) {
                NSInteger st = ((NSInteger (*)(id, SEL))objc_msgSend)(sub, @selector(state));
                if (st >= 2 && sv.contentInset.top > targetTop + 10) loading = YES;
            }
        }
    }
    if (refreshHeightOut) *refreshHeightOut = refreshH;
    return loading;
}

static void applyHomeTopInset(UIView *view, CGFloat targetTop, CGFloat safeBottom) {
    static char kAppliedHomeTopKey;
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *sv = (UIScrollView *)view;
        if (CGRectGetHeight(sv.bounds) < 200) return;
        if (!sv.pagingEnabled) {
            // 小红书原生列表原先位于顶栏下方（safeArea.top == 0），其冷启动偏移、XYTabbarClicked 与下拉刷新
            // 均以 -contentInset.top 而非 -adjustedContentInset.top 作为顶部基准；将列表拉到 y=0 后必须设为 Never，
            // 使 contentInset.top == adjustedContentInset.top == targetTop，消除 +59pt 错位引发的白色卡片上窜与顶栏渐隐误亮
            CGFloat oldAdjTop = sv.adjustedContentInset.top;
            CGFloat oldInsetTop = sv.contentInset.top;
            NSNumber *prevApplied = objc_getAssociatedObject(sv, &kAppliedHomeTopKey);
            UIEdgeInsets inset = sv.contentInset;
            BOOL insetChanged = NO;
            if (sv.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever) {
                sv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
                if (safeBottom > 0 && inset.bottom < 60 + safeBottom - 0.5) {
                    inset.bottom = MAX(inset.bottom, 60) + safeBottom;
                    insetChanged = YES;
                }
            }
            // 先同步 XYPullToRefreshView.originalTopInset；刷新加载中绝不改写 contentInset，
            // 避免在 stopAnimating -> resetScrollViewContentInset 收尾瞬间（isAnimating 尚未清零）把 inset.top 写回 targetTop+60 导致永久卡死在 204
            if (syncPullToRefreshInset(sv, targetTop, NULL)) return;
            if (fabs(inset.top - targetTop) > 0.5 || insetChanged) {
                BOOL wasAtTop = (!prevApplied && sv.contentOffset.y <= 2.0)
                    || fabs(sv.contentOffset.y + oldInsetTop) < 2.0
                    || fabs(sv.contentOffset.y + oldAdjTop) < 2.0;
                inset.top = targetTop;
                sv.contentInset = inset;
                if (wasAtTop) {
                    sv.contentOffset = CGPointMake(sv.contentOffset.x, -targetTop);
                }
            }
            UIEdgeInsets indicator = sv.verticalScrollIndicatorInsets;
            if (fabs(indicator.top - targetTop) > 0.5) {
                indicator.top = targetTop;
                sv.verticalScrollIndicatorInsets = indicator;
            }
            objc_setAssociatedObject(sv, &kAppliedHomeTopKey, @(targetTop), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
    }
    for (UIView *sub in view.subviews) {
        applyHomeTopInset(sub, targetTop, safeBottom);
    }
}

+ (void)layoutHomeBar:(UIView *)bar {
    static char kFadeKey;
    [self applySoftEdgeFadeOn:bar key:&kFadeKey fromTop:YES extraHeight:10];
    [self extendHomeFeedUnderNaviBar:bar];
}

// 左上角的入口按图标画一个圆，右上角的搜索或发布按按钮的大小
+ (void)plateHomeBar:(UIView *)bar menu:(UIView *)menu button:(UIView *)button {
    static char kMenuKey, kButtonKey;
    CGPoint center = CGPointMake(CGRectGetMidX(menu.frame), CGRectGetMidY(menu.frame));
    for (UIView *icon in menu.subviews) {
        if (![icon isKindOfClass:UIImageView.class] || CGRectGetWidth(icon.bounds) <= 0) continue;
        center = [bar convertPoint:CGPointMake(CGRectGetMidX(icon.bounds), CGRectGetMidY(icon.bounds)) fromView:icon];
        break;
    }
    CGRect circle = CGRectMake(round(center.x - 22), round(center.y - 22), 44, 44);
    [XHSNativeHelper plateOn:bar key:&kMenuKey below:menu frame:[XHSNativeHelper isVisible:menu] ? circle : CGRectZero bar:kXHSNativeBarHome].alpha = menu.alpha;
    [XHSNativeHelper plateOn:bar key:&kButtonKey below:button frame:[XHSNativeHelper isVisible:button] ? button.frame : CGRectZero bar:kXHSNativeBarHome].alpha = button.alpha;
}

+ (void)extendHomeFeedUnderNaviBar:(UIView *)naviBar {
    static BOOL extending;
    if (!naviBar.superview || extending) return;
    UIView *root = naviBar.superview;
    CGFloat barBottom = CGRectGetMaxY(naviBar.frame);
    if (barBottom <= 0) return;
    CGFloat safeBottom = root.window.safeAreaInsets.bottom;
    // 设置 contentInset 会同步回调滚动通知，不能重入并把插件值记为原值。
    extending = YES;
    [self clearLegacyBackground:naviBar owner:naviBar];
    if (naviBar.opaque) [XHSNativeViewState setValues:@{@"opaque": @NO} on:naviBar owner:naviBar];
    UIViewController *home = (id)root.nextResponder;
    if ([root isMemberOfClass:UIView.class] &&
        [home isKindOfClass:objc_getClass("XYMHomeViewController")] && home.viewIfLoaded == root) {
        [self clearLegacyBackground:root owner:naviBar];
        if (root.opaque) [XHSNativeViewState setValues:@{@"opaque": @NO} on:root owner:naviBar];
    }
    for (UIView *view in naviBar.subviews) {
        if ([self isGlassView:view] || [view isKindOfClass:XHSFakeEdgeFadeView.class] || view.userInteractionEnabled) continue;
        if (CGRectGetWidth(view.frame) >= CGRectGetWidth(naviBar.bounds) - 2 && CGRectGetHeight(view.frame) > 20 && view.alpha > 0) {
            [XHSNativeViewState setValues:@{@"alpha": @0} on:view owner:naviBar];
        }
    }
    for (UIView *sub in root.subviews) {
        for (UIView *child in sub.subviews) {
            if (![child isKindOfClass:UIScrollView.class]) continue;
            UIScrollView *pager = (UIScrollView *)child;
            if (!pager.pagingEnabled) continue;
            CGFloat pageH = CGRectGetHeight(pager.bounds);
            for (UIView *page in pager.subviews) {
                UIView *topChannelBar = nil;
                CGFloat channelBarH = 0;
                CGFloat channelRawY = 0;
                for (UIView *item in page.subviews) {
                    if (item.hidden) continue;
                    CGFloat rawY = item.center.y - CGRectGetHeight(item.bounds) / 2.0;
                    CGFloat h = CGRectGetHeight(item.bounds);
                    if (![item isKindOfClass:UIScrollView.class] && rawY >= -h - 5 && rawY < 20 && h > 20 && h < 80) {
                        topChannelBar = item;
                        channelBarH = h;
                        channelRawY = rawY;
                        break;
                    }
                }
                if (CGRectGetMinY(page.frame) > 1 && fabs(CGRectGetMinY(page.frame) - barBottom) < 20) {
                    CGRect pf = page.frame;
                    pf.origin.y = 0;
                    pf.size.height = pageH;
                    page.frame = pf;
                }
                if (topChannelBar) {
                    static char kChannelFoldStateKey;
                    XHSChannelFoldState *fold = objc_getAssociatedObject(topChannelBar, &kChannelFoldStateKey);
                    if (!fold) {
                        fold = [XHSChannelFoldState new];
                        objc_setAssociatedObject(topChannelBar, &kChannelFoldStateKey, fold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    UIScrollView *feedSV = findActiveFeedScrollView(page);
                    if (feedSV != fold.trackedScrollView) {
                        fold.trackedScrollView = feedSV;
                        fold.hasLastScrolled = NO;
                    }
                    if (feedSV) {
                        [self attachScrollView:feedSV toBar:naviBar];
                        CGFloat scrolled = feedSV.contentOffset.y + feedSV.adjustedContentInset.top;
                        if (scrolled <= 2.0) {
                            fold.foldOffset = 0;
                        } else if (fold.hasLastScrolled) {
                            CGFloat delta = scrolled - fold.lastScrolled;
                            if (delta > 0 && scrolled > 6.0) {
                                fold.foldOffset = MIN(channelBarH, fold.foldOffset + delta);
                            } else if (delta < 0) {
                                fold.foldOffset = MAX(0.0, fold.foldOffset + delta);
                            }
                        }
                        fold.lastScrolled = scrolled;
                        fold.hasLastScrolled = YES;
                    }
                    CGFloat effectiveFold = MIN(channelBarH, MAX(fold.foldOffset, -MIN(0.0, channelRawY)));
                    CGFloat progress = channelBarH > 0 ? (effectiveFold / channelBarH) : 0;
                    topChannelBar.alpha = MAX(0.0, 1.0 - progress * 1.25);
                    topChannelBar.userInteractionEnabled = (progress < 0.8);
                    topChannelBar.transform = CGAffineTransformMakeTranslation(0, barBottom - channelRawY - effectiveFold);
                    [XHSNativeHelper clearBackground:topChannelBar];
                    for (UIView *subView in topChannelBar.subviews) {
                        if ([subView isKindOfClass:UIButton.class]) {
                            [XHSNativeHelper clearBackground:subView];
                        } else if (![subView isKindOfClass:UICollectionView.class] && subView.alpha > 0) {
                            subView.alpha = 0;
                        }
                    }
                }
                CGFloat targetTop = barBottom + channelBarH;
                CGFloat pageW = CGRectGetWidth(page.bounds);
                adjustFloatingPillsUnderBar(page, root, topChannelBar, targetTop, pageW, naviBar);
                for (UIView *item in page.subviews) {
                    if (item == topChannelBar) continue;
                    if (CGRectGetMinY(item.frame) < 0 && CGRectGetMaxY(item.frame) <= 1 && !item.subviews.count && item.alpha > 0) {
                        item.alpha = 0;
                    }
                    if (topChannelBar && CGRectGetMinY(item.frame) > 1 && CGRectGetMinY(item.frame) <= channelBarH + 20 && CGRectGetHeight(item.frame) > pageH * 0.5) {
                        if (!item.translatesAutoresizingMaskIntoConstraints) {
                            for (NSLayoutConstraint *c in page.constraints) {
                                if (c.firstItem == item && c.firstAttribute == NSLayoutAttributeTop) {
                                    if (c.secondItem == topChannelBar && c.secondAttribute == NSLayoutAttributeBottom) {
                                        if (fabs(c.constant + channelBarH) > 0.5) c.constant = -channelBarH;
                                    } else if (c.secondItem == page && c.secondAttribute == NSLayoutAttributeTop) {
                                        if (fabs(c.constant) > 0.5) c.constant = 0;
                                    }
                                }
                            }
                        }
                        CGRect sf = item.frame;
                        sf.origin.y = 0;
                        sf.size.height = pageH;
                        item.frame = sf;
                    }
                    adjustFloatingPillsUnderBar(item, root, nil, targetTop, pageW, naviBar);
                    if ([item.subviews.firstObject isKindOfClass:UIScrollView.class]) {
                        UIScrollView *innerPager = (UIScrollView *)item.subviews.firstObject;
                        for (UIView *subPage in innerPager.subviews) {
                            adjustFloatingPillsUnderBar(subPage, root, nil, targetTop, pageW, naviBar);
                        }
                    }
                    applyHomeTopInset(item, targetTop, safeBottom);
                }
            }
        }
    }
    extending = NO;
}

#pragma mark - 个人页 / 笔记页低版本补丁

+ (void)layoutProfileBar:(XYPFProfileV2NavigationBar *)bar {
    static char leftKey, rightKey;
    UIView *menu = [bar homeMenuButton];
    UIView *share = [bar shareButton], *scan = [bar scanButton], *edit = [bar editButton];
    BOOL enabled = [XHSNativeConfig.shared boolForKey:kXHSNativeGlassProfile] && ![bar usesDuoNavigation] && [XHSNativeHelper isVisible:menu] && menu.superview == bar;
    if (!enabled) {
        [XHSNativeViewState restoreOwner:bar];
        return;
    }

    CGRect menuFrame = menu.frame;
    CGFloat barW = CGRectGetWidth(bar.bounds);
    CGFloat y = CGRectGetMinY(menuFrame);
    CGFloat h = CGRectGetHeight(menuFrame);
    if (h <= 0) h = 36;
    if (y <= 0 && bar.superview) y = bar.window ? MAX(bar.window.safeAreaInsets.top + 4, 44) : 44;

    if (enabled && CGRectGetWidth(menuFrame) > 0) {
        [self plateOn:bar key:&leftKey below:menu frame:CGRectInset(menuFrame, -6, -6) bar:kXHSNativeBarProfile];
    } else {
        ((UIView *)objc_getAssociatedObject(bar, &leftKey)).hidden = YES;
    }

    NSMutableArray<UIView *> *rightBtns = [NSMutableArray array];
    for (UIView *button in @[edit ?: [NSNull null], scan ?: [NSNull null], share ?: [NSNull null]]) {
        if ((id)button == [NSNull null] || button.superview != bar || button.hidden || button.alpha <= 0.01) continue;
        [rightBtns addObject:button];
    }
    if (enabled && rightBtns.count && barW > 0) {
        CGFloat x = barW - 14;
        CGRect group = CGRectNull;
        for (NSInteger idx = (NSInteger)rightBtns.count - 1; idx >= 0; idx--) {
            UIView *btn = rightBtns[idx];
            CGSize sz = btn.bounds.size;
            if (sz.width <= 0) sz = CGSizeMake(h, h);
            x -= sz.width;
            CGRect f = CGRectMake(x, y + (h - sz.height) / 2, sz.width, sz.height);
            [XHSNativeViewState setValues:@{@"frame": [NSValue valueWithCGRect:f]} on:btn owner:bar];
            group = CGRectUnion(group, f);
            x -= 8;
        }
        // 取 bar.subviews 中层级最靠下的按钮作为 below 目标，避免玻璃底板盖住其他按钮（如 share）
        UIView *lowest = nil;
        for (UIView *sub in bar.subviews) {
            if ([rightBtns containsObject:sub]) {
                lowest = sub;
                break;
            }
        }
        if (lowest && !CGRectIsNull(group)) {
            [self plateOn:bar key:&rightKey below:lowest frame:CGRectInset(group, -6, -6) bar:kXHSNativeBarProfile];
        } else {
            ((UIView *)objc_getAssociatedObject(bar, &rightKey)).hidden = YES;
        }
    } else {
        ((UIView *)objc_getAssociatedObject(bar, &rightKey)).hidden = YES;
    }
}

static void constrainLabelsInView(UIView *view, UIView *owner) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        [XHSNativeViewState setValues:@{@"lineBreakMode": @(NSLineBreakByTruncatingTail),
                                      @"adjustsFontSizeToFitWidth": @YES, @"minimumScaleFactor": @0.72} on:label owner:owner];
        return;
    }
    for (UIView *sub in view.subviews) {
        constrainLabelsInView(sub, owner);
    }
}

static void clipContentWidth(UIView *view, CGFloat width, UIView *owner) {
    static char kContentMaskKey;
    CAShapeLayer *mask = objc_getAssociatedObject(view, &kContentMaskKey);
    if (!mask) {
        mask = [CAShapeLayer layer];
        objc_setAssociatedObject(view, &kContentMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect rect = CGRectMake(0, -4, width, CGRectGetHeight(view.bounds) + 8);
    if (!mask.path || !CGRectEqualToRect(CGPathGetBoundingBox(mask.path), rect))
        mask.path = [UIBezierPath bezierPathWithRect:rect].CGPath;
    [XHSNativeViewState setValues:@{@"layer.mask": mask} on:view owner:owner];
}

+ (void)adjustNoteBottomInStack:(UIView *)stack {
    // 取消底栏容器裁剪，避免仿玻璃外缘高光与阴影被截断导致缺少厚度感
    UIView *content = stack.superview;
    if (content.clipsToBounds) [XHSNativeViewState setValues:@{@"clipsToBounds": @NO} on:content owner:content];
    if (content.superview.clipsToBounds) [XHSNativeViewState setValues:@{@"clipsToBounds": @NO} on:content.superview owner:content];

    UIView *leftGlass = nil, *rightGlass = nil;
    for (UIView *sub in content.subviews) {
        if ([self isGlassView:sub] && !sub.hidden && CGRectGetWidth(sub.frame) > 0) {
            if (!leftGlass || CGRectGetMinX(sub.frame) < CGRectGetMinX(leftGlass.frame)) {
                if (leftGlass && (!rightGlass || CGRectGetMinX(leftGlass.frame) > CGRectGetMinX(rightGlass.frame))) {
                    rightGlass = leftGlass;
                }
                leftGlass = sub;
            } else if (!rightGlass || CGRectGetMinX(sub.frame) > CGRectGetMinX(rightGlass.frame)) {
                rightGlass = sub;
            }
        }
    }

    UIView *fieldGroup = nil;
    UIView *editField = nil;
    UIButton *commentBtn = nil;
    for (UIView *group in stack.subviews) {
        for (UIView *field in group.subviews) {
            if ([NSStringFromClass(field.class) hasSuffix:@"Field"] && !field.hidden) {
                fieldGroup = fieldGroup ?: group;
                if ([NSStringFromClass(field.class) hasSuffix:@"InteractionEditField"]) editField = field;
                else if ([field isKindOfClass:UIButton.class] && [NSStringFromClass(field.class) hasSuffix:@"CommentField"]) commentBtn = (UIButton *)field;
            }
        }
    }
    if (editField) {
        [XHSNativeViewState setValues:@{@"transform": [NSValue valueWithCGAffineTransform:CGAffineTransformMakeTranslation(6, 0)]} on:editField owner:content];
    }
    if (!leftGlass || !fieldGroup) return;

    // 当右侧互动胶囊较宽（如 10w+）导致左侧「说点什么...」会被挤压时，
    // 自动隐藏文字、只保留前面图标，并将左胶囊收成 48x48 圆形按钮；
    // 无论右侧玻璃是否存在，每轮都统一更新 titleLabel 显示状态，避免退回整条胶囊后文案无法恢复
    BOOL compactIconOnly = NO;
    if (commentBtn) {
        UILabel *titleLabel = commentBtn.titleLabel;
        if (rightGlass && !rightGlass.hidden && titleLabel) {
            CGFloat textW = [titleLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, 36)].width;
            CGFloat minNeededW = 6 + CGRectGetMinX(titleLabel.frame) + textW + 10;
            if (minNeededW > 80 && CGRectGetWidth(leftGlass.frame) < minNeededW) {
                compactIconOnly = YES;
                CGFloat h = CGRectGetHeight(leftGlass.frame);
                CGRect circle = CGRectMake(CGRectGetMinX(leftGlass.frame), CGRectGetMinY(leftGlass.frame), h, h);
                if (!CGRectEqualToRect(leftGlass.frame, circle)) {
                    leftGlass.frame = circle;
                    if ([leftGlass isKindOfClass:XHSFakeGlassPlate.class]) [(XHSFakeGlassPlate *)leftGlass refreshAppearance];
                }
            }
        }
        if (titleLabel) {
            if (compactIconOnly) [XHSNativeViewState setValues:@{@"hidden": @YES, @"alpha": @0} on:titleLabel owner:content];
            else [XHSNativeViewState restoreProperties:@[@"hidden", @"alpha"] on:titleLabel owner:content];
        }
    }

    // 不修改 fieldGroup / field 的 bounds，避免改变 layoutFrame 导致上游 setOffset 来回漂移；
    // 仅用 layer.mask 裁剪超出左胶囊的部分，并对内部文案做自适应缩放/截断。
    CGRect fgInContent = [content convertRect:fieldGroup.bounds fromView:fieldGroup];
    CGFloat maxRight = CGRectGetMaxX(leftGlass.frame) - (compactIconOnly ? 2 : 8);
    CGFloat availW = MAX(36, maxRight - CGRectGetMinX(fgInContent));
    CGFloat fgW = CGRectGetWidth(fieldGroup.bounds);
    if (fgW > availW) {
        clipContentWidth(fieldGroup, availW, content);
    } else {
        [XHSNativeViewState restoreProperties:@[@"layer.mask"] on:fieldGroup owner:content];
    }

    for (UIView *field in fieldGroup.subviews) {
        if (![NSStringFromClass(field.class) hasSuffix:@"Field"] || field.hidden) continue;
        CGFloat fieldMaxW = MAX(32, availW - MAX(0, field.transform.tx));
        if (!compactIconOnly) {
            constrainLabelsInView(field, content);
            if ([field isKindOfClass:UIButton.class]) {
                UILabel *titleLabel = ((UIButton *)field).titleLabel;
                if (titleLabel && CGRectGetMaxX(titleLabel.frame) > fieldMaxW - 2) {
                    CGRect tf = titleLabel.frame;
                    tf.size.width = MAX(20, fieldMaxW - 2 - CGRectGetMinX(tf));
                    [XHSNativeViewState setValues:@{@"frame": [NSValue valueWithCGRect:tf]} on:titleLabel owner:content];
                }
            }
        }
    }
}

+ (void)layoutAdNoteBottom:(UIView *)adBar {
    static char kAdLeftGlassKey, kAdRightGlassKey;
    if (!adBar.window) return;
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote]) {
        [XHSNativeViewState restoreOwner:adBar];
        return;
    }
    if (adBar.clipsToBounds) [XHSNativeViewState setValues:@{@"clipsToBounds": @NO} on:adBar owner:adBar];
    if (adBar.superview.clipsToBounds) [XHSNativeViewState setValues:@{@"clipsToBounds": @NO} on:adBar.superview owner:adBar];
    [self clearLegacyBackground:adBar owner:adBar];
    [self clearLegacyBackground:adBar.superview owner:adBar];

    if ([adBar respondsToSelector:@selector(seperatorView)]) {
        UIView *sep = [adBar performSelector:@selector(seperatorView)];
        if (sep) [XHSNativeViewState setValues:@{@"hidden": @YES, @"alpha": @0} on:sep owner:adBar];
    }
    for (UIView *container in @[adBar, adBar.superview ?: adBar]) {
        for (UIView *view in container.subviews) {
            if ([self isGlassView:view]) continue;
            if (!view.subviews.count && CGRectGetHeight(view.frame) > 0 && CGRectGetHeight(view.frame) <= 1.5) {
                [XHSNativeViewState setValues:@{@"hidden": @YES, @"alpha": @0} on:view owner:adBar];
            }
        }
    }

    NSMutableArray<UIView *> *leftViews = [NSMutableArray array];
    NSMutableArray<UIView *> *rightViews = [NSMutableArray array];
    UIView *firstContent = nil;
    CGFloat width = CGRectGetWidth(adBar.bounds);
    CGFloat minLeftX = CGFLOAT_MAX, maxLeftX = 0;
    CGFloat minRightX = CGFLOAT_MAX, maxRightX = 0;
    CGFloat minBaseY = CGFLOAT_MAX, maxBaseY = 0;

    for (UIView *view in adBar.subviews) {
        if ([self isGlassView:view] || view.hidden || CGRectGetHeight(view.bounds) <= 1.5) continue;
        if (!firstContent) firstContent = view;
        // 使用未叠加 transform 的 bounds/center 计算原始范围，避免反复 layoutSubviews 时偏移累积
        CGFloat halfW = CGRectGetWidth(view.bounds) / 2.0;
        CGFloat halfH = CGRectGetHeight(view.bounds) / 2.0;
        CGFloat minX = view.center.x - halfW, maxX = view.center.x + halfW;
        minBaseY = MIN(minBaseY, view.center.y - halfH);
        maxBaseY = MAX(maxBaseY, view.center.y + halfH);

        NSString *clsName = NSStringFromClass(view.class);
        BOOL isLeft = [clsName containsString:@"EngageBar"] || [clsName hasSuffix:@"Field"] || view.center.x < width * 0.45;
        if (isLeft) {
            [leftViews addObject:view];
            minLeftX = MIN(minLeftX, minX);
            maxLeftX = MAX(maxLeftX, maxX);
        } else {
            [rightViews addObject:view];
            minRightX = MIN(minRightX, minX);
            maxRightX = MAX(maxRightX, maxX);
        }
    }
    if (!firstContent) return;

    CGFloat height = 48, gap = 10, padding = 10;
    CGFloat below = CGRectGetHeight(adBar.window.bounds) - CGRectGetMaxY([adBar convertRect:adBar.bounds toView:nil]);
    CGFloat margin = adBar.window.safeAreaInsets.bottom > 0 ? 20 : MAX(12, (CGRectGetHeight(adBar.bounds) - height) / 2);
    CGFloat y = CGRectGetHeight(adBar.bounds) + below - margin - height;

    CGRect left = CGRectMake(margin, y, MAX(0, width - margin * 2), height);
    CGRect right = CGRectZero;
    if (leftViews.count && rightViews.count && maxRightX > minRightX) {
        CGFloat rightGroupW = maxRightX - minRightX;
        right = CGRectMake(width - margin - rightGroupW - padding * 2, y, rightGroupW + padding * 2, height);
        left.size.width = CGRectGetMinX(right) - gap - margin;
        if (CGRectGetWidth(left) < 80) {
            left.size.width = MAX(0, width - margin * 2);
            right = CGRectZero;
        }
    }

    CGFloat contentMidY = (minBaseY + maxBaseY) / 2.0;
    CGFloat dy = CGRectGetMidY(left) - contentMidY;
    CGFloat dxL = (!CGRectIsEmpty(right) && minLeftX < CGFLOAT_MAX) ? (CGRectGetMinX(left) + 6 - minLeftX) : 0;
    CGFloat dxR = (!CGRectIsEmpty(right) && maxRightX > 0) ? (CGRectGetMaxX(right) - padding - maxRightX) : 0;

    CGAffineTransform leftShift = (fabs(dxL) < 0.5 && fabs(dy) < 0.5) ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(dxL, dy);
    CGAffineTransform rightShift = (fabs(dxR) < 0.5 && fabs(dy) < 0.5) ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(dxR, dy);

    CGFloat leftMaxInnerW = MAX(40, CGRectGetWidth(left) - 12);
    for (UIView *view in leftViews) {
        [XHSNativeViewState setValues:@{@"transform": [NSValue valueWithCGAffineTransform:leftShift]} on:view owner:adBar];
        constrainLabelsInView(view, adBar);
        if (CGRectGetWidth(view.bounds) > leftMaxInnerW) {
            clipContentWidth(view, leftMaxInnerW, adBar);
        } else {
            [XHSNativeViewState restoreProperties:@[@"layer.mask"] on:view owner:adBar];
        }
    }
    for (UIView *view in rightViews) {
        [XHSNativeViewState setValues:@{@"transform": [NSValue valueWithCGAffineTransform:rightShift]} on:view owner:adBar];
    }

    [XHSNativeHelper plateOn:adBar key:&kAdLeftGlassKey below:firstContent frame:left bar:kXHSNativeBarNoteBottom];
    [XHSNativeHelper plateOn:adBar key:&kAdRightGlassKey below:firstContent frame:right bar:kXHSNativeBarNoteBottom];
}

static UIView *topDirectSubviewInBar(UIView *view, UIView *bar) {
    UIView *cur = view;
    while (cur.superview && cur.superview != bar) {
        cur = cur.superview;
    }
    return cur.superview == bar ? cur : nil;
}

static BOOL isSearchBarInSearchNavigation(UIView *bar) {
    Class searchNavCls = objc_getClass("XYPHSearchNavigationViewController");
    for (UIResponder *r = bar; r; r = r.nextResponder) {
        if (searchNavCls && [r isKindOfClass:searchNavCls]) return YES;
    }
    return NO;
}

+ (void)prepareLegacySearchBar:(UIView *)bar {
    if (!bar.window) return;
    if (!isSearchBarInSearchNavigation(bar) || ![XHSNativeConfig.shared boolForKey:kXHSNativeGlassSearch]) {
        [XHSNativeViewState restoreOwner:bar];
        return;
    }
    // 在原生 layoutSubviews 前拉开返回按钮与输入容器间距（默认 6 -> 22），
    // 让宿主自行右移输入框、占位符与光标，从根源消除左侧圆形玻璃（x=8..52）与输入框胶囊（x=60..）的重叠
    if ([bar respondsToSelector:@selector(backButtonSpacing)] && [bar respondsToSelector:@selector(setBackButtonSpacing:)]) {
        [XHSNativeViewState setValues:@{@"backButtonSpacing": @22} on:bar owner:bar];
    }
}

+ (void)layoutLegacySearchBar:(UIView *)bar {
    if (!bar.window) return;
    if (!isSearchBarInSearchNavigation(bar) || ![XHSNativeConfig.shared boolForKey:kXHSNativeGlassSearch]) {
        [XHSNativeViewState restoreOwner:bar];
        return;
    }

    static char kSearchInputGlassKey, kSearchBackGlassKey, kSearchBtnGlassKey;
    [self clearLegacyBackground:bar owner:bar];
    [self clearLegacyBackground:bar.superview owner:bar];
    UIView *leftBox = [bar respondsToSelector:@selector(leftContainerView)] ? [bar performSelector:@selector(leftContainerView)] : nil;
    UIView *rightBox = [bar respondsToSelector:@selector(rightContainerView)] ? [bar performSelector:@selector(rightContainerView)] : nil;
    UIView *shadowBox = [bar respondsToSelector:@selector(textViewShadowContainer)] ? [bar performSelector:@selector(textViewShadowContainer)] : nil;
    UIView *bgBox = [bar respondsToSelector:@selector(textViewBackgroundView)] ? [bar performSelector:@selector(textViewBackgroundView)] : nil;
    if (leftBox) [self clearLegacyBackground:leftBox owner:bar];
    if (rightBox) [self clearLegacyBackground:rightBox owner:bar];
    if (shadowBox) {
        [self clearLegacyBackground:shadowBox owner:bar];
        if (shadowBox.layer.shadowOpacity > 0)
            [XHSNativeViewState setValues:@{@"layer.shadowOpacity": @0} on:shadowBox owner:bar];
        if (shadowBox.layer.borderWidth > 0)
            [XHSNativeViewState setValues:@{@"layer.borderWidth": @0} on:shadowBox owner:bar];
    }
    // textViewBackgroundView 是带实心浅/深色背景图的 UIImageView，必须隐藏才不会遮挡底层仿玻璃底板
    if (bgBox) {
        [self clearLegacyBackground:bgBox owner:bar];
        [XHSNativeViewState setValues:@{@"hidden": @YES, @"alpha": @0} on:bgBox owner:bar];
        if (bgBox.layer.borderWidth > 0)
            [XHSNativeViewState setValues:@{@"layer.borderWidth": @0} on:bgBox owner:bar];
    }
    // 隐藏原搜索框内右侧「| 搜索」之间的竖向细分隔线
    for (UIView *container in @[bar, shadowBox ?: bar]) {
        for (UIView *sub in container.subviews) {
            if ([self isGlassView:sub] || sub.subviews.count) continue;
            if (CGRectGetWidth(sub.bounds) > 0 && CGRectGetWidth(sub.bounds) <= 1.5 && CGRectGetHeight(sub.bounds) >= 10) {
                [XHSNativeViewState setValues:@{@"hidden": @YES, @"alpha": @0} on:sub owner:bar];
            }
        }
    }

    UIView *inputHost = [XHSNativeHelper isVisible:shadowBox] ? shadowBox : bgBox;
    UIView *inputAnchor = topDirectSubviewInBar(inputHost, bar);
    CGRect inputFrame = CGRectZero;
    if (inputHost && inputAnchor && CGRectGetWidth(inputHost.bounds) > 0 && CGRectGetHeight(inputHost.bounds) > 0) {
        inputFrame = [bar convertRect:inputHost.bounds fromView:inputHost];
    }

    CGRect circle = CGRectZero;
    UIButton *backBtn = [bar respondsToSelector:@selector(backButton)] ? [bar performSelector:@selector(backButton)] : nil;
    UIView *backAnchor = topDirectSubviewInBar(backBtn, bar);
    if ([XHSNativeHelper isVisible:backBtn] && backAnchor && (!inputHost || ![backBtn isDescendantOfView:inputHost])) {
        [self clearLegacyBackground:backBtn owner:bar];
        [XHSNativeViewState restoreProperties:@[@"transform"] on:backBtn owner:bar];
        UIView *arrow = ([backBtn isKindOfClass:UIButton.class] && backBtn.imageView && CGRectGetWidth(backBtn.imageView.bounds) > 0)
            ? backBtn.imageView : backBtn;
        CGPoint iconCenter = [bar convertPoint:CGPointMake(CGRectGetMidX(arrow.bounds), CGRectGetMidY(arrow.bounds)) fromView:arrow];
        CGFloat side = CGRectGetHeight(inputFrame) > 0 ? CGRectGetHeight(inputFrame) : 40;
        CGFloat centerY = CGRectGetHeight(inputFrame) > 0 ? CGRectGetMidY(inputFrame) : iconCenter.y;
        CGFloat circleX = MAX(8, round(iconCenter.x - side / 2.0));
        CGFloat arrowShift = (circleX + side / 2.0) - iconCenter.x;
        if (fabs(arrowShift) >= 0.5) {
            [XHSNativeViewState setValues:@{@"transform": [NSValue valueWithCGAffineTransform:CGAffineTransformMakeTranslation(arrowShift, 0)]} on:backBtn owner:bar];
        }
        circle = CGRectMake(circleX, round(centerY - side / 2.0), side, side);
        [self plateOn:bar key:&kSearchBackGlassKey below:backAnchor frame:circle bar:kXHSNativeBarSearch];
    } else {
        ((UIView *)objc_getAssociatedObject(bar, &kSearchBackGlassKey)).hidden = YES;
    }

    CGRect pill = CGRectZero;
    UIButton *searchBtn = [bar respondsToSelector:@selector(searchButton)] ? [bar performSelector:@selector(searchButton)] : nil;
    UIView *searchAnchor = topDirectSubviewInBar(searchBtn, bar);
    if ([XHSNativeHelper isVisible:searchBtn] && searchAnchor && (!inputHost || ![searchBtn isDescendantOfView:inputHost])) {
        [self clearLegacyBackground:searchBtn owner:bar];
        // 先读取未叠加插件位移的原始中心，把原本内嵌在输入框右侧的「搜索」按钮贴近右安全边距居中进独立胶囊
        [XHSNativeViewState restoreProperties:@[@"transform"] on:searchBtn owner:bar];
        UIView *labelRef = ([searchBtn isKindOfClass:UIButton.class] && searchBtn.titleLabel && CGRectGetWidth(searchBtn.titleLabel.bounds) > 0)
            ? searchBtn.titleLabel : searchBtn;
        CGRect lf = [bar convertRect:labelRef.bounds fromView:labelRef];
        CGFloat h = CGRectGetHeight(inputFrame) > 0 ? CGRectGetHeight(inputFrame) : MAX(36, CGRectGetHeight(lf) + 12);
        CGFloat y = CGRectGetHeight(inputFrame) > 0 ? CGRectGetMinY(inputFrame) : round(CGRectGetMidY(lf) - h / 2.0);
        CGFloat pillW = MAX(h, ceil(CGRectGetWidth(lf)) + 24);
        CGFloat barW = CGRectGetWidth(bar.bounds);
        CGFloat desiredPillX = barW > 0 ? MIN(barW - 8 - pillW, MAX(round(CGRectGetMidX(lf) - pillW / 2.0), barW - 10 - pillW)) : round(CGRectGetMidX(lf) - pillW / 2.0);
        pill = CGRectMake(desiredPillX, y, pillW, h);
        CGFloat btnShift = CGRectGetMidX(pill) - CGRectGetMidX(lf);
        if (fabs(btnShift) >= 0.5) {
            [XHSNativeViewState setValues:@{@"transform": [NSValue valueWithCGAffineTransform:CGAffineTransformMakeTranslation(btnShift, 0)]} on:searchBtn owner:bar];
        }
        [self plateOn:bar key:&kSearchBtnGlassKey below:searchAnchor frame:pill bar:kXHSNativeBarSearch];
    } else {
        ((UIView *)objc_getAssociatedObject(bar, &kSearchBtnGlassKey)).hidden = YES;
    }

    if (!CGRectIsEmpty(inputFrame) && inputAnchor) {
        if (!CGRectIsEmpty(circle) && CGRectGetMinX(inputFrame) < CGRectGetMaxX(circle) + 8) {
            CGFloat minX = CGRectGetMaxX(circle) + 8;
            CGFloat delta = minX - CGRectGetMinX(inputFrame);
            inputFrame.origin.x = minX;
            inputFrame.size.width = MAX(80, CGRectGetWidth(inputFrame) - delta);
        }
        if (!CGRectIsEmpty(pill) && CGRectGetMaxX(inputFrame) > CGRectGetMinX(pill) - 8) {
            inputFrame.size.width = MAX(80, CGRectGetMinX(pill) - 8 - CGRectGetMinX(inputFrame));
        }
        if ([XHSNativeHelper isVisible:rightBox]) {
            [XHSNativeViewState restoreProperties:@[@"transform"] on:rightBox owner:bar];
            CGRect rightFrame = [bar convertRect:rightBox.bounds fromView:rightBox];
            CGFloat maxRightInside = CGRectGetMaxX(inputFrame) - 4;
            if (CGRectGetMaxX(rightFrame) > maxRightInside) {
                CGFloat shiftLeft = maxRightInside - CGRectGetMaxX(rightFrame);
                [XHSNativeViewState setValues:@{@"transform": [NSValue valueWithCGAffineTransform:CGAffineTransformMakeTranslation(shiftLeft, 0)]} on:rightBox owner:bar];
            }
        }
        [self plateOn:bar key:&kSearchInputGlassKey below:inputAnchor frame:inputFrame bar:kXHSNativeBarSearch];
    } else {
        ((UIView *)objc_getAssociatedObject(bar, &kSearchInputGlassKey)).hidden = YES;
    }
}

@end
