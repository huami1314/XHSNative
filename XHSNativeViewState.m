#import "XHSNativeViewState.h"
#import <objc/runtime.h>

@interface XHSNativeViewState ()
@property (nonatomic, strong) NSMapTable<NSObject *, NSMutableDictionary *> *changes;
@property (nonatomic, strong) NSHashTable<NSObject *> *decorations;
@end

@implementation XHSNativeViewState

static char kViewStateKey;

+ (NSHashTable *)ownerTable {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

+ (instancetype)stateForOwner:(NSObject *)owner create:(BOOL)create {
    if (!owner) return nil;
    XHSNativeViewState *state = objc_getAssociatedObject(owner, &kViewStateKey);
    if (!state && create) {
        state = [self new];
        state.changes = [NSMapTable weakToStrongObjectsMapTable];
        state.decorations = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(owner, &kViewStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[self ownerTable] addObject:owner];
    }
    return state;
}

+ (void)setValues:(NSDictionary<NSString *, id> *)values on:(NSObject *)object owner:(NSObject *)owner {
    if (!object || !owner) return;
    for (NSString *key in values) {
        id desired = values[key];
        id current = [object valueForKeyPath:key] ?: NSNull.null;
        XHSNativeViewState *state = [self stateForOwner:owner create:NO];
        NSMutableDictionary *properties = [state.changes objectForKey:object];
        NSMutableDictionary *change = properties[key];
        if (change && ![current isEqual:change[@"applied"]]) change[@"original"] = current;
        if ([current isEqual:desired]) continue;
        if (!state) state = [self stateForOwner:owner create:YES];
        if (!properties) {
            properties = [NSMutableDictionary dictionary];
            [state.changes setObject:properties forKey:object];
        }
        if (!change) {
            change = [@{@"original": current} mutableCopy];
            properties[key] = change;
        }
        [object setValue:desired == NSNull.null ? nil : desired forKeyPath:key];
        change[@"applied"] = [object valueForKeyPath:key] ?: NSNull.null;
    }
}

+ (void)restoreProperties:(NSArray<NSString *> *)properties on:(NSObject *)object owner:(NSObject *)owner {
    XHSNativeViewState *state = [self stateForOwner:owner create:NO];
    if (!object || !state) return;
    NSMutableDictionary *changes = [state.changes objectForKey:object];
    for (NSString *key in properties) {
        NSDictionary *change = changes[key];
        if (!change) continue;
        id current = [object valueForKeyPath:key] ?: NSNull.null;
        if ([current isEqual:change[@"applied"]]) {
            id original = change[@"original"];
            [object setValue:original == NSNull.null ? nil : original forKeyPath:key];
        }
        [changes removeObjectForKey:key];
    }
    if (!changes.count) [state.changes removeObjectForKey:object];
}

+ (void)addDecoration:(NSObject *)decoration owner:(NSObject *)owner {
    if (decoration) [[[self stateForOwner:owner create:YES] decorations] addObject:decoration];
}

+ (void)restoreOwner:(NSObject *)owner {
    XHSNativeViewState *state = [self stateForOwner:owner create:NO];
    if (!state) return;
    for (NSObject *object in state.changes.keyEnumerator.allObjects) {
        NSArray *properties = [[state.changes objectForKey:object] allKeys];
        // frame 恢复前先恢复 transform，避免非单位变换下写 frame。
        if ([properties containsObject:@"transform"]) [self restoreProperties:@[@"transform"] on:object owner:owner];
        [self restoreProperties:properties on:object owner:owner];
    }
    for (NSObject *decoration in state.decorations.allObjects) [decoration setValue:@YES forKey:@"hidden"];
    objc_setAssociatedObject(owner, &kViewStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[self ownerTable] removeObject:owner];
}

+ (NSArray<NSObject *> *)owners {
    return [self ownerTable].allObjects;
}

@end
