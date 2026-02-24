//
//  NSMutableArray+DIXExtensions.h
//  Disk Inventory X
//
//  Replacement for OmniFoundation NSMutableArray-OFExtensions
//

#import <Foundation/Foundation.h>

@interface NSMutableArray (DIXExtensions)
- (void)insertObject:(id)object inArraySortedUsingSelector:(SEL)selector;
@end
