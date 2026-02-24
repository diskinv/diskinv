//
//  NSMutableArray+DIXExtensions.m
//  Disk Inventory X
//
//  Replacement for OmniFoundation NSMutableArray-OFExtensions
//

#import "NSMutableArray+DIXExtensions.h"

@implementation NSMutableArray (DIXExtensions)

- (void)insertObject:(id)object inArraySortedUsingSelector:(SEL)selector {
    NSUInteger low = 0;
    NSUInteger high = self.count;

    while (low < high) {
        NSUInteger mid = (low + high) / 2;
        id midObject = self[mid];
        NSComparisonResult result = ((NSComparisonResult (*)(id, SEL, id))
            [object methodForSelector:selector])(object, selector, midObject);

        if (result == NSOrderedDescending) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    [self insertObject:object atIndex:low];
}

@end
