//
//  NSDictionary+DIXExtensions.m
//  Disk Inventory X
//
//  Replacement for OmniFoundation NSDictionary-OFExtensions
//

#import "NSDictionary+DIXExtensions.h"

@implementation NSDictionary (DIXExtensions)

- (BOOL)boolForKey:(NSString *)key {
    return [self boolForKey:key defaultValue:NO];
}

- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id value = [self objectForKey:key];
    if (value == nil) {
        return defaultValue;
    }
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return defaultValue;
}

- (int)intForKey:(NSString *)key {
    return [self intForKey:key defaultValue:0];
}

- (int)intForKey:(NSString *)key defaultValue:(int)defaultValue {
    id value = [self objectForKey:key];
    if (value == nil) {
        return defaultValue;
    }
    if ([value respondsToSelector:@selector(intValue)]) {
        return [value intValue];
    }
    return defaultValue;
}

- (float)floatForKey:(NSString *)key {
    return [self floatForKey:key defaultValue:0.0f];
}

- (float)floatForKey:(NSString *)key defaultValue:(float)defaultValue {
    id value = [self objectForKey:key];
    if (value == nil) {
        return defaultValue;
    }
    if ([value respondsToSelector:@selector(floatValue)]) {
        return [value floatValue];
    }
    return defaultValue;
}

@end

@implementation NSMutableDictionary (DIXExtensions_Mutable)

- (void)setBoolValue:(BOOL)value forKey:(NSString *)key {
    [self setObject:@(value) forKey:key];
}

- (void)setIntValue:(int)value forKey:(NSString *)key {
    [self setObject:@(value) forKey:key];
}

- (void)setFloatValue:(float)value forKey:(NSString *)key {
    [self setObject:@(value) forKey:key];
}

@end
