//
//  NSView-BackingCoordsHelpers.h
//  TreeMapView
//
//  Created by Tjark Derlien on 12.02.19.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSView (BackingCoordsHelpers)

/* the NSView methods convertXXXToBacking and convertXXXFromBacking have problems with flipped views*/

- (NSPoint) convertPointToBackingRespectingFlipped: (NSPoint)point;
- (NSPoint) convertPointFromBackingRespectingFlipped: (NSPoint)point;
- (NSSize) convertSizeToBackingRespectingFlipped: (NSSize)size;
- (NSSize) convertSizeFromBackingRespectingFlipped: (NSSize)size;
- (NSRect) convertRectToBackingRespectingFlipped:(NSRect)rect;
- (NSRect) convertRectFromBackingRespectingFlipped: (NSRect)rect;


@end

NS_ASSUME_NONNULL_END
