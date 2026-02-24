//
//  InfoPanelController.m
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

#import "InfoPanelController.h"
#import "DIXFileInfoView.h"

@implementation InfoPanelController

+ (InfoPanelController*) sharedController
{
	static InfoPanelController *controller = nil;
	
	if ( controller == nil )
		controller = [[InfoPanelController alloc] init];
	
	return controller;
}

- (id) init
{
	self = [super init];
		
	//load Nib with info panel
    if ( ![NSBundle loadNibNamed: @"InfoPanel" owner: self] )
	{
		[self release];
		self = nil;
	}
	else
	{
		/*
		NSRect frameRect = [_infoView frame];
		
		[_infoView removeFromSuperviewWithoutNeedingDisplay];
		
		_infoView = [[DIXFileInfoView alloc] initWithFrame: frameRect longFormat: YES];
		[_infoView autorelease];
		
		[_infoView setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
		
		[[_infoPanel contentView] addSubview: _infoView];
		 */
	}
	
	return self;
}

- (void) dealloc
{	
    [super dealloc];
}

- (BOOL) panelIsVisible
{
	return [[self panel] isVisible];
}

- (void) showPanel
{
	[[self panel] orderFront: nil];
}

- (void) hidePanel
{
	[[self panel] orderOut: nil];
}

- (NSWindow*) panel
{
	return _infoPanel;
}

- (void) showPanelWithFSItem: (FSItem*) fsItem
{
	[self showPanel];
	
	if ( fsItem == nil || [fsItem fileURL] == nil)
	{
		[_displayNameTextField setStringValue: @""];
		[_iconImageView setImage: nil];

		[_infoView setURL: nil];
	}
	else if ( [_infoView URL] == nil
             || ![[fsItem fileURL] isEqualToURL: [_infoView URL]] )
	{
		[_displayNameTextField setStringValue: [fsItem displayName]];
		[_iconImageView setImage: [fsItem iconWithSize: 32]];
        
        [_infoView setURL: [fsItem fileURL]];
	}
}

@end
