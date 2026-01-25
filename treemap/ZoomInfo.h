//
//  ZoomInfo.h
//  TreeMapView
//
//  Created by Tjark Derlien on 30.11.04.
//  Copyright 2004 Tjark Derlien. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface ZoomInfo : NSObject
{
	NSImage *_image; //retained
	NSRect _rect;
	unsigned _zoomStepsLeft;
	float _leftStep, _topStep, _rightStep, _bottomStep;
	id _delegate;
	SEL _delegateSelector;
	NSTimer *_timer;
}

- (id) initWithImage: (NSImage*) image
			delegate: (id) delegate
			selector: (SEL) selector;

- (void) calculateZoomFromRect: (NSRect) startRect toRect: (NSRect) endRect;

- (NSImage*) image;
- (NSRect) imageRect;

- (void) drawImage;

- (BOOL) hasFinished;

@end
