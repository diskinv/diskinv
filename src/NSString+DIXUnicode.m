//
//  NSString+DIXUnicode.m
//  Disk Inventory X
//
//  Replacement for OmniFoundation NSString-OFUnicodeCharacters
//

#import "NSString+DIXUnicode.h"

@implementation NSString (DIXUnicode)

+ (NSString *)horizontalEllipsisString {
    // Unicode horizontal ellipsis character U+2026
    return @"\u2026";
}

@end
