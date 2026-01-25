//
//  ZoomInfo.m
//  TreeMapView
//
//  Created by Tjark Derlien on 30.11.04.
//  Copyright 2004 Tjark Derlien. All rights reserved.
//

#import "ZoomInfo.h"

@interface NSApplication(Omni)
- (BOOL) checkForModifierFlags:(unsigned int)flags;
@end

@implementation ZoomInfo

- (id) initWithImage: (NSImage*) image
			delegate: (id) delegate
			selector: (SEL) selector
{
	self = [super init];
	
	_image = [image retain];
	
	_delegate = delegate;
	_delegateSelector = selector;
	NSAssert( [delegate respondsToSelector: selector], @"delegate doesn't respond to given selector" );
	
	_leftStep = _topStep = _rightStep = _bottomStep = 0;
	_rect = NSZeroRect;
	
	return self;
}

- (void) calculateZoomFromRect: (NSRect) startRect toRect: (NSRect) endRect
{
	//if the shift key is down, we slow the zoom effect down (like e.g. the dock)
	//(To determine this ([[NSApp currentEvent] modifierFlags] & NSShiftKeyMask)
	//should do it, but it don't. So ask OAApplication, if present)
	BOOL shiftKeyPressed = NO;
	if ( [NSApp respondsToSelector: @selector(checkForModifierFlags:) ] )
		 shiftKeyPressed = [NSApp checkForModifierFlags: NSShiftKeyMask];
    
	BOOL zoomIn = NSContainsRect( endRect, startRect );
	
	_rect = zoomIn ? endRect: startRect;
	
	float maxPixelToZoom = fmaxf( fabs( NSWidth(endRect) - NSWidth(startRect) ),
								  fabs( NSHeight(endRect) - NSHeight(startRect) ) );
	
	float zoomStepCount = maxPixelToZoom / (shiftKeyPressed ? 10.0 : 40.0);
	
	float zoomFactorX = zoomIn ? NSWidth(endRect) / NSWidth(startRect)	: NSWidth(startRect) / NSWidth(endRect);
	float zoomFactorY = zoomIn ? NSHeight(endRect) / NSHeight(startRect): NSHeight(startRect) / NSHeight(endRect);
	
	_leftStep = ( NSMinX(startRect) - NSMinX(endRect) ) / zoomStepCount * zoomFactorX;
	_topStep = ( NSMinY(startRect) - NSMinY(endRect) ) / zoomStepCount * zoomFactorY;
	_rightStep = ( NSMaxX(endRect) - NSMaxX(startRect) ) / zoomStepCount * zoomFactorX;
	_bottomStep = ( NSMaxY(endRect) - NSMaxY(startRect) ) / zoomStepCount * zoomFactorY;
	
	if ( !zoomIn )
	{
		_rect.origin.x += _leftStep * zoomStepCount;
		_rect.origin.y += _topStep * zoomStepCount;
		_rect.size.width -= (_rightStep + _leftStep) * zoomStepCount;
		_rect.size.height -= (_bottomStep + _topStep) * zoomStepCount;
	}
	
	_zoomStepsLeft = roundf( zoomStepCount );
	
	_timer = [NSTimer timerWithTimeInterval: 0.03
									 target: self
								   selector: @selector(onTimer:)
								   userInfo: nil
									repeats: YES];
	
	//run loop will retain the timer object
	[[NSRunLoop currentRunLoop] addTimer: _timer forMode: NSDefaultRunLoopMode];
}

- (void) dealloc
{
	[_image release];
	
	if ( _timer != nil && [_timer isValid] )
		[_timer invalidate]; //timer will be released by run loop
	
	_timer = nil;
	
	[super dealloc];
}


- (void) calculateNewRect
{
	_rect.origin.x -= _leftStep;
	_rect.origin.y -= _topStep;
	_rect.size.width += _rightStep + _leftStep;
	_rect.size.height += _bottomStep + _topStep;
}

- (void) onTimer: (NSTimer*) timer
{
	NSAssert( timer == _timer, @"unknown timer" );
	NSAssert( [timer isValid], @"invalid timer" );
	
	[self calculateNewRect];
	
	if ( _zoomStepsLeft > 0 )
		_zoomStepsLeft--;
	
	if ( _zoomStepsLeft <= 0 )
	{
		[_timer invalidate];
		_timer = nil; //timer will be released by run loop
	}
	
	[_delegate performSelector: _delegateSelector withObject: self];
}

- (BOOL) hasFinished
{
	return _zoomStepsLeft <= 0;
}

- (NSImage*) image;
{
	return _image;
}

- (NSRect) imageRect
{
	return _rect;
}

- (void) drawImage
{
	NSImageInterpolation currentInterpolation = [[NSGraphicsContext currentContext] imageInterpolation];
	[[NSGraphicsContext currentContext] setImageInterpolation: NSImageInterpolationLow];
	
	NSSize imageSize = [_image size];
	
	[_image drawInRect: _rect
			  fromRect: NSMakeRect( 0, 0, imageSize.width, imageSize.height )
			 operation: NSCompositeCopy
              fraction: 1/*requestedAlpha*/
        respectFlipped: YES
                 hints: nil];
	
	[[NSGraphicsContext currentContext] setImageInterpolation: currentInterpolation];
}

@end
