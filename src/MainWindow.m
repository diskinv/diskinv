//
//  MainWindow.m
//  Disk Inventory X new
//
//  Created by Tjark Derlien on 19.03.06.
//  Copyright 2006 Tjark Derlien. All rights reserved.
//

#import "MainWindow.h"
#import "MainWindowController.h"


@implementation MainWindow

// the TreeMapView now uses NSTrackingArea to receive mouseMoved-Events even when it is not first responder,
// so we do not need to propagate this event anymore
/*
- (void) mouseMoved: (NSEvent *)theEvent
{
    [super mouseMoved: theEvent];
	
	//give the treemap view a chance to handle mouseMoved events even if it's not the first responder
	if ( [self firstResponder] != _treeMapView && NSPointInRect( [theEvent locationInWindow], [_treeMapView frame]))
		[_treeMapView mouseMoved: theEvent];
}
*/

+ (void)restoreWindowWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                              state:(NSCoder *)state
                  completionHandler:(void (^)(NSWindow *, NSError *))completionHandler
{
    completionHandler(nil, nil);
}

@end
