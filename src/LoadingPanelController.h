//
//  LoadingPanelController.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on 03.12.04.
//
//  Copyright (C) 2004 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import <Cocoa/Cocoa.h>


@interface LoadingPanelController : NSObject
{
	NSModalSession _loadingPanelModalSession;
	uint64_t _lastEventLoopRun;
	BOOL _cancelPressed;
	NSString *_message;
    IBOutlet NSTextField* _loadingTextField;
    IBOutlet NSPanel* _loadingPanel;
    IBOutlet NSProgressIndicator* _loadingProgressIndicator;
    IBOutlet NSButton* _loadingCancelButton;
}

- (id) init; //will start modal session immediately
- (id) initAsSheetForWindow: (NSWindow*) window; //will start modal session immediately

- (void) close;
- (void) closeNoModalEnd;

- (void) enableCancelButton: (BOOL) enable; //button is enabled by default
- (BOOL) cancelPressed;

- (void) startAnimation;
- (void) stopAnimation;

- (void) setMessageText: (NSString*) msg; //message will be shown next time "runEventLoop" is called
- (void) runEventLoop;

- (IBAction) cancel:(id)sender;

@end
