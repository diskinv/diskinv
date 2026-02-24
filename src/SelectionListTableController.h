//
//  SelectionListTableController.h
//  Disk Inventory X
//
//	This class implemented the controller/delagte for the NSTableView
//	in the selection list drawer.
//	It also listens for and handles various notifications and KVO events
//	regarding opening/closing of the drawer, option changes (font sizes) and
//	document selection.
//
//  Created by Tjark Derlien on 25.03.05.
//
//  Copyright (C) 2005 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import <Cocoa/Cocoa.h>
#import "FileSystemDoc.h"
#import "GenericArrayController.h"
#import "MainWindowController.h"
#import "FileKindsPopupController.h"

@interface SelectionListTableController : NSObject
{
    IBOutlet NSTableView *_tableView;
    IBOutlet MainWindowController *_windowController;
	IBOutlet GenericArrayController *_selectionListArrayController;
	IBOutlet FileKindsPopupController *_kindStatisticsArrayController;
}

- (FileSystemDoc*) document;

@end
