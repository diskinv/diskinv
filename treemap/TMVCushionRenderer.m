//
//  TMVCushionRenderer.m
//  Disk Accountant
//
//  Created by Tjark Derlien on Sun Oct 12 2003.
//  Copyright (c) 2003 Tjark Derlien. All rights reserved.
//

#import "TMVCushionRenderer.h"

#ifdef __ppc__
#import <ppc_intrinsics.h>	//special PowerPC (603+) instructions
#endif //__ppc__

#define MAX_RGB_VALUE 1.0f

NSColor *g_defaultCushionColor = nil;
SEL g_renderFunction;	//optimized rendering function depending on processor features

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
	[g_defaultCushionColor retain];
	
	//determine optimal rendering function
	g_renderFunction = @selector(renderCushionInBitmapGeneric:);
	
	//query for the existance of PPC603's square root functions (frsqrte)
#ifdef __ppc__
	long gestaltValue = 0;
	OSErr result = Gestalt( gestaltPowerPCProcessorFeatures, &gestaltValue );
	if ( result == 0 && ( gestaltValue & gestaltPowerPCHasSquareRootInstructions ) != 0 )
		g_renderFunction = @selector(renderCushionInBitmapPPC603Single:);
#endif //__ppc__
}

- (id) init
{
    self = [super init];

	//_color will be release in setColor, so retain it allthough g_defaultCushionColor is a global variable
    _color = [g_defaultCushionColor retain]; 

    memset( _surface, 0, sizeof(_surface) );

    _rect = NSZeroRect;

    return self;
}

- (id) initWithRect: (NSRect) rect
{
    [self init];

    _rect = rect;

    return self;
}

- (void) dealloc
{
    [_color release];

    [super dealloc];
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
	if ( ![[newColor colorSpaceName] isEqualToString: NSCalibratedRGBColorSpace] )
		newColor = [newColor colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
	
    [newColor retain];
    [_color release];

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
	NSAssert( g_renderFunction != nil, @"no render function set" );

	[self performSelector: g_renderFunction withObject: bitmap];
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

#ifdef __ppc__
//PowerPC optimzed version (603+)
//double precision (double)
- (void) renderCushionInBitmapPPC603: (NSBitmapImageRep*) bitmap
{
	NSRect rect = [self rect];
	
    const float *surface = [self surface];
	const double surface3 = surface[3];
	const double surface2 = surface[2];
	
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
    static const double lx = -1.0;		// negative = left
    static const double ly = -1.0;		// negative = top
    static const double lz = 10.0;
	
    // Derived parameters
    const double Is = 1.0 - Ia;	// brightness
	
    const double len = sqrt(lx*lx + ly*ly + lz*lz);
    const double Lx = lx / len;
    const double Ly = lx / len;
    const double Lz = lz / len;
	
	//some frequently accessed values to speed up the loop
    const float colR = [baseColor redComponent];
    const float colG = [baseColor greenComponent];
    const float colB = [baseColor blueComponent];
	
    unsigned char *pixels = [bitmap bitmapData];
    int bytesPerRow = [bitmap bytesPerRow];
	
	const double nxFactor = 2.0f * surface[0];
	const double nyFactor = 2.0f * surface[1];
	
    int ix, iy;
	int yStart = NSMinY(rect);
	int yEnd = NSMaxY(rect);
	int xStart = NSMinX(rect);
	int xEnd = NSMaxX(rect);
    
    for ( iy = yStart; iy < yEnd ; iy++)
    {
        unsigned char *rowStart = pixels + iy * bytesPerRow;
		const double ny = -(nyFactor * (iy + 0.5) + surface3);
		
        for ( ix = xStart ; ix < xEnd ; ix++)
        {
            const double nx = -(nxFactor * (ix + 0.5) + surface2);
			
			//we use a special PowerPC version of sqrt
			//frsqrte is a reciprocal SQRT estimation function on PPC 603 and later processors
			//(frsqrte = 1/sqrt)
			//generic code: double cosa = (nx*Lx + ny*Ly + Lz) / sqrt(nx*nx + ny*ny + 1.0);
			double sqrtParam = nx*nx + ny*ny + 1.0;
			double cosa = __frsqrte( sqrtParam );
			//Due to the lack of frsqrte's accuracy, we improve the result with Newton-Raphson.
			//One iteration is enough on a G4 so one won't see any difference looking at a cushion 1000x800 pixels
			//rendered with frsqrte (PPC) or sqrt (generic).
			cosa = 0.5 * cosa * (3.0 - sqrtParam * cosa * cosa);
			cosa *= nx*Lx + ny*Ly + Lz;
			
            double brightness = Is * cosa;
            brightness = brightness < 0 ? Ia : (brightness + Ia);
			
			//another consequence of frsqrte: brightness may be greater than 1, which isn't allowed (with sqrt this won't be ever the case)
			if ( brightness > 1 )
				brightness = 1;
			
			brightness *= 2.5 / BASE_BRIGHTNESS;

            CGFloat red = colR * brightness;
            CGFloat green = colG * brightness;
            CGFloat blue = colB * brightness;
			
            [TMVCushionRenderer normalizeColorRed: &red green: &green blue: &blue];
			
            unsigned char *pixel = rowStart + (ix*3);
			
            *pixel = (unsigned char) (red * 255);
            pixel[1] = (unsigned char) (green * 255);
            pixel[2] = (unsigned char) (blue * 255);
        }
    }
}
#endif //__ppc__

#ifdef __ppc__
//PowerPC optimzed version (603+)
//single precision (float)
- (void) renderCushionInBitmapPPC603Single: (NSBitmapImageRep*) bitmap;
{
	NSRect rect = [self rect];
	
    const float *surface = [self surface];
	const float surface3 = surface[3];
	const float surface2 = surface[2];
	
    NSColor *baseColor = [self color];
	
    //we're expecting a bitmap which is at least as big as our rectangle,
    //has a 24 Bit color depth in RGB space (3 * 8 bytes) with no alpha channel
    NSAssert( NSMaxY(rect) <= [bitmap pixelsHigh], @"_rect exeeds bitmap height" );
    NSAssert( NSMaxX(rect) <= [bitmap pixelsWide], @"_rect exeeds bitmap width" );
    NSAssert( [bitmap bitsPerSample] == 8, @"expecting bitmap to have 8 bits per RGB component");
    NSAssert( ![bitmap hasAlpha], @"not expecting the bitmap to have alpha component");
	
    // Cushion parameters
    const float Ia = 0.15f;  //ambient light
	
    // where is the light:
    static const float lx = -1.0f;		// negative = left
    static const float ly = -1.0f;		// negative = top
    static const float lz = 10.0f;
	
    // Derived parameters
    const float Is = 1.0f - Ia;	// brightness
	
    const float len = sqrt(lx*lx + ly*ly + lz*lz);
    const float Lx = lx / len;
    const float Ly = lx / len;
    const float Lz = lz / len;
	
	//some frequently accessed values to speed up the loop
    const float colR = [baseColor redComponent];
    const float colG = [baseColor greenComponent];
    const float colB = [baseColor blueComponent];
	
    unsigned char *pixels = [bitmap bitmapData];
    int bytesPerRow = [bitmap bytesPerRow];
	
	const float nxFactor = 2.0f * surface[0];
	const float nyFactor = 2.0f * surface[1];
	
    int ix, iy;
	float fix, fiy;
	int yEnd = NSMaxY(rect);
	int xStart = NSMinX(rect);
	int xEnd = NSMaxX(rect);
	
    for ( iy = fiy = NSMinY(rect); iy < yEnd ; iy++, fiy++)
    {
        unsigned char *rowStart = pixels + iy * bytesPerRow;
		const float ny = -(nyFactor * (fiy + 0.5f) + surface3);
		
        for ( ix = xStart, fix = NSMinX(rect); ix < xEnd ; ix++, fix++)
        {
            const float nx = -(nxFactor * (fix + 0.5f) + surface2);
			
			//we use a special PowerPC version of sqrt
			//frsqrte is a reciprocal SQRT estimation function on PPC 603 and later processors
			//(frsqrte = 1/sqrt)
			const register float sqrtParam = nx*nx + ny*ny + 1.0f;
			register float cosa = __frsqrtes( sqrtParam );
			//Due to the lack of frsqrte's accuracy, we improve the result with some Newton-Raphson iterations (noticibly better!)
			cosa *= 1.5f - 0.5f * sqrtParam * cosa * cosa;
			cosa *= nx*Lx + ny*Ly + Lz;
			
            float brightness = Is * cosa;
            brightness = brightness < 0 ? Ia : (brightness + Ia);
			
			//another consequence of frsqrte: brightness may be greater than 1, which isn't allowed (with sqrt this won't be ever the case)
			if ( brightness > 1 )
				brightness = 1;
			
			brightness *= 2.5f / BASE_BRIGHTNESS;
			
            CGFloat red = colR * brightness;
            CGFloat green = colG * brightness;
            CGFloat blue = colB * brightness;
			
            [TMVCushionRenderer normalizeColorRed: &red green: &green blue: &blue];
			
            unsigned char *pixel = rowStart + ( ix * 3 );
			
            *pixel = (unsigned char) (red * 255.0f);
            pixel[1] = (unsigned char) (green * 255.0f);
            pixel[2] = (unsigned char) (blue * 255.0f);
        }
    }
}
#endif //__ppc__

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
	if ( ![[color colorSpaceName] isEqualToString: NSCalibratedRGBColorSpace] )
		color = [color colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
	
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
