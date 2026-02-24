//
//  NSView-BackingCoordsHelpers.m
//  TreeMapView
//
//  Created by Tjark Derlien on 12.02.19.
//

#import "NSView-BackingCoordsHelpers.h"

@implementation NSView (BackingCoordsHelpers)

- (NSPoint) convertPointToBackingRespectingFlipped: (NSPoint)point
{
    point = [self convertPointToBacking:point];
    if ( [self isFlipped] )
        point.y *= -1;
    
    return point;
}

- (NSPoint) convertPointFromBackingRespectingFlipped: (NSPoint)point
{
    point = [self convertPointFromBacking:point];
    if ( [self isFlipped] )
        point.y *= -1;
    
    return point;
}

- (NSSize)convertSizeToBackingRespectingFlipped:(NSSize)size
{
    // no need for special handling flipped views here
    return [self convertSizeToBacking:size];
}

- (NSSize)convertSizeFromBackingRespectingFlipped:(NSSize)size
{
    // no need for special handling flipped views here
    return [self convertSizeFromBacking:size];
}

- (NSRect)convertRectToBackingRespectingFlipped:(NSRect)rect
{
    rect.origin = [self convertPointToBackingRespectingFlipped: rect.origin];
    rect.size = [self convertSizeToBackingRespectingFlipped: rect.size];
    
    return rect;
}

- (NSRect)convertRectFromBackingRespectingFlipped:(NSRect)rect
{
    rect.origin = [self convertPointFromBackingRespectingFlipped: rect.origin];
    rect.size = [self convertSizeFromBackingRespectingFlipped: rect.size];
    
    return rect;
}


@end
