//
//  NSBitmapImageRep-Extensions.m
//  TreeMapView
//
//  Created by Tjark Derlien on 20.10.04.
//  Copyright 2004 Tjark Derlien. All rights reserved.
//

#import "NSBitmapImageRep-CreationExtensions.h"

@implementation NSBitmapImageRep (CreationExtensions)

//creates a bitmap image rep with size and scaling factor of the view
+ (NSBitmapImageRep*) imageRepCompatibleWithView: (NSView*) view
{
    NSRect viewBounds = [view bounds];
    NSSize sizePoints = viewBounds.size;
    NSSize sizePixel = [view convertSizeToBacking:sizePoints];
    
    NSBitmapImageRep *imgRep = [[NSBitmapImageRep alloc] initRGBBitmapWithWidth: sizePixel.width
                                                                         height: sizePixel.height];
    [imgRep autorelease];
    
    // Setting the user size communicates the dpi
    [imgRep setSize:sizePoints];

    // set color space
    if ( [view window] != nil )
    {
        // retag image rep with window's color space
        // (we have to do that after the creation as there is no color space constant for the sRGB space)
        NSColorSpace *colorSpace = [[view window] colorSpace];
        if ( colorSpace != nil )
        {
            NSBitmapImageRep *imgRepWithCorrectCS = [imgRep bitmapImageRepByRetaggingWithColorSpace: colorSpace];
            if ( imgRepWithCorrectCS != nil )
                imgRep = imgRepWithCorrectCS;
        }
    }

    return imgRep;
}

//creates a Bitmap with 24 bit color depth and no alpha component
- (id) initRGBBitmapWithWidth: (NSInteger) width height: (NSInteger) height
{
    return [self initWithBitmapDataPlanes: NULL    // Let the class allocate it
                               pixelsWide: width
                               pixelsHigh: height
                            bitsPerSample: 8       // Each component is 8 bits (one byte)
                          samplesPerPixel: 3       // Number of components (R, G, B, no alpha)
                                 hasAlpha: NO
                                 isPlanar: NO
                           colorSpaceName: NSCalibratedRGBColorSpace
                              bytesPerRow: 0       // 0 means: Let the class figure it out
                             bitsPerPixel: 0];     // 0 means: Let the class figure it out
}

//creates an autoreleased NSImage with the same dimensions as the NSBitmapImageRep
//and adds the NSBitmapImageRep as the only image represensation
- (NSImage*) suitableImageForView: (NSView*) view
{
    NSSize size = [self size];
    NSImage *image = [[NSImage alloc] initWithSize: size];
	
    [image addRepresentation: self];
	
	return [image autorelease];
}

@end
