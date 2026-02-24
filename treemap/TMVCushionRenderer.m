//
//  TMVCushionRenderer.m
//  Disk Accountant
//
//  Created by Tjark Derlien on Sun Oct 12 2003.
//  Copyright (c) 2003 Tjark Derlien. All rights reserved.
//

#import "TMVCushionRenderer.h"

#define MAX_RGB_VALUE 1.0f

static NSColor *g_defaultCushionColor = nil;

//================ interface TMVCushionRenderer(Private) ======================================================

@interface TMVCushionRenderer(Private)

+ (void) distributeRGB1: (CGFloat*) first toRGB2: (CGFloat*) second toRGB3: (CGFloat*) third;

@end


//================ implementation TMVCushionRenderer ======================================================

@implementation TMVCushionRenderer

+ (void) initialize
{
	//set default cushion color
	g_defaultCushionColor = [NSColor colorWithCalibratedRed: 0 green: 0 blue: 0.9 alpha: 1];
	g_defaultCushionColor = [TMVCushionRenderer normalizeColor: g_defaultCushionColor];
}

- (id) init
{
    self = [super init];

    _color = g_defaultCushionColor;

    memset( _surface, 0, sizeof(_surface) );

    _rect = NSZeroRect;

    return self;
}

- (id) initWithRect: (NSRect) rect
{
    self = [self init];

    _rect = rect;

    return self;
}

- (NSRect) rect
{
    return _rect;
}

- (void) setRect: (NSRect) rect
{
    _rect = rect;
}

- (NSColor*) color
{
    return _color;
}

- (void) setColor: (NSColor*) newColor
{
	//we need the color in the RGB color space
	NSColor *rgbColor = [newColor colorUsingColorSpace: [NSColorSpace sRGBColorSpace]];
	if (rgbColor != nil)
		newColor = rgbColor;

    _color = newColor;
}

- (CGFloat*) surface
{
    return _surface;
}

- (void) setSurface: (const CGFloat*) newsurface
{
    memcpy( _surface, newsurface, sizeof(_surface) );
}


- (void) addRidgeByHeightFactor: (float) heightFactor
{
    /*
Unoptimized:

     if (rc.Width() > 0)
     {
         surface[2]+= 4 * h * (rc.right + rc.left) / (rc.right - rc.left);
         surface[0]-= 4 * h / (rc.right - rc.left);
     }

     if (rc.Height() > 0)
     {
         surface[3]+= 4 * h * (rc.bottom + rc.top) / (rc.bottom - rc.top);
         surface[1]-= 4 * h / (rc.bottom - rc.top);
     }
     */

    // Optimized (gains 15 ms of 1030):

    CGFloat h4= 4 * heightFactor;

    CGFloat wf= h4 / NSWidth(_rect);
    _surface[2]+= wf * ( NSMaxX(_rect) + NSMinX(_rect) );
    _surface[0]-= wf;

    CGFloat hf= h4 / NSHeight(_rect);
    _surface[3]+= hf * ( NSMaxY(_rect) + NSMinY(_rect) );
    _surface[1]-= hf;
}

- (void) renderCushionInBitmap: (NSBitmapImageRep*) bitmap
{
	[self renderCushionInBitmapGeneric: bitmap];
}

- (void) renderCushionInBitmapGeneric: (NSBitmapImageRep*) bitmap
{
    NSRect rect = [self rect];
    const CGFloat *surface = [self surface];
    NSColor *baseColor = [self color];

    //we're expecting a bitmap which is at least as big as our rectangle,
    //has a 24 Bit color depth in RGB space (3 * 8 bytes) with no alpha channel
    NSAssert( NSMaxY(rect) <= [bitmap pixelsHigh], @"_rect exeeds bitmap height" );
    NSAssert( NSMaxX(rect) <= [bitmap pixelsWide], @"_rect exeeds bitmap width" );
    NSAssert( [bitmap bitsPerSample] == 8, @"expecting bitmap to have 8 bits per RGB component");
    NSAssert( ![bitmap hasAlpha], @"not expecting the bitmap to have alpha component");

    // Cushion parameters
    const double Ia = 0.15;  //ambient light

    // where is the light:
    static const double lx = -1;		// negative = left
    static const double ly = -1;		// negative = top
    static const double lz = 10;

    // Derived parameters
    const double Is = 1 - Ia;	// brightness

    const double len = sqrt(lx*lx + ly*ly + lz*lz);
    const double Lx = lx / len;
    const double Ly = lx / len;
    const double Lz = lz / len;

    const CGFloat colR = [baseColor redComponent];
    const CGFloat colG = [baseColor greenComponent];
    const CGFloat colB = [baseColor blueComponent];

    unsigned char *pixels = [bitmap bitmapData];
    NSInteger bytesPerRow = [bitmap bytesPerRow];
	
    int ix, iy;
	int yStart = NSMinY(rect);
	int yEnd = NSMaxY(rect);
	int xStart = NSMinX(rect);
	int xEnd = NSMaxX(rect);
    
    for ( iy = yStart; iy < yEnd ; iy++)
    {
        unsigned char *rowStart = pixels + iy * bytesPerRow;
		const double ny = -(2 * surface[1] * (iy + 0.5) + surface[3]);

        for ( ix = xStart ; ix < xEnd ; ix++)
        {
            const double nx = -(2 * surface[0] * (ix + 0.5) + surface[2]);
			
            double cosa = (nx*Lx + ny*Ly + Lz) / sqrt(nx*nx + ny*ny + 1.0);
			
            double brightness = Is * cosa;
            brightness = brightness < 0 ? Ia : (brightness + Ia);

            NSAssert(brightness <= 1.0, @"brightness must be <=1" );

            brightness *= 2.5 / BASE_BRIGHTNESS;

            CGFloat red = colR * brightness;
            CGFloat green = colG * brightness;
            CGFloat blue = colB * brightness;

            [TMVCushionRenderer normalizeColorRed: &red green: &green blue: &blue];

            /*
             //with QuickDraw, this would be simplier:
             //QuickDraw RGB components are in the range 0..65535
             RGBColor pixelColor;
             pixelColor.red = (unsigned short) (red * 65535);
             pixelColor.green = (unsigned short) (green * 65535);
             pixelColor.blue = (unsigned short) (blue * 65535);

             SetCPixel( ix, iy, &pixelColor);
             */

            unsigned char *pixel = rowStart + (ix*3);

            *pixel = (unsigned char) (red * 255);
            pixel[1] = (unsigned char) (green * 255);
            pixel[2] = (unsigned char) (blue * 255);
        }
    }
}

+ (void) normalizeColorRed: (CGFloat*) red green: (CGFloat*) green blue: (CGFloat*) blue
{
	//This eats 50% of function time
    //NSAssert(*red + *green + *blue <= 3.0 * MAX_RGB_VALUE, @"color error");

    if (*red > MAX_RGB_VALUE)
    {
        [TMVCushionRenderer distributeRGB1: red toRGB2: green toRGB3: blue];
    }
    else if (*green > MAX_RGB_VALUE)
    {
        [TMVCushionRenderer distributeRGB1: green toRGB2: red toRGB3: blue];
    }
    else if (*blue > MAX_RGB_VALUE)
    {
        [TMVCushionRenderer distributeRGB1: blue toRGB2: red toRGB3: green];
    }
}

+ (NSColor*) normalizeColor: (NSColor*) color
{
	//we need the color in the RGB color space
	NSColor *rgbColor = [color colorUsingColorSpace: [NSColorSpace sRGBColorSpace]];
	if (rgbColor != nil)
		color = rgbColor;

    CGFloat red = [color redComponent];
    CGFloat green = [color greenComponent];
    CGFloat blue = [color blueComponent];

    CGFloat alpha = [color alphaComponent];

	CGFloat componentSum = red + green + blue;
    CGFloat f= (componentSum != 0.0) ? (BASE_BRIGHTNESS / componentSum) : 1;
    red *= f;
    green *= f;
    blue *= f;

    [TMVCushionRenderer normalizeColorRed: &red green: &green blue: &blue ];

    return [NSColor colorWithCalibratedRed: red green: green blue: blue alpha: alpha];
}

@end


//================ implementation TMVCushionRenderer(Private) ======================================================

@implementation TMVCushionRenderer(Private)

+ (void) distributeRGB1: (CGFloat*) first toRGB2: (CGFloat*) second toRGB3: (CGFloat*) third
{
    CGFloat h = (*first - MAX_RGB_VALUE) / 2.0f;
    *first = MAX_RGB_VALUE;
    *second += h;
    *third += h;

    if (*second > MAX_RGB_VALUE)
    {
        h = *second - MAX_RGB_VALUE;
        *second = MAX_RGB_VALUE;
        *third+= h;
        NSAssert(*third <= MAX_RGB_VALUE, @"color error" );
    }
    else if (*third > MAX_RGB_VALUE)
    {
        h = *third - MAX_RGB_VALUE;
        *third = MAX_RGB_VALUE;
        *second += h;
        NSAssert(*second <= MAX_RGB_VALUE, @"color error");
    }
}

@end
