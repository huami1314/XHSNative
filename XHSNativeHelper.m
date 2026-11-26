//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/24
//
#import "XHSNativeHelper.h"
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "XHSNativeConfig.h"
#import "XHSNativeLegacy.h"

#pragma mark - 滚动联动

// 小红书的页面是多层嵌套的分页容器，系统找不到真正在滚的那个列表。
// 手指开始拖的时候把它登记成当前页面的内容滚动视图，系统的「滚动收起底栏」才会生效。

@interface XHSNativeScrollTracker : NSObject
@end

@implementation XHSNativeScrollTracker

+ (instancetype)shared {
    static XHSNativeScrollTracker *tracker;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tracker = [XHSNativeScrollTracker new]; });
    return tracker;
}

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIScrollView *list = (UIScrollView *)pan.view;
    if (![list isKindOfClass:UIScrollView.class]) return;
    // 只认竖向列表，横向分页容器不算
    if (list.contentSize.height <= CGRectGetHeight(list.bounds) && !list.alwaysBounceVertical) return;
    if (list.contentSize.width > CGRectGetWidth(list.bounds) + 1 && list.pagingEnabled) return;

    UINavigationController *navigation = (UINavigationController *)XHSNativeConfig.shared.tabBarController.selectedViewController;
    UIViewController *page = [navigation isKindOfClass:UINavigationController.class] ? navigation.topViewController : navigation;
    if (!page.isViewLoaded || ![list isDescendantOfView:page.view]) return;
    // 低系统的底栏收起是插件自己做的，要跟着整个拖动过程
    if (![XHSNativeHelper supportsGlass]) return [XHSNativeLegacy handleScrollPan:pan inPage:page];
    if (pan.state != UIGestureRecognizerStateBegan) return;
    [XHSNativeHelper attachHomeBar:list];
    if ([page contentScrollViewForEdge:NSDirectionalRectEdgeBottom] != list) [page setContentScrollView:list forEdge:NSDirectionalRectEdgeBottom];
}

@end

#pragma mark - 图文笔记页

// 系统的 soft 边缘只画在滚动视图自己的范围里，笔记列表从顶栏下沿才开始，画不到顶栏下面。
// 在顶栏的位置放一个空的滚动视图替它画：列表停在顶上时，它的内容在栏的下方，系统不显示边缘；
// 列表一往下滑，就把它的内容挪到栏下面，系统显示边缘
@interface XHSNativeSoftEdge : UIScrollView
- (void)follow:(UIScrollView *)list;
@end

@implementation XHSNativeSoftEdge

- (void)follow:(UIScrollView *)list {
    BOOL scrolled = list.contentOffset.y > 0.5 - list.adjustedContentInset.top;
    CGFloat offset = scrolled ? 0 : -self.contentInset.top;
    if (self.contentOffset.y != offset) self.contentOffset = CGPointMake(0, offset);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(UIScrollView *)list change:(NSDictionary *)change context:(void *)context {
    [self follow:list];
}

@end

#pragma mark - 双击放大

// 交给笔记图片轮播的一次「单击」。它处理点按时只看手势的 state 和 recognizedTap（1 单击，2 双击）
@interface XHSNativeSingleTap : NSObject
@end

@implementation XHSNativeSingleTap

- (UIGestureRecognizerState)state {
    return UIGestureRecognizerStateEnded;
}

- (NSUInteger)recognizedTap {
    return 1;
}

@end

#pragma mark - 小红书主程序

// 小红书主程序的镜像。不按 MH_EXECUTE 找：用 LiveContainer 这类容器加载时，进程的主程序是容器自己，
// 小红书是被当成动态库加载进来的。按它里面的类落在哪个镜像来找，两种情况都对
struct XHSAppImage {
    const struct mach_header_64 *header;
    intptr_t slide;
    uintptr_t textSize;
};

static const struct XHSAppImage *appImage(void) {
    static struct XHSAppImage app;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (!dladdr((__bridge void *)objc_getClass("XYTabbarController"), &info) || !info.dli_fbase) return;
        const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
        if (header->magic != MH_MAGIC_64) return;
        const struct load_command *command = (const struct load_command *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (command->cmd != LC_SEGMENT_64 || strcmp(segment->segname, SEG_TEXT)) continue;
            app.header = header;
            app.slide = (intptr_t)header - (intptr_t)segment->vmaddr;
            app.textSize = segment->vmsize;
            break;
        }
    });
    return &app;
}

#pragma mark - iOS 27.1 以下

// 首页的下沉布局是按 iOS 27.1 写的，用到三个更早的系统上没有的东西：
// 特征 verticalBarEdge，Swift 的 UITraitCollection.systemTraitsAffectingVerticalBarEdge
// 和 UIView.LayoutRegion.bar(onEdge:extent:)。
// 第一个补一个返回「未指定」的方法。后两个在导入表里是空的，一调就崩：
// 一个填上返回空数组的函数（没有竖排栏，也就没有要监听的特征），
// 一个填上转给 safeArea 的跳板（没有竖排栏时这个区域的上边界就是安全区，结果一样）。

static NSInteger verticalBarEdgeUnspecified(id self, SEL _cmd) {
    return 0;
}

// 跳板的目标和参数。参数是 AdaptivityAxis?，这个枚举跨模块按地址传，nil 是字节 2
__attribute__((used, visibility("hidden"))) void *gSafeAreaRegion;
__attribute__((used, visibility("hidden"))) uint64_t gNoAxis = 2;

__attribute__((naked)) static void layoutRegionBar(void) {
    __asm__ volatile("adrp x16, _gSafeAreaRegion@PAGE\n"
                     "ldr x16, [x16, _gSafeAreaRegion@PAGEOFF]\n"
                     "adrp x0, _gNoAxis@PAGE\n"
                     "add x0, x0, _gNoAxis@PAGEOFF\n"
                     "br x16\n");
}

// 在主程序的导入表里按符号名找到对应的指针槽：间接符号表 → 符号表 → 名字
static void **importSlot(const char *symbol) {
    const struct mach_header_64 *header = appImage()->header;
    intptr_t slide = appImage()->slide;
    if (!header) return NULL;

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)command;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)command;
        else if (command->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT)) linkedit = (const struct segment_command_64 *)command;
    }
    if (!symtab || !dysymtab || !linkedit) return NULL;
    uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t j = 0; j < segment->nsects; j++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)(section->addr + slide);
            for (size_t k = 0; k < section->size / sizeof(void *); k++) {
                uint32_t index = indirect[section->reserved1 + k];
                if ((index & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) || index >= symtab->nsyms) continue;
                if (!strcmp(strings + symbols[index].n_un.n_strx, symbol)) return &slots[k];
            }
        }
    }
    return NULL;
}

static void *noTraits(void) {
    static void *empty;
    if (!empty) empty = dlsym(RTLD_DEFAULT, "_swiftEmptyArrayStorage");
    return empty;
}

static void fillImport(const char *symbol, void *replacement) {
    void **slot = importSlot(symbol);
    if (!slot || *slot) return;  // 槽里有东西说明系统自带，不用补
    vm_address_t page = (vm_address_t)slot & ~(vm_page_size - 1);
    if (vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
    *slot = replacement;
    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
}

#pragma mark - 设置界面

// 小红书的设置组件，属性都是返回 block 的链式写法，下面几个小函数把调用包一下

static id blockOf(id target, NSString *name) {
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}

static id rowTitle(NSString *text) {
    id (^make)(NSString *) = blockOf(objc_getClass("StandardOptionTitle"), @"title");
    return make(text);
}

static id with(id object, NSString *name, id value) {
    id (^apply)(id) = blockOf(object, name);
    return apply(value);
}

static id withFlag(id object, NSString *name, BOOL value) {
    id (^apply)(BOOL) = blockOf(object, name);
    return apply(value);
}

static id row(NSString *kind, id title, NSString *identity) {
    id (^make)(id) = blockOf(objc_getClass("StandardOption"), kind);
    return with(make(title), @"setIdentity", identity);
}

static id gap(CGFloat height) {
    id (^make)(double) = blockOf(objc_getClass("StandardOption"), @"blank");
    return make(height);
}

static id switchRow(NSString *title, BOOL on, NSString *identity) {
    return row(@"switcher", withFlag(rowTitle(title), @"setSwitcherIsOn", on), identity);
}

static NSDictionary<NSString *, NSString *> *tabTitles(void) {
    return @{@"index": @"首页", @"shopping": @"市集", @"message": @"消息", @"me": @"我"};
}

// 首页频道按小红书的 childVCPageName：0 关注 1 发现 2 同城
static NSArray<NSString *> *channelTitles(void) {
    return @[@"关注", @"发现", @"同城"];
}

static NSArray<NSArray *> *glassBars(void) {
    NSMutableArray *bars = [@[@[@"首页顶栏", kXHSNativeBarHome], @[@"笔记顶栏", kXHSNativeBarNoteTop], @[@"笔记底栏", kXHSNativeBarNoteBottom],
                              @[@"视频顶栏", kXHSNativeBarVideoTop], @[@"视频底栏", kXHSNativeBarVideoBottom],
                              @[@"评论输入栏", kXHSNativeBarComment], @[@"个人页顶栏", kXHSNativeBarProfile]] mutableCopy];
    // 低系统的底栏和搜索栏也是插件画的玻璃
    if (![XHSNativeHelper supportsGlass]) {
        [bars insertObject:@[@"底部标签栏", kXHSNativeBarTab] atIndex:1];
        [bars insertObject:@[@"搜索页", kXHSNativeBarSearch] atIndex:2];
    }
    return bars;
}

@implementation XHSNativeHelper

#pragma mark - 视图

+ (UIView *)plateOn:(UIView *)owner key:(const void *)key below:(UIView *)below frame:(CGRect)frame bar:(NSString *)bar {
    if (![self supportsGlass]) return [XHSNativeLegacy plateOn:owner key:key below:below frame:frame bar:bar];
    UIVisualEffectView *glass = objc_getAssociatedObject(owner, key);
    if (!glass) {
        glass = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
        glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
        glass.userInteractionEnabled = NO;
        glass.contentView.layer.masksToBounds = YES;
        objc_setAssociatedObject(owner, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL empty = CGRectIsEmpty(frame) || !below.superview;
    if (glass.hidden != empty) glass.hidden = empty;
    if (empty) return glass;

    NSArray<UIView *> *siblings = below.superview.subviews;
    NSUInteger index = [siblings indexOfObjectIdenticalTo:below];
    if (glass.superview != below.superview || index == 0 || siblings[index - 1] != glass) [below.superview insertSubview:glass belowSubview:below];
    if (!CGRectEqualToRect(glass.frame, frame)) glass.frame = frame;

    // 不透明度：在玻璃上垫一层半透明的底色
    UIView *content = glass.contentView;
    NSInteger fill = (NSInteger)[XHSNativeConfig.shared fillForBar:bar];
    if (content.tag != fill + 1) {
        content.tag = fill + 1;
        content.backgroundColor = fill ? [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:fill / 100.0]
                                                                         : [UIColor colorWithWhite:1 alpha:fill / 100.0];
        }] : nil;
    }
    content.layer.cornerRadius = CGRectGetHeight(frame) / 2;
    return glass;
}

+ (void)clearBackground:(UIView *)view {
    // 低系统记下原来的底色，关掉对应的玻璃时换回去
    if (![self supportsGlass]) return [XHSNativeLegacy clearLegacyBackground:view owner:view];
    if (view.backgroundColor && ![view.backgroundColor isEqual:UIColor.clearColor]) view.backgroundColor = UIColor.clearColor;
}

+ (BOOL)isVisible:(UIView *)view {
    return view && !view.hidden && view.alpha > 0.01 && CGRectGetWidth(view.bounds) > 0 && CGRectGetHeight(view.bounds) > 0;
}

+ (UIView *)subviewOf:(UIView *)view named:(NSString *)className {
    for (UIView *subview in view.subviews)
        if ([NSStringFromClass(subview.class) isEqualToString:className]) return subview;
    return nil;
}

+ (UIViewController *)viewControllerOf:(UIView *)view {
    UIResponder *responder = view;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
    return (UIViewController *)responder;
}

#pragma mark - 小红书

// 这几个方法调用得很频繁，直接和主程序代码段的地址范围比
+ (BOOL)isAppAddress:(void *)address {
    uintptr_t start = (uintptr_t)appImage()->header;
    return start && (uintptr_t)address >= start && (uintptr_t)address < start + appImage()->textSize;
}

+ (id)themeGlyph:(NSString *)name {
    Class managerClass = objc_getClass("XYThemeManager");
    if (![managerClass respondsToSelector:NSSelectorFromString(@"defaultManager")]) return nil;
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, NSSelectorFromString(@"defaultManager"));
    if (![manager respondsToSelector:NSSelectorFromString(@"icon")]) return nil;
    id set = ((id (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"icon"));
    return [set respondsToSelector:NSSelectorFromString(name)] ? ((id (*)(id, SEL))objc_msgSend)(set, NSSelectorFromString(name)) : nil;
}

// 取成图片的写法是 .size(28).image
+ (UIImage *)themeIcon:(NSString *)name {
    id glyph = [self themeGlyph:name];
    if (![glyph respondsToSelector:NSSelectorFromString(@"size")]) return nil;
    id (^sized)(CGFloat) = ((id (*)(id, SEL))objc_msgSend)(glyph, NSSelectorFromString(@"size"));
    id result = sized ? sized([self supportsGlass] ? 28 : XHSNativeConfig.shared.tabIconSize) : nil;
    if (![result respondsToSelector:NSSelectorFromString(@"image")]) return nil;
    UIImage *image = ((id (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"image"));
    return [image isKindOfClass:UIImage.class] ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

+ (UIImage *)tabIcon:(NSString *)name selected:(BOOL)selected {
    NSDictionary *theme = @{@"index": @"home", @"shopping": @"store", @"message": @"chat", @"me": @"me"};
    NSDictionary *symbols = @{@"index": @"house", @"shopping": @"bag", @"message": @"message", @"me": @"person"};
    UIImage *image = [self themeIcon:[theme[name] stringByAppendingString:selected ? @"_f" : @"_b"]];
    NSString *symbol = selected ? [symbols[name] stringByAppendingString:@".fill"] : symbols[name];
    if (image || [self supportsGlass]) return image ?: [UIImage systemImageNamed:symbol];
    UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:round(XHSNativeConfig.shared.tabIconSize * 0.72) weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:symbol withConfiguration:size];
}

#pragma mark - 底栏

// 当前显示着的、对应某个页面的标签
+ (UITab *)tabNamed:(NSString *)name {
    if (![self supportsGlass]) return nil;
    for (UITab *tab in XHSNativeConfig.shared.tabBarController.tabs)
        if ([tab.identifier isEqualToString:name]) return tab;
    return nil;
}

// 底栏是不是已经换成插件排的那一套
+ (BOOL)hasRebuiltTabs {
    if (![self supportsGlass]) return XHSNativeConfig.shared.pages.count > 0;
    return [self tabNamed:@"index"] != nil;
}

+ (NSArray<NSString *> *)legacyTabNames:(XYTabbarController *)controller {
    return [[controller.customtabBar valueForKey:@"tabs"] valueForKey:@"itemName"];
}

+ (void)refreshBadge:(UITabBarItem *)item {
    if ([item respondsToSelector:@selector(_updateViewBadge)]) [item _updateViewBadge];
}

+ (BOOL)isItemEnabled:(UITabBarItem *)item {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if (config.searchPage && item == config.searchPage.tabBarItem) return YES;
    for (NSUInteger i = 0; i < config.pages.count; i++) {
        if (item != config.pages[i].tabBarItem) continue;
        return [self supportsGlass] ? [self tabNamed:config.pageNames[i]].enabled : ![config isTabHidden:config.pageNames[i]];
    }
    return NO;
}

+ (BOOL)isOurTabBar:(UITabBar *)bar {
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    return controller && bar == controller.tabBar;
}

+ (void)rebuildTabs {
    if (![self supportsGlass]) return [XHSNativeLegacy rebuildLegacyTabs];
    XHSNativeConfig *config = XHSNativeConfig.shared;
    XYTabbarController *controller = config.tabBarController;
    if (!controller || !config.pages.count) return;
    // 底栏被二级页面盖住时（比如正在设置页里改）先记一笔，等它重新露出来再换
    config.tabsDirty = controller.isTabBarHidden;
    if (config.tabsDirty) return;

    // 每次都建新的标签对象：沿用旧对象重排的话，系统会把留下来的那几个画成灰的
    NSString *selected = controller.selectedTab.identifier;
    NSMutableArray<UITab *> *tabs = [NSMutableArray array];
    NSArray *legacyNames = [self legacyTabNames:controller];
    for (NSString *name in config.tabOrder) {
        NSUInteger index = [config.pageNames indexOfObject:name];
        if (index == NSNotFound || [config isTabHidden:name]) continue;
        UIViewController *page = config.pages[index];
        NSString *title = config.isTabTitleShown ? tabTitles()[name] : @"";
        UITab *tab = [[UITab alloc] initWithTitle:title image:[self tabIcon:name selected:NO] identifier:name viewControllerProvider:^UIViewController *(UITab *t) { return page; }];
        if ([tab respondsToSelector:@selector(setSelectedImage:)]) [(id)tab setSelectedImage:[self tabIcon:name selected:YES]];
        NSUInteger badgeIndex = [legacyNames indexOfObject:name];
        tab.badgeValue = (legacyNames && badgeIndex != NSNotFound) ? controller.badgeValueDict[@(badgeIndex)] : [self tabNamed:name].badgeValue;
        [tabs addObject:tab];
    }
    BOOL swapped = config.isPublishSwapped;
    if ([config boolForKey:kXHSNativeSearchTab] || swapped) {
        // 系统的搜索标签会自己单独排在右边。它不切页面，点了直接开小红书的搜索，见 shouldSelectTab。
        // 交换搜索与发布时，这一格换成发布
        if (!config.searchPage) config.searchPage = [UIViewController new];
        UIViewController *page = config.searchPage;
        UISearchTab *search = [[UISearchTab alloc] initWithViewControllerProvider:^UIViewController *(UITab *t) { return page; }];
        search.automaticallyActivatesSearch = YES;
        if (swapped) {
            search.title = @"发布";
            search.image = [UIImage systemImageNamed:@"plus"];
        }
        [tabs addObject:search];
    }
    config.rebuilding = YES;
    [controller setTabs:tabs animated:NO];
    for (UITabBarItem *item in controller.tabBar.items) {
        if (!item.enabled && [self isItemEnabled:item]) item.enabled = YES;
        if (item.badgeValue) [self refreshBadge:item];
    }
    // 旧栏保留给发布和角标使用。其他插件可能在布局时重新显示它。
    if ([self tabNamed:@"index"]) controller.customtabBar.alpha = 0;
    UITab *restored = selected ? [self tabNamed:selected] : nil;
    if (restored) controller.selectedTab = restored;
    controller.tabBarMinimizeBehavior = [config boolForKey:kXHSNativeMinimize] ? UITabBarMinimizeBehaviorOnScrollDown : UITabBarMinimizeBehaviorNever;
    config.rebuilding = NO;
}

// 等同于点原来的加号
+ (void)openPublish {
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    UIControl *button = [controller respondsToSelector:@selector(centerButton)] ? [controller centerButton] : nil;
    if ([button isKindOfClass:UIControl.class]) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

// 等同于点首页顶栏原来的搜索。搜索页是从首页进的，不在首页时先切回去
+ (void)openSearch {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if ([self supportsGlass]) {
        UITab *home = [self tabNamed:@"index"];
        if (home && config.tabBarController.selectedTab != home) config.tabBarController.selectedTab = home;
    } else {
        UIViewController *home = [XHSNativeLegacy legacyPageForName:@"index"];
        if (home && config.tabBarController.selectedViewController != home) config.tabBarController.selectedViewController = home;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [config.searchButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    });
}

// 打开插件设置页（低系统长按底栏首页）
+ (void)openSettings {
    UINavigationController *navigation = (UINavigationController *)XHSNativeConfig.shared.tabBarController.selectedViewController;
    if (![navigation isKindOfClass:UINavigationController.class] || [navigation.topViewController isKindOfClass:objc_getClass("XHSNativeSettingsPage")]) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [navigation pushViewController:[[objc_getClass("XHSNativeSettingsPage") alloc] init] animated:YES];
}

// 重复点当前标签。小红书的每个标签页都实现了 XYTabbarClicked（首页是回到顶部并刷新），
// 原来由它的自绘底栏调用，换成系统底栏后要自己转过去
+ (void)reselectPage:(UIViewController *)tabPage {
    UINavigationController *navigation = (UINavigationController *)tabPage;
    UIViewController *page = [navigation isKindOfClass:UINavigationController.class] ? navigation.viewControllers.firstObject : navigation;
    SEL clicked = NSSelectorFromString(@"XYTabbarClicked");
    if ([page respondsToSelector:clicked]) ((void (*)(id, SEL))objc_msgSend)(page, clicked);
}

#pragma mark - 首页顶栏

static char kBarEdgeKey, kSoftEdgeKey, kPublishKey, kSegmentGlassKey, kChannelTitlesKey, kRenamedTitlesKey, kLineHiddenKey;

+ (NSHashTable *)pinnedEdgeEffects {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

+ (BOOL)isPinnedEdgeEffect:(UIScrollEdgeEffect *)effect {
    return [[self pinnedEdgeEffects] containsObject:effect];
}

+ (BOOL)hasSoftTopEdge:(UIScrollView *)list {
    return objc_getAssociatedObject(list, &kSoftEdgeKey) != nil;
}

+ (void)useSoftTopEdge:(UIScrollView *)list {
    if ([self hasSoftTopEdge:list]) return;
    objc_setAssociatedObject(list, &kSoftEdgeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[self pinnedEdgeEffects] addObject:list.topEdgeEffect];
    list.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
    list.topEdgeEffect.hidden = NO;
}

// 这个列表是不是当前屏幕上、压在顶栏下面的那个竖向列表
+ (BOOL)isList:(UIScrollView *)list underBar:(UIView *)bar {
    if (list.hidden || !list.window || list.window != bar.window) return NO;
    if (list.contentSize.width > CGRectGetWidth(list.bounds) + 1 && list.pagingEnabled) return NO;
    if (list.contentSize.height <= CGRectGetHeight(list.bounds) && !list.alwaysBounceVertical) return NO;
    CGRect frame = [list convertRect:list.bounds toView:nil], barFrame = [bar convertRect:bar.bounds toView:nil];
    if (CGRectGetWidth(CGRectIntersection(frame, list.window.bounds)) < CGRectGetWidth(list.window.bounds) / 2) return NO;  // 在左右相邻的页里
    return CGRectGetMinY(frame) < CGRectGetMaxY(barFrame) - 1 && CGRectGetHeight(frame) > CGRectGetHeight(barFrame) * 2;
}

// 告诉系统顶栏压在这个列表上，边缘效果才会按顶栏的高度铺开。同一时刻只跟当前在看的那个列表
+ (void)attachHomeBar:(UIScrollView *)list {
    UIView *bar = XHSNativeConfig.shared.homeBar;
    if (!bar || ![self isList:list underBar:bar]) return;
    // 低系统没有系统的边缘效果，用插件画的渐隐跟着这个列表
    if (![self supportsGlass]) return [XHSNativeLegacy attachScrollView:list toBar:bar];
    [self useSoftTopEdge:list];
    UIScrollEdgeElementContainerInteraction *interaction = objc_getAssociatedObject(bar, &kBarEdgeKey);
    if (!interaction) {
        interaction = [UIScrollEdgeElementContainerInteraction new];
        interaction.edge = UIRectEdgeTop;
        [bar addInteraction:interaction];
        objc_setAssociatedObject(bar, &kBarEdgeKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (interaction.scrollView != list) interaction.scrollView = list;
}

+ (void)findListIn:(UIView *)root underBar:(UIView *)bar best:(UIScrollView **)best {
    if ([root isKindOfClass:UIScrollView.class] && [self isList:(UIScrollView *)root underBar:bar] &&
        (!*best || CGRectGetHeight(root.bounds) > CGRectGetHeight((*best).bounds)))
        *best = (UIScrollView *)root;
    for (UIView *view in root.subviews) [self findListIn:view underBar:bar best:best];
}

// 左右切到别的页（关注 / 发现 / 同城）之后，把边缘效果接到新出现的那个列表上
+ (void)attachVisibleList {
    UIView *bar = XHSNativeConfig.shared.homeBar;
    if (!bar.window) return;
    UIScrollView *list = nil;
    [self findListIn:bar.superview underBar:bar best:&list];
    if (list) [self attachHomeBar:list];
}

// 主题图、分隔线和通栏磨砂各是一层，主题图的高度会按图片比例变化。
+ (void)stripBarBackground:(XYMHomeNaviBar *)bar {
    [self clearBackground:bar];
    UIView *theme = [bar respondsToSelector:@selector(background)] ? bar.background : nil;
    Class separator = objc_getClass("_XYSeparatorView");
    for (UIView *view in bar.subviews) {
        if (view.alpha == 0) continue;
        BOOL fullWidth = CGRectGetWidth(bar.bounds) > 0 &&
                         fabs(CGRectGetMinX(view.frame) - CGRectGetMinX(bar.bounds)) < 1 &&
                         fabs(CGRectGetWidth(view.frame) - CGRectGetWidth(bar.bounds)) < 1;
        BOOL backdrop = fullWidth && view.subviews.count <= 2 &&
            ([view isMemberOfClass:UIVisualEffectView.class] ||
             ([view isMemberOfClass:UIView.class] && (!view.userInteractionEnabled || CGRectEqualToRect(view.frame, bar.bounds))));
        if (view == theme || backdrop || (fullWidth && [view isKindOfClass:separator])) view.alpha = 0;
    }
}

// 发布是不是在底栏：用户对调了，或者是折叠屏。折叠屏上小红书自己接管系统底栏，带发布、不带搜索
+ (BOOL)isPublishInTabBar {
    XYTabbarController *controller = XHSNativeConfig.shared.tabBarController;
    return XHSNativeConfig.shared.isPublishSwapped || ([controller respondsToSelector:@selector(useLiquidGlass)] && [controller useLiquidGlass]);
}

+ (void)layoutHomeBar:(XYMHomeNaviBar *)bar {
    XHSNativeConfig.shared.homeBar = bar;
    [self stripBarBackground:bar];
    if (![self supportsGlass]) [XHSNativeLegacy layoutHomeBar:bar];

    UIButton *publish = objc_getAssociatedObject(bar, &kPublishKey);
    UIView *menu = nil, *segment = nil, *search = nil;
    for (UIView *view in bar.subviews) {
        NSString *name = NSStringFromClass(view.class);
        if ([name isEqualToString:@"XYMenuButton"]) menu = view;
        else if ([name isEqualToString:@"XYSegmentControl"]) segment = view;
        else if (view != publish && [view isKindOfClass:UIButton.class] && (!search || CGRectGetMinX(view.frame) > CGRectGetMinX(search.frame))) search = view;
    }
    if (!menu || !search) return;
    XHSNativeConfig.shared.searchButton = (UIControl *)search;

    if ([self isPublishInTabBar]) {
        // 发布在底栏，原来的搜索留在顶栏。之前收起过的话放出来
        if (publish) {
            [publish removeFromSuperview];
            objc_setAssociatedObject(bar, &kPublishKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (UIView *view in bar.subviews) {
                BOOL backing = [view isKindOfClass:UIVisualEffectView.class] && CGRectEqualToRect(view.frame, search.frame);
                if (view == search || backing) view.hidden = NO;
            }
        }
    } else {
        if (!publish) {
            // 低系统没有玻璃按钮，用普通按钮，玻璃垫在后面
            UIButtonConfiguration *config = [self supportsGlass] ? [UIButtonConfiguration glassButtonConfiguration] : [UIButtonConfiguration plainButtonConfiguration];
            config.image = [UIImage systemImageNamed:@"plus"];
            config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
            config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
            config.baseForegroundColor = UIColor.labelColor;
            publish = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *action) { [XHSNativeHelper openPublish]; }]];
            publish.accessibilityLabel = @"发布";
            objc_setAssociatedObject(bar, &kPublishKey, publish, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (publish.superview != bar) [bar addSubview:publish];
        if (!CGRectEqualToRect(publish.frame, search.frame)) publish.frame = search.frame;
        // 原搜索按钮和它背后那块玻璃都收起来（玻璃是和按钮同一位置的另一个视图）
        for (UIView *view in bar.subviews) {
            BOOL backing = [view isKindOfClass:UIVisualEffectView.class] && CGRectEqualToRect(view.frame, search.frame);
            if ((view == search || backing) && !view.hidden) view.hidden = YES;
        }
    }

    if (![self supportsGlass]) [XHSNativeLegacy plateHomeBar:bar menu:menu button:objc_getAssociatedObject(bar, &kPublishKey) ?: search];

    if (!segment) return;
    [self customizeChannels:segment];
    // 「关注 发现 同城」垫一块玻璃，文字压在图片上才看得清；高度和两侧按钮对齐，在两个按钮之间居中
    CGFloat left = CGRectGetMaxX(menu.frame) + 8, right = CGRectGetMinX(search.frame) - 8;
    CGFloat width = MIN(right - left, CGRectGetWidth(segment.frame) + 16);
    CGFloat x = left + (right - left - width) / 2;
    CGRect frame = segment.frame;
    frame.origin.x = x + (width - CGRectGetWidth(frame)) / 2;
    if (!CGRectEqualToRect(segment.frame, frame)) segment.frame = frame;
    // 低系统的左右按钮没有玻璃底，按 44 高的圆对齐
    CGFloat height = [self supportsGlass] ? CGRectGetHeight(menu.frame) : 44;
    CGRect plate = segment.hidden ? CGRectZero : CGRectMake(x, CGRectGetMidY(menu.frame) - height / 2, width, height);
    [self plateOn:bar key:&kSegmentGlassKey below:segment frame:plate bar:kXHSNativeBarHome];
    if (![self supportsGlass]) [self attachVisibleList];
}

// 首页顶栏的频道：自定义名称用控件自己的 setTitles:，红线用 setSelectionIndicatorHidden:。
// 标题和 childViewModels 一一对应，按频道编号改，不看文字。改之前的标题记下来，关掉开关时换回去；
// 小红书自己换了标题（比如定位到了新城市）就以它的为准
+ (void)customizeChannels:(UIView *)segment {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    BOOL hideLine = config.isChannelLineHidden;
    if (hideLine || objc_getAssociatedObject(segment, &kLineHiddenKey)) {
        if ([[segment valueForKey:@"selectionIndicatorHidden"] boolValue] != hideLine) [(id)segment setSelectionIndicatorHidden:hideLine];
        objc_setAssociatedObject(segment, &kLineHiddenKey, hideLine ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSArray *titles = [segment valueForKey:@"titles"];
    NSArray *renamed = objc_getAssociatedObject(segment, &kRenamedTitlesKey);
    NSArray *original = [titles isEqualToArray:renamed] ? objc_getAssociatedObject(segment, &kChannelTitlesKey) : titles;
    UIResponder *home = segment;
    while (home && ![home isKindOfClass:objc_getClass("XYMHomeViewController")]) home = home.nextResponder;
    NSArray *children = [[(XYMHomeViewController *)home dataSource] childViewModels];
    if (!original || children.count != original.count) return;

    NSMutableArray *wanted = [original mutableCopy];
    for (NSUInteger i = 0; i < children.count; i++) {
        if (![children[i] respondsToSelector:@selector(childVCPageName)]) continue;
        NSString *name = [config nameForChannel:[children[i] childVCPageName]];
        if (name) wanted[i] = name;
    }
    objc_setAssociatedObject(segment, &kChannelTitlesKey, original, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(segment, &kRenamedTitlesKey, wanted, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (![titles isEqualToArray:wanted]) [(id)segment setTitles:wanted];
}

// 首页的频道页（关注 发现 同城）都由 childViewModels 提供，标题、分页、按频道找下标都从这里取，
// 在这一处过滤就能整个藏掉，排序也在这里。全藏了就不过滤
+ (NSArray *)visibleChannels:(NSArray *)children {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSMutableArray *visible = [NSMutableArray array];
    for (id child in children)
        if (![child respondsToSelector:@selector(childVCPageName)] || ![config isChannelHidden:[child childVCPageName]]) [visible addObject:child];
    if (!visible.count) visible = [children mutableCopy];
    NSArray<NSNumber *> *order = config.channelOrder;
    [visible sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(id a, id b) {
        NSUInteger first = [a respondsToSelector:@selector(childVCPageName)] ? [order indexOfObject:@([a childVCPageName])] : NSNotFound;
        NSUInteger second = [b respondsToSelector:@selector(childVCPageName)] ? [order indexOfObject:@([b childVCPageName])] : NSNotFound;
        return first < second ? NSOrderedAscending : (first > second ? NSOrderedDescending : NSOrderedSame);
    }];
    return visible;
}

// 默认打开的频道被藏了，就打开剩下的第一个
+ (NSUInteger)landingChannel:(NSUInteger)page ofHome:(XYMHomeViewController *)home {
    if (![XHSNativeConfig.shared isChannelHidden:page]) return page;
    id first = [[home dataSource] childViewModels].firstObject;
    return [first respondsToSelector:@selector(childVCPageName)] ? [first childVCPageName] : page;
}

// 首页左上角的入口由服务器按账号下发：SETTING 侧边栏菜单，DOT 点点，RED_BOX 红包。
// 禁用点点时把 DOT 当成 SETTING，图标和点击都回到侧边栏菜单
+ (NSString *)leftEntranceType:(NSString *)type {
    if (!XHSNativeConfig.shared.isDotsDisabled || ![type isEqualToString:@"DOT"]) return type;
    return @"SETTING";
}

// 入口按侧边栏菜单处理时，服务器配的图标还是点点的那张，不让顶栏再去套它
+ (BOOL)keepsMenuIcon {
    if (!XHSNativeConfig.shared.isDotsDisabled) return NO;
    return [[[objc_getClass("XYHomeModule.MainFrameEntranceConfigManager") shared] leftSideBarType] isEqualToString:@"SETTING"];
}

#pragma mark - 滚动联动

+ (void)trackScrollView:(UIScrollView *)list {
    static char key;
    if (!list.window || objc_getAssociatedObject(list, &key)) return;
    objc_setAssociatedObject(list, &key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [list.panGestureRecognizer addTarget:[XHSNativeScrollTracker shared] action:@selector(pan:)];
}

#pragma mark - 市集 / 消息 / 我

// 换成悬浮的系统底栏后，这几页底下会空出一条。原因有两种：
// 页面按旧底栏的高度（44 + 底部安全区）把内容区截短了（市集），或者页面不肯延伸到栏下面（消息）。

static BOOL nearlyEqual(CGFloat a, CGFloat b) {
    return fabs(a - b) < 1.5;
}

// 把一个「底边正好停在旧底栏上沿」的视图往下加长 gap
static BOOL growView(UIView *view, CGFloat gap) {
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstItem == view && !constraint.secondItem && constraint.firstAttribute == NSLayoutAttributeHeight &&
            constraint.relation == NSLayoutRelationEqual && constraint.isActive && nearlyEqual(constraint.constant, CGRectGetHeight(view.bounds))) {
            constraint.constant += gap;
            return YES;
        }
    }
    for (NSLayoutConstraint *constraint in view.superview.constraints) {
        if (!constraint.isActive || constraint.relation != NSLayoutRelationEqual || constraint.multiplier != 1) continue;
        BOOL pinned = (constraint.firstItem == view && constraint.secondItem == view.superview) || (constraint.firstItem == view.superview && constraint.secondItem == view);
        if (!pinned || constraint.firstAttribute != NSLayoutAttributeBottom || constraint.secondAttribute != NSLayoutAttributeBottom) continue;
        if (nearlyEqual(fabs(constraint.constant), gap)) {
            constraint.constant = 0;
            return YES;
        }
    }
    if (!view.translatesAutoresizingMaskIntoConstraints) return NO;
    CGRect frame = view.frame;
    frame.size.height += gap;
    view.frame = frame;
    return YES;
}

static void extendDown(UIView *parent, UIView *root, CGFloat gap, int depth) {
    CGFloat height = CGRectGetHeight(root.bounds), width = CGRectGetWidth(root.bounds);
    for (UIView *view in [parent.subviews copy]) {
        if (view.hidden || view.alpha < 0.01) continue;
        CGRect frame = [root convertRect:view.bounds fromView:view];
        if (CGRectGetWidth(frame) < width * 0.9 || CGRectGetHeight(frame) <= gap) continue;
        if (nearlyEqual(CGRectGetMaxY(frame), height - gap) && growView(view, gap)) {
            [view.superview layoutIfNeeded];
            frame = [root convertRect:view.bounds fromView:view];
        }
        if (CGRectGetMaxY(frame) < height - gap - 1.5) continue;  // 够不到底部那一段，里面不用看
        if ([view isKindOfClass:UIScrollView.class]) {
            UIScrollView *list = (UIScrollView *)view;
            if (list.contentSize.width <= CGRectGetWidth(list.bounds) + 1) {
                // 延伸到底的竖向列表，末尾留出底栏的位置；里面是单元格，不往里找
                if (nearlyEqual(CGRectGetMaxY(frame), height) && list.adjustedContentInset.bottom < gap) {
                    UIEdgeInsets inset = list.contentInset;
                    inset.bottom += gap - list.adjustedContentInset.bottom;
                    list.contentInset = inset;
                }
                continue;
            }
        }
        if (depth < 9) extendDown(view, root, gap, depth + 1);
    }
}

+ (void)extendTabPage:(UIViewController *)page {
    UINavigationController *navigation = page.navigationController;
    if (!page.view.window || navigation.viewControllers.firstObject != page || navigation.parentViewController != XHSNativeConfig.shared.tabBarController) return;
    if (!(page.edgesForExtendedLayout & UIRectEdgeBottom)) {
        page.edgesForExtendedLayout |= UIRectEdgeBottom;
        [navigation.view setNeedsLayout];
    }
    static BOOL busy;
    if (busy) return;
    busy = YES;
    extendDown(page.view, page.view, 44 + page.view.window.safeAreaInsets.bottom, 0);
    busy = NO;
}

#pragma mark - 图文笔记页

// 正文延伸到上下两条栏的后面，栏的底色去掉，控件悬浮在玻璃胶囊上。
// 顶栏两块：返回 + 头像 + 昵称 / 关注 + 分享；底栏一块：评论框 + 点赞收藏评论。

static char kNoteLeftKey, kNoteRightKey, kNoteBottomKey, kNoteBottomRightKey, kNoteEdgeKey;

// 不算位移的 frame（frame 会把 transform 算进去）
static CGRect layoutFrame(UIView *view) {
    CGSize size = view.bounds.size;
    return CGRectMake(view.center.x - size.width / 2, view.center.y - size.height / 2, size.width, size.height);
}

// 一组按钮里看得见的内容占的范围（在这组自己的坐标里）。栈里可能留着不显示的位置，
// 按钮也可能比里面的图标和数字宽，按整组的宽度垫玻璃会一边空出一截
static CGRect visibleSpan(UIView *group) {
    CGRect span = CGRectNull;
    for (UIView *button in group.subviews) {
        if (button.hidden || button.alpha < 0.01 || CGRectIsEmpty(button.bounds)) continue;
        CGRect frame = layoutFrame(button), content = CGRectNull;
        for (UIView *view in button.subviews) {
            BOOL shown = !view.hidden && view.alpha > 0.01 && !CGRectIsEmpty(view.bounds);
            if (shown && ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class])) content = CGRectUnion(content, layoutFrame(view));
        }
        span = CGRectUnion(span, CGRectIsNull(content) ? frame : CGRectOffset(content, CGRectGetMinX(frame), CGRectGetMinY(frame)));
    }
    return CGRectIsNull(span) ? group.bounds : span;
}

static void setOffset(UIView *view, CGFloat x, CGFloat y) {
    CGAffineTransform transform = (fabs(x) < 0.5 && fabs(y) < 0.5) ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(x, y);
    if (view && !CGAffineTransformEqualToTransform(view.transform, transform)) view.transform = transform;
}

+ (void)layoutNoteTop:(UIView *)bar {
    [self clearBackground:bar];
    // 控件那一行在安全区下面
    UIView *row = nil;
    for (UIView *view in bar.subviews) {
        if ([XHSNativeLegacy isGlassView:view] || view.hidden || CGRectGetHeight(view.frame) <= 30) continue;
        if (!row || CGRectGetMinY(view.frame) > CGRectGetMinY(row.frame)) row = view;
    }
    if (!row) return;
    [self clearBackground:row];
    if (![self supportsGlass]) {
        static char kNoteTopFadeKey;
        [XHSNativeLegacy applySoftEdgeFadeOn:bar key:&kNoteTopFadeKey fromTop:YES extraHeight:14];
    }

    UIView *back = nil, *author = nil;
    for (UIView *view in row.subviews) {
        if ([view isKindOfClass:UIButton.class]) back = back ?: view;
        else author = [self subviewOf:view named:@"XYNoteModule.NoteDirectionView"] ?: author;
    }
    if (!author) return;
    UIView *avatar = nil, *follow = nil, *share = nil, *name = nil;
    for (UIView *view in author.subviews) {
        if ([view isKindOfClass:objc_getClass("XYFollowBtn")]) follow = view;
        else if ([view isKindOfClass:UIButton.class]) share = view;
        else if ([view isKindOfClass:UIStackView.class]) name = name ?: view;
        else if ([NSStringFromClass(view.class) isEqualToString:@"XYUserAvatar"]) avatar = view;
    }

    CGFloat y = CGRectGetMidY(row.frame) - 24;
    // 右边：关注 + 分享
    UIView *first = [self isVisible:follow] ? follow : ([self isVisible:share] ? share : nil);
    CGRect right = CGRectZero;
    if (first) {
        CGFloat x = CGRectGetMinX([bar convertRect:first.bounds fromView:first]) - (first == follow ? 6 : 12);
        right = CGRectMake(x, y, CGRectGetWidth(bar.bounds) - 8 - x, 48);
    }
    // 左边：返回 + 头像 + 昵称，按内容收窄
    UIView *last = [self isVisible:name] ? name : ([self isVisible:avatar] ? avatar : back);
    CGFloat maxX = CGRectGetMaxX([bar convertRect:last.bounds fromView:last]) + (last == back ? 12 : 16);
    if (first) maxX = MIN(maxX, CGRectGetMinX(right) - 8);
    [self plateOn:bar key:&kNoteLeftKey below:row frame:CGRectMake(8, y, maxX - 8, 48) bar:kXHSNativeBarNoteTop];
    [self plateOn:bar key:&kNoteRightKey below:row frame:right bar:kXHSNativeBarNoteTop];
}

+ (void)layoutNoteBottom:(UIView *)bar {
    [self clearBackground:bar];
    XYNoteInteractionView *content = (id)[self subviewOf:bar named:@"XYNoteModule.InteractionView"];
    if (!content.window) return;
    [self clearBackground:content];
    UIView *stack = nil;
    for (UIView *view in content.subviews) {
        if ([XHSNativeLegacy isGlassView:view]) continue;
        if ([view isKindOfClass:UIStackView.class]) stack = stack ?: view;
        // 顶上那条分隔线：不到 1pt 高，里面没东西
        else if (!view.subviews.count && CGRectGetHeight(view.frame) > 0 && CGRectGetHeight(view.frame) <= 1 && !view.hidden) view.hidden = YES;
    }
    if (CGRectGetHeight(stack.frame) <= 1) return;
    // 点赞动画单独绘制，图标上原本有一块与页面同色的方形遮底。
    XYLottieAnimationButton *like = [content respondsToSelector:@selector(likeButton)] ? content.likeButton : nil;
    UIView *mask = [like respondsToSelector:@selector(lottieMaskView)] ? like.lottieMaskView : nil;
    if (mask && mask.superview == like.imageView && !mask.subviews.count && mask.alpha != 0) mask.alpha = 0;
    // 评论框自带的灰色药丸底去掉，和旁边的按钮一样直接放在玻璃上
    UIView *fieldGroup = nil, *buttons = nil;
    for (UIView *group in stack.subviews) {
        BOOL hasField = NO;
        for (UIView *field in group.subviews) {
            if (![NSStringFromClass(field.class) hasSuffix:@"Field"]) continue;
            [self clearBackground:field];
            hasField = YES;
        }
        if (hasField) fieldGroup = fieldGroup ?: group;
        else if ([group isKindOfClass:UIStackView.class]) buttons = group;
    }

    // 拆成两块：左边评论框，右边点赞、收藏、评论。左右和底下留一样的边距，和屏幕圆角同心；
    // 没有底部安全区的机型在栏里居中。控件用位移挪进去，不动小红书的约束
    CGFloat height = 48, gap = 10, padding = 10;
    CGFloat width = CGRectGetWidth(content.bounds), below = CGRectGetHeight(content.window.bounds) - CGRectGetMaxY([content convertRect:content.bounds toView:nil]);
    CGFloat margin = content.window.safeAreaInsets.bottom > 0 ? 20 : (CGRectGetHeight(content.bounds) - height) / 2;
    CGFloat y = CGRectGetHeight(content.bounds) + below - margin - height;
    CGRect row = layoutFrame(stack);
    setOffset(stack, 0, y + height / 2 - CGRectGetMidY(row));

    CGRect left = CGRectMake(margin, y, width - margin * 2, height), right = CGRectZero;
    CGRect span = buttons ? visibleSpan(buttons) : CGRectZero;
    if (fieldGroup && buttons) {
        right = CGRectMake(width - margin - CGRectGetWidth(span) - padding * 2, y, CGRectGetWidth(span) + padding * 2, height);
        left.size.width = CGRectGetMinX(right) - gap - margin;
        if (CGRectGetWidth(left) < 80) {
            // 数字太长放不下两块，退回一整条
            left.size.width = width - margin * 2;
            right = CGRectZero;
        }
    }
    CAGradientLayer *fade = (CAGradientLayer *)fieldGroup.layer.mask;
    if (CGRectIsEmpty(right)) {
        setOffset(fieldGroup, 0, 0);
        setOffset(buttons, 0, 0);
        fieldGroup.layer.mask = nil;
    } else {
        setOffset(fieldGroup, margin + 6 - CGRectGetMinX(row) - CGRectGetMinX(layoutFrame(fieldGroup)), 0);
        setOffset(buttons, CGRectGetMaxX(right) - padding - CGRectGetMinX(row) - CGRectGetMinX(layoutFrame(buttons)) - CGRectGetMaxX(span), 0);
        // 评论框还是原来的宽度，比胶囊宽。提示语长的时候（比如英文界面）会伸到右边那块上，超出胶囊的部分渐隐掉
        if (![fade isKindOfClass:CAGradientLayer.class]) {
            fade = [CAGradientLayer layer];
            fade.startPoint = CGPointMake(0, 0.5);
            fade.endPoint = CGPointMake(1, 0.5);
            fade.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
            fieldGroup.layer.mask = fade;
        }
        CGRect visible = CGRectMake(0, 0, CGRectGetMaxX(left) - 2 - (margin + 6), CGRectGetHeight(fieldGroup.bounds));
        if (!CGRectEqualToRect(fade.frame, visible)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            fade.frame = visible;
            fade.locations = @[@0, @(1 - 8 / CGRectGetWidth(visible)), @1];
            [CATransaction commit];
        }
    }
    // 玻璃记在它所在的那层上：这一层会被小红书拿到别的笔记页里接着用，记在外层的话每开一篇就多垫一块
    [self plateOn:content key:&kNoteBottomKey below:stack frame:left bar:kXHSNativeBarNoteBottom];
    [self plateOn:content key:&kNoteBottomRightKey below:stack frame:right bar:kXHSNativeBarNoteBottom];
    if (![self supportsGlass]) [XHSNativeLegacy adjustNoteBottomInStack:stack];
}

+ (void)layoutNotePage:(UIViewController *)page {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote]) return;
    UIView *root = page.view;
    UIView *top = [self subviewOf:root named:@"XYNoteModule.NavigationBar"], *bottom = [self subviewOf:root named:@"XYNoteModule.NoteDetailBottomView"];
    UICollectionView *list = nil;
    for (UIView *view in root.subviews)
        if ([view isKindOfClass:UICollectionView.class]) list = list ?: (UICollectionView *)view;
    if (!top || !bottom || !list || top.hidden || bottom.hidden) return;

    // 列表的位置不动，它本来就夹在上下两条栏之间。不裁剪，滚出去的内容就能透过栏看到；
    // 可见范围往上下扩到屏幕边，栏后面的单元格才不会被回收（否则栏下面会一块块露出底色）
    if (list.clipsToBounds) list.clipsToBounds = NO;
    UIEdgeInsets reach = UIEdgeInsetsMake(-CGRectGetMinY(list.frame), 0, CGRectGetMaxY(list.frame) - CGRectGetMaxY(root.bounds), 0);
    if ([list respondsToSelector:@selector(_setVisibleRectEdgeInsets:)] && !UIEdgeInsetsEqualToEdgeInsets([list _visibleRectEdgeInsets], reach))
        [list _setVisibleRectEdgeInsets:reach];

    // 顶栏下面的 soft 边缘，见 XHSNativeSoftEdge；底部不要边缘效果，胶囊直接浮在正文上
    // 低系统没有系统的边缘效果，换成插件画的渐隐，见 layoutNoteTop
    if ([self supportsGlass]) {
        XHSNativeSoftEdge *edge = objc_getAssociatedObject(list, &kNoteEdgeKey);
        if (!edge) {
            edge = [XHSNativeSoftEdge new];
            edge.userInteractionEnabled = NO;
            edge.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
            edge.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
            UIScrollEdgeElementContainerInteraction *interaction = [UIScrollEdgeElementContainerInteraction new];
            interaction.edge = UIRectEdgeTop;
            interaction.scrollView = edge;
            [top addInteraction:interaction];
            [list addObserver:edge forKeyPath:@"contentOffset" options:0 context:NULL];
            objc_setAssociatedObject(list, &kNoteEdgeKey, edge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (edge.superview != root) [root insertSubview:edge belowSubview:top];
        if (!CGRectEqualToRect(edge.frame, top.frame)) {
            edge.frame = top.frame;
            edge.contentSize = top.frame.size;
            edge.contentInset = UIEdgeInsetsMake(CGRectGetHeight(top.frame), 0, 0, 0);
        }
        [edge follow:list];
        if (!list.bottomEdgeEffect.hidden) list.bottomEdgeEffect.hidden = YES;
    }

    [self layoutNoteTop:top];
    [self layoutNoteBottom:bottom];
    if (![self supportsGlass]) [XHSNativeLegacy attachScrollView:list toBar:top];
}

// 「头像 昵称 关注 分享」这一条是贴着安全区摆的，上面把栏高记进安全区之后它会被推到栏外，
// 用位移把它放回容器的垂直正中（位移不参与自动布局，不会和它的约束打架）
+ (void)recenterAuthorRow:(UIView *)row {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassNote]) return;
    UIView *box = row.superview;
    CGFloat y = row.center.y - CGRectGetHeight(row.bounds) / 2;
    CGFloat offset = (CGRectGetHeight(box.bounds) - CGRectGetHeight(row.bounds)) / 2 - y;
    CGAffineTransform transform = fabs(offset) < 0.5 ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(0, offset);
    if (!CGAffineTransformEqualToTransform(row.transform, transform)) row.transform = transform;
    // 昵称是异步填进来的，宽度变了胶囊要跟着改
    for (UIView *view = box; view; view = view.superview) {
        if (![NSStringFromClass(view.class) isEqualToString:@"XYNoteModule.NavigationBar"]) continue;
        [self layoutNoteTop:view];
        break;
    }
}

// 双击笔记里的图片：和单击一样进小红书的大图，再放大到点的位置。
// 大图里的双击放大是小红书自带的（实验开关，见 hook），所以进去以后再双击就缩回
+ (void)openGalleryZoomedFrom:(UIView *)browser {
    if (![browser respondsToSelector:@selector(handleWithMultiGesture:)]) return;
    UIView *image = [browser respondsToSelector:@selector(currentImageView)] ? [browser currentImageView] : nil;
    id tap = [browser respondsToSelector:@selector(multiRegesture)] ? [browser multiRegesture] : nil;
    CGPoint unit = CGPointMake(0.5, 0.5);
    if ([image isKindOfClass:UIView.class] && [tap isKindOfClass:UIGestureRecognizer.class] && !CGRectIsEmpty(image.bounds)) {
        CGPoint point = [(UIGestureRecognizer *)tap locationInView:image];
        unit = CGPointMake(MAX(0, MIN(1, point.x / CGRectGetWidth(image.bounds))), MAX(0, MIN(1, point.y / CGRectGetHeight(image.bounds))));
    }
    [browser handleWithMultiGesture:[XHSNativeSingleTap new]];
    [self zoomGalleryIn:browser.window at:unit tries:40];
}

// 大图是带转场出来的：转场期间它的列表是藏着的，这时候设缩放会被冲掉。等它露出来再放大
+ (void)zoomGalleryIn:(UIWindow *)window at:(CGPoint)unit tries:(NSInteger)tries {
    UIScrollView *scroll = [self galleryScrollViewIn:window];
    UIView *image = [scroll.delegate respondsToSelector:@selector(viewForZoomingInScrollView:)] ? [scroll.delegate viewForZoomingInScrollView:scroll] : nil;
    BOOL ready = image && !CGRectIsEmpty(image.bounds);
    for (UIView *view = scroll; view && ready; view = view.superview) ready = !view.hidden && view.alpha > 0.01;
    if (!ready) {
        if (tries > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self zoomGalleryIn:window at:unit tries:tries - 1];
        });
        return;
    }
    CGFloat scale = MIN(2, scroll.maximumZoomScale);  // 和它自己双击放大的倍数一样
    CGSize size = CGSizeMake(CGRectGetWidth(scroll.bounds) / scale, CGRectGetHeight(scroll.bounds) / scale);
    CGPoint center = CGPointMake(unit.x * CGRectGetWidth(image.bounds), unit.y * CGRectGetHeight(image.bounds));
    [scroll zoomToRect:CGRectMake(center.x - size.width / 2, center.y - size.height / 2, size.width, size.height) animated:YES];
}

// 大图当前这一页的缩放视图
+ (UIScrollView *)galleryScrollViewIn:(UIView *)view {
    if ([view isKindOfClass:UIScrollView.class] && [NSStringFromClass(view.superview.class) containsString:@"GalleryItemView"]) {
        UIScrollView *scroll = (UIScrollView *)view;
        CGRect frame = [scroll convertRect:scroll.bounds toView:nil];
        if (scroll.maximumZoomScale > 1 && fabs(CGRectGetMinX(frame)) < 1) return scroll;
    }
    for (UIView *subview in view.subviews) {
        UIScrollView *scroll = [self galleryScrollViewIn:subview];
        if (scroll) return scroll;
    }
    return nil;
}

#pragma mark - 视频页

// 顶上的按钮按左右分成两个胶囊（返回 + 小窗 / 搜索 + 分享），底部互动栏垫一个胶囊。
// 视频页永远是深色界面，玻璃固定用深色。

static char kVideoLeftKey, kVideoRightKey, kVideoBottomKey;

static void darken(UIView *glass) {
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
}

+ (void)layoutVideoHead:(UIView *)head {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassVideo]) return;
    CGFloat middle = CGRectGetMidX(head.bounds);
    CGRect left = CGRectNull, right = CGRectNull;
    UIView *lowest = nil;
    for (UIView *view in head.subviews) {
        if ([XHSNativeLegacy isGlassView:view]) continue;
        lowest = lowest ?: view;
        if (![view isKindOfClass:UIControl.class] || ![self isVisible:view]) continue;
        if (CGRectGetMidX(view.frame) < middle) left = CGRectUnion(left, view.frame);
        else right = CGRectUnion(right, view.frame);
    }
    if (!lowest) return;
    CGRect (^around)(CGRect) = ^CGRect(CGRect buttons) {
        return CGRectIsNull(buttons) ? CGRectZero : CGRectMake(CGRectGetMinX(buttons) - 9, CGRectGetMidY(buttons) - 22, CGRectGetWidth(buttons) + 18, 44);
    };
    darken([self plateOn:head key:&kVideoLeftKey below:lowest frame:around(left) bar:kXHSNativeBarVideoTop]);
    darken([self plateOn:head key:&kVideoRightKey below:lowest frame:around(right) bar:kXHSNativeBarVideoTop]);
}

+ (void)layoutVideoEngage:(UIView *)bar {
    if (![XHSNativeConfig.shared boolForKey:kXHSNativeGlassVideo]) return;
    CGRect row = CGRectNull;
    UIView *lowest = nil;
    for (UIView *view in bar.subviews) {
        if ([XHSNativeLegacy isGlassView:view]) continue;
        lowest = lowest ?: view;
        if (![self isVisible:view]) continue;
        row = CGRectUnion(row, view.frame);
        // 评论框自带的灰色药丸底去掉
        if ([NSStringFromClass(view.class) hasSuffix:@"VFBottomWriteCmtView"])
            for (UIView *field in view.subviews) [self clearBackground:field];
    }
    if (!lowest || CGRectIsNull(row)) return;
    // 这一排控件的可见内容在各自格子的下半部分
    CGRect frame = CGRectMake(8, CGRectGetMaxY(row) - 39, CGRectGetWidth(bar.bounds) - 16, 44);
    darken([self plateOn:bar key:&kVideoBottomKey below:lowest frame:frame bar:kXHSNativeBarVideoBottom]);
}

#pragma mark - 设置界面

+ (NSString *)entryIdentity {
    return @"XHSNative";
}

+ (id)entryOption {
    return row(@"leftIconArrow", with(rowTitle(@"XHSNative"), @"setIconFont", [self themeGlyph:@"filters_b"]), [self entryIdentity]);
}

+ (NSArray *)settingsRows {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSMutableArray *rows = [NSMutableArray arrayWithObject:gap(12)];
    // 低系统的底栏、玻璃是插件自己画的，消息顶栏和私聊输入栏没有，多了图标、文字大小和模糊程度
    BOOL glass = [self supportsGlass];
    [rows addObject:row(@"label", rowTitle(@"底部标签栏"), @"tabs.heading")];
    [rows addObject:gap(8)];
    // 每组里的行按文字从短到长排
    for (NSString *name in @[@"me", @"shopping", @"message"])
        [rows addObject:switchRow(tabTitles()[name], ![config isTabHidden:name], [@"tab." stringByAppendingString:name])];
    [rows addObject:switchRow(@"搜索", [config boolForKey:kXHSNativeSearchTab], [@"pref." stringByAppendingString:kXHSNativeSearchTab])];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSString *name in config.tabOrder) [order addObject:tabTitles()[name]];
    [rows addObject:row(@"arrow", with(rowTitle(@"标签顺序"), @"setTrailing", [order componentsJoinedByString:@" "]), @"order")];
    if (!glass) {
        [rows addObject:row(@"arrow", with(rowTitle(@"图标大小"), @"setTrailing", [NSString stringWithFormat:@"%.0f", config.tabIconSize]), @"tabIconSize")];
        [rows addObject:row(@"arrow", with(rowTitle(@"文字大小"), @"setTrailing", [NSString stringWithFormat:@"%.0f", config.tabTitleSize]), @"tabTitleSize")];
    }
    [rows addObject:switchRow(@"滚动时收起", [config boolForKey:kXHSNativeMinimize], [@"pref." stringByAppendingString:kXHSNativeMinimize])];
    [rows addObject:switchRow(@"显示底栏文字", config.isTabTitleShown, [@"pref." stringByAppendingString:kXHSNativeTabTitles])];
    [rows addObject:switchRow(@"交换搜索与发布", config.isPublishSwapped, [@"pref." stringByAppendingString:kXHSNativeSwapPublish])];
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(@"交换后，发布在底栏右侧，搜索回到首页顶栏。"), @"tabs.note")];
    [rows addObject:gap(24)];

    [rows addObject:row(@"label", rowTitle(@"首页频道"), @"channels.heading")];
    [rows addObject:gap(8)];
    NSArray *channels = channelTitles();
    for (NSUInteger page = 0; page < channels.count; page++)
        [rows addObject:switchRow(channels[page], ![config isChannelHidden:page], [NSString stringWithFormat:@"channel.%lu", (unsigned long)page])];
    NSMutableArray<NSString *> *channelOrder = [NSMutableArray array];
    for (NSNumber *page in config.channelOrder) [channelOrder addObject:channels[page.unsignedIntegerValue]];
    NSMutableArray<NSString *> *channelNames = [NSMutableArray array];
    for (NSUInteger page = 0; page < channels.count; page++) [channelNames addObject:[config nameForChannel:page] ?: channels[page]];
    [rows addObject:row(@"arrow", with(rowTitle(@"频道名称"), @"setTrailing", [channelNames componentsJoinedByString:@" "]), @"channelNames")];
    [rows addObject:row(@"arrow", with(rowTitle(@"频道顺序"), @"setTrailing", [channelOrder componentsJoinedByString:@" "]), @"channelOrder")];
    [rows addObject:switchRow(@"隐藏频道红线", config.isChannelLineHidden, [@"pref." stringByAppendingString:kXHSNativeHideChannelLine])];
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(@"频道的显示和顺序重启小红书后生效。"), @"channels.note")];
    [rows addObject:gap(24)];

    [rows addObject:row(@"label", rowTitle(@"功能"), @"features.heading")];
    [rows addObject:gap(8)];
    [rows addObject:switchRow(@"无水印保存", config.isNoWatermarkEnabled, [@"pref." stringByAppendingString:kXHSNativeNoWatermark])];
    [rows addObject:switchRow(@"禁用点点 AI", config.isDotsDisabled, [@"pref." stringByAppendingString:kXHSNativeDisableDots])];
    [rows addObject:switchRow(@"双击放大图片", config.isDoubleTapZoomEnabled, [@"pref." stringByAppendingString:kXHSNativeDoubleTapZoom])];
    [rows addObject:switchRow(@"解除保存限制", config.isSaveRestrictionIgnored, [@"pref." stringByAppendingString:kXHSNativeIgnoreNoSave])];
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(@"禁用点点 AI 后重启小红书生效。\n双击放大的图片，再双击缩回。\n解除保存限制后，作者关闭了保存的笔记也能保存。"), @"features.note")];
    [rows addObject:gap(24)];

    [rows addObject:row(@"label", rowTitle(@"液态玻璃"), @"glass.heading")];
    [rows addObject:gap(8)];
    for (NSArray *option in @[@[@"视频", kXHSNativeGlassVideo], @[@"搜索栏", kXHSNativeGlassSearch], @[@"图文笔记", kXHSNativeGlassNote],
                              @[@"消息顶栏", kXHSNativeGlassMessages], @[@"评论输入栏", kXHSNativeGlassComments],
                              @[@"私聊输入栏", kXHSNativeGlassChat], @[@"个人页顶栏", kXHSNativeGlassProfile]]) {
        if (!glass && ([option[1] isEqual:kXHSNativeGlassMessages] || [option[1] isEqual:kXHSNativeGlassChat])) continue;
        [rows addObject:switchRow(option[0], [config boolForKey:option[1]], [@"pref." stringByAppendingString:option[1]])];
    }
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(@"下次进入页面时生效。"), @"glass.note")];
    [rows addObject:gap(24)];

    [rows addObject:row(@"label", rowTitle(@"不透明度"), @"fillHeading")];
    [rows addObject:gap(8)];
    if (!glass) [rows addObject:row(@"arrow", with(rowTitle(@"模糊程度"), @"setTrailing", [NSString stringWithFormat:@"%.0f%%", config.blurPercent]), @"blur")];
    for (NSArray *bar in glassBars()) {
        id title = with(rowTitle(bar[0]), @"setTrailing", [NSString stringWithFormat:@"%.0f%%", [config fillForBar:bar[1]]]);
        [rows addObject:row(@"arrow", title, [@"fill." stringByAppendingString:bar[1]])];
    }
    [rows addObject:gap(24)];
    [rows addObject:row(@"button", rowTitle(@"恢复默认"), @"reset")];
    return rows;
}

+ (NSArray *)rowsForMode:(NSString *)mode {
    if (!mode) return [self settingsRows];
    if ([self isOrderMode:mode]) return [self orderRowsForMode:mode];
    if ([mode isEqualToString:@"channelNames"]) return [self channelNameRows];
    return [self valueRowsForMode:mode];
}

// 频道名称：点一行弹输入框，留空恢复小红书原来的名字
+ (NSArray *)channelNameRows {
    NSMutableArray *rows = [NSMutableArray arrayWithObject:gap(12)];
    XHSNativeConfig *config = XHSNativeConfig.shared;
    for (NSUInteger page = 0; page < channelTitles().count; page++)
        [rows addObject:row(@"arrow", with(rowTitle(channelTitles()[page]), @"setTrailing", [config nameForChannel:page] ?: @""), [NSString stringWithFormat:@"name.%lu", (unsigned long)page])];
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(@"留空恢复原来的名字。"), @"note")];
    return rows;
}

+ (void)renameChannel:(NSUInteger)page onPage:(XHSNativeSettingsPage *)settings {
    NSString *original = channelTitles()[page];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"「%@」的名称", original] message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [XHSNativeConfig.shared nameForChannel:page];
        field.placeholder = original;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [XHSNativeConfig.shared setName:name forChannel:page];
        [XHSNativeHelper applySettings];
        [settings reloadRows];
    }]];
    [settings presentViewController:alert animated:YES completion:nil];
}

// 拖动排序的页面：order 是底栏标签，channelOrder 是首页频道
+ (BOOL)isOrderMode:(NSString *)mode {
    return [mode isEqualToString:@"order"] || [mode isEqualToString:@"channelOrder"];
}

+ (NSArray *)orderRowsForMode:(NSString *)mode {
    NSMutableArray *rows = [NSMutableArray array];
    if ([mode isEqualToString:@"channelOrder"]) {
        for (NSNumber *page in XHSNativeConfig.shared.channelOrder)
            [rows addObject:withFlag(row(@"text", rowTitle(channelTitles()[page.unsignedIntegerValue]), page.stringValue), @"setCornerMaskUsesCellBounds", YES)];
        return rows;
    }
    for (NSString *name in XHSNativeConfig.shared.tabOrder)
        [rows addObject:withFlag(row(@"text", rowTitle(tabTitles()[name]), name), @"setCornerMaskUsesCellBounds", YES)];
    return rows;
}

+ (void)moveOrderInMode:(NSString *)mode from:(NSUInteger)from to:(NSUInteger)to {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    BOOL channels = [mode isEqualToString:@"channelOrder"];
    NSMutableArray *order = [(channels ? config.channelOrder : config.tabOrder) mutableCopy];
    if (from >= order.count || to >= order.count) return;
    id item = order[from];
    [order removeObjectAtIndex:from];
    [order insertObject:item atIndex:to];
    if (channels) config.channelOrder = order;
    else config.tabOrder = order;
}

// 选数值：不透明度和模糊程度按百分比，底栏图标和文字按字号（这两项和模糊程度只有低系统有）
+ (NSArray *)valueRowsForMode:(NSString *)mode {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    NSInteger current, from = 0, to = 100, step = 10;
    NSString *format = @"%ld%%", *note = @"0% 是纯玻璃，数值越大越不透。";
    if ([mode isEqualToString:@"blur"]) {
        current = config.blurPercent;
        note = @"0% 不模糊，数值越大越模糊。";
    } else if ([mode isEqualToString:@"tabIconSize"]) {
        current = config.tabIconSize, from = 16, to = 32, step = 2, format = @"%ld";
        note = @"默认 28。\n显示底栏文字时，调到 20 到 22 比较合适。";
    } else if ([mode isEqualToString:@"tabTitleSize"]) {
        current = config.tabTitleSize, from = 8, to = 14, step = 1, format = @"%ld";
        note = @"默认 10。";
    } else {
        current = [config fillForBar:mode];
    }
    NSMutableArray *rows = [NSMutableArray arrayWithObject:gap(12)];
    for (NSInteger value = from; value <= to; value += step) {
        id title = withFlag(rowTitle([NSString stringWithFormat:format, (long)value]), @"setSelected", value == current);
        [rows addObject:row(@"selector", title, [NSString stringWithFormat:@"value.%ld", (long)value])];
    }
    [rows addObject:gap(8)];
    [rows addObject:row(@"label", rowTitle(note), @"note")];
    return rows;
}

+ (void)setValue:(double)value forMode:(NSString *)mode {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if ([mode isEqualToString:@"blur"]) config.blurPercent = value;
    else if ([mode isEqualToString:@"tabIconSize"]) config.tabIconSize = value;
    else if ([mode isEqualToString:@"tabTitleSize"]) config.tabTitleSize = value;
    else [config setFill:value forBar:mode];
}

+ (NSString *)titleForMode:(NSString *)mode {
    if (!mode) return @"XHSNative";
    if ([mode isEqualToString:@"order"]) return @"标签顺序";
    if ([mode isEqualToString:@"channelOrder"]) return @"频道顺序";
    if ([mode isEqualToString:@"channelNames"]) return @"频道名称";
    if ([mode isEqualToString:@"blur"]) return @"模糊程度";
    if ([mode isEqualToString:@"tabIconSize"]) return @"图标大小";
    if ([mode isEqualToString:@"tabTitleSize"]) return @"文字大小";
    for (NSArray *bar in glassBars())
        if ([bar[1] isEqualToString:mode]) return [bar[0] stringByAppendingString:@"不透明度"];
    return @"XHSNative";
}

+ (UIView *)settingsFooterWithWidth:(CGFloat)width {
    UIStackView *footer = [UIStackView new];
    footer.axis = UILayoutConstraintAxisVertical;
    footer.alignment = UIStackViewAlignmentCenter;
    footer.spacing = 8;
    footer.layoutMarginsRelativeArrangement = YES;
    footer.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(14, 0, 14, 0);

    UIFont *font = [UIFont systemFontOfSize:12];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSInteger year = [calendar component:NSCalendarUnitYear fromDate:NSDate.date];
    NSString *copyright = [NSString stringWithFormat:@"© %ld huamidev. All rights reserved.", (long)year];
    NSArray *lines = @[@"XHSNative", @"Version: " XHSNativeVersion, @"Developed by huami1314", copyright];
    CGFloat opacity[] = {0.8, 0.56, 0.56 * 0.7, 0.56 * 0.5};
    for (NSUInteger i = 0; i < lines.count; i++) {
        UILabel *label = [UILabel new];
        label.text = lines[i];
        label.font = font;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor.labelColor colorWithAlphaComponent:opacity[i]];
        [footer addArrangedSubview:label];
    }
    CGFloat height = [footer systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].height;
    footer.frame = CGRectMake(0, 0, width, ceil(height));
    return footer;
}

+ (void)handleTap:(NSString *)identity onPage:(XHSNativeSettingsPage *)page {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if ([identity hasPrefix:@"name."]) {
        [self renameChannel:[identity substringFromIndex:5].integerValue onPage:page];
    } else if ([self isOrderMode:identity] || [identity hasPrefix:@"fill."] ||
               [@[@"channelNames", @"blur", @"tabIconSize", @"tabTitleSize"] containsObject:identity]) {
        XHSNativeSettingsPage *next = [[objc_getClass("XHSNativeSettingsPage") alloc] init];
        next.mode = [identity hasPrefix:@"fill."] ? [identity substringFromIndex:5] : identity;
        [page.navigationController pushViewController:next animated:YES];
    } else if ([identity hasPrefix:@"value."]) {
        [self setValue:[identity substringFromIndex:6].doubleValue forMode:page.mode];
        [self applySettings];
        [page.navigationController popViewControllerAnimated:YES];
    } else if ([identity isEqualToString:@"reset"]) {
        [config reset];
        [self applySettings];
        [page reloadRows];
    }
}

+ (void)handleSwitch:(NSString *)identity on:(BOOL)on {
    XHSNativeConfig *config = XHSNativeConfig.shared;
    if ([identity hasPrefix:@"pref."]) [config setBool:on forKey:[identity substringFromIndex:5]];
    else if ([identity hasPrefix:@"tab."]) [config setTab:[identity substringFromIndex:4] hidden:!on];
    else if ([identity hasPrefix:@"channel."]) [config setChannel:[identity substringFromIndex:8].integerValue hidden:!on];
    [self applySettings];
}

+ (void)applySettings {
    [self rebuildTabs];
    [XHSNativeConfig.shared.homeBar setNeedsLayout];
    if (![self supportsGlass]) [XHSNativeLegacy applyLegacySettings];
}

#pragma mark - 系统版本

+ (BOOL)supportsGlass {
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

#pragma mark - iOS 27.1 以下

+ (void)patchOlderSystems {
    class_addMethod(UITraitCollection.class, NSSelectorFromString(@"verticalBarEdge"), (IMP)verticalBarEdgeUnspecified, "q@:");
    if (noTraits()) fillImport("_$sSo17UITraitCollectionC5UIKitE36systemTraitsAffectingVerticalBarEdgeSayAC0A10Definition_pXpGvgZ", (void *)noTraits);
    gSafeAreaRegion = dlsym(RTLD_DEFAULT, "$sSo6UIViewC5UIKitE12LayoutRegionV8safeArea16cornerAdaptationA2E14AdaptivityAxisOSg_tFZ");
    if (gSafeAreaRegion) fillImport("_$sSo6UIViewC5UIKitE12LayoutRegionV3bar6onEdge6extentAESo06UIRectG0V_12CoreGraphics7CGFloatVtFZ", (void *)layoutRegionBar);
}

@end
