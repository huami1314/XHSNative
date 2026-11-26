#import <Foundation/Foundation.h>

// 只撤销插件仍持有的改动；宿主在此之后写入的新状态优先。
@interface XHSNativeViewState : NSObject
+ (void)setValues:(NSDictionary<NSString *, id> *)values on:(NSObject *)object owner:(NSObject *)owner;
+ (void)restoreProperties:(NSArray<NSString *> *)properties on:(NSObject *)object owner:(NSObject *)owner;
+ (void)addDecoration:(NSObject *)decoration owner:(NSObject *)owner;
+ (void)restoreOwner:(NSObject *)owner;
+ (NSArray<NSObject *> *)owners;
@end
