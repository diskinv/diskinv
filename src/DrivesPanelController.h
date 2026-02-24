//
//  DrivesPanelController.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on 15.11.04.
//
//  Copyright (C) 2004 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import <Cocoa/Cocoa.h>


@interface DrivesPanelController : NSObject
{
	NSMutableArray *_volumes;
	NSMutableArray *_progressIndicators;
	IBOutlet NSTableView* _volumesTableView;
	IBOutlet NSWindow* _volumesPanel;
	IBOutlet NSButton* _openVolumeButton;
	IBOutlet NSArrayController *_volumesController;
    
    unsigned long long _maxVolumeSize; // size of largest volumes
}

+ (DrivesPanelController*) sharedController;

- (BOOL) panelIsVisible;
- (void) showPanel;
- (NSWindow*) panel;

- (NSArray*) volumes;

- (IBAction) openVolume:(id)sender;

@end
