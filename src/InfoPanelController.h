//
//  InfoPanelController.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on 16.11.04.
//
//  Copyright (C) 2004 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import <Cocoa/Cocoa.h>
#import "FSItem.h"

@class DIXFileInfoView;

@interface InfoPanelController : NSObject
{
	IBOutlet DIXFileInfoView *_infoView;
	IBOutlet NSWindow* _infoPanel;
	IBOutlet NSTextField* _displayNameTextField;
	IBOutlet NSImageView* _iconImageView;
}

+ (InfoPanelController*) sharedController;

- (BOOL) panelIsVisible;
- (void) showPanel;
- (void) hidePanel;
- (void) showPanelWithFSItem: (FSItem*) fsItem;
- (NSWindow*) panel;

@end
