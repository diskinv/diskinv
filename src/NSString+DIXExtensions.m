//
//  NSString+DIXExtensions.m
//  Disk Inventory X
//
//  Replacement for OmniFoundation NSString-OFExtensions
//

#import "NSString+DIXExtensions.h"

@implementation NSString (DIXExtensions)

+ (BOOL)isEmptyString:(NSString *)string {
    return string == nil || string.length == 0;
}

@end
