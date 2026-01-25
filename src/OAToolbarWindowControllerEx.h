//
//  OAToolbarWindowControllerEx.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on 01.12.04.
//
//  Copyright (C) 2004 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import <Cocoa/Cocoa.h>
#import <OmniAppKit/OAToolbarWindowController.h>

@interface NSToolbarItemValidationAdapter : NSObject
{
	NSToolbarItem* _toolbarItem;
}

- (void) setToolbarItem: (NSToolbarItem*) toolbarItem;
- (void) forwardInvocation: (NSInvocation*) anInvocation;

@end

@interface OAToolbarWindowControllerEx : OAToolbarWindowController {

}

- (NSImage*) toolbar: (NSToolbar*) theToolbar imageForToolbarItem: (NSToolbarItem*) item forState: (int) state;

// properties to resolve "target" value for tool items
@property (readonly) NSDocumentController *documentController;
@property (readonly) NSApplication *application;

@end
