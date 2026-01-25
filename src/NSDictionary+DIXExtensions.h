//
//  NSDictionary+DIXExtensions.h
//  Disk Inventory X
//
//  Replacement for OmniFoundation NSDictionary-OFExtensions
//

#import <Foundation/Foundation.h>

@interface NSDictionary (DIXExtensions)

- (BOOL)boolForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (int)intForKey:(NSString *)key;
- (int)intForKey:(NSString *)key defaultValue:(int)defaultValue;
- (float)floatForKey:(NSString *)key;
- (float)floatForKey:(NSString *)key defaultValue:(float)defaultValue;

@end

@interface NSMutableDictionary (DIXExtensions_Mutable)

- (void)setBoolValue:(BOOL)value forKey:(NSString *)key;
- (void)setIntValue:(int)value forKey:(NSString *)key;
- (void)setFloatValue:(float)value forKey:(NSString *)key;

@end
