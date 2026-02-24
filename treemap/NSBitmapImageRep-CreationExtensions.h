//
//  NSBitmapImageRep-Extensions.h
//  TreeMapView
//
//  Created by Tjark Derlien on 20.10.04.
//  Copyright 2004 Tjark Derlien. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface NSBitmapImageRep (CreationExtensions)

//creates a bitmap image rep with size (respecting scaling factor) and color space of the view
+ (NSBitmapImageRep*) imageRepCompatibleWithView: (NSView*) view;

//creates a Bitmap with 24 bit color depth and no alpha component
- (id) initRGBBitmapWithWidth: (NSInteger) width height: (NSInteger) height;

//creates an autoreleased NSImage with the same dimensions as the NSBitmapImageRep
//and adds the NSBitmapImageRep as the only image represensation
- (NSImage*) suitableImageForView: (NSView*) view;
@end
