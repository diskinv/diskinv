//
//  SelectionListController.h
//  Disk Inventory X
//
//	This class implements the ArrayController for the collection of files
//	to show in the NSTableView.
//	It is also the delegate for the search field and does the filtering defined
//	the entered serach string.
//
//  Created by Tjark Derlien on 31.03.05.
//
//  Copyright (C) 2005 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import <Cocoa/Cocoa.h>
#import "GenericArrayController.h"
#import "FileSystemDoc.h"
#import "FSItemIndex.h"

@interface SelectionListController : GenericArrayController
{
	IBOutlet NSProgressIndicator *_progressIndicator;
	IBOutlet NSWindowController *_windowController;
	IBOutlet GenericArrayController *_kindsPopupController;
	IBOutlet NSSearchField *_searchField;
    NSString *_serachString;
	NSMutableDictionary *_indexes;
	FSItemIndexType _indexToSearch;
}

- (FileSystemDoc*) document;

- (IBAction) search: (id)sender;
- (NSString*) searchString;
- (void) setSearchString: (NSString*) newSearchString;

- (IBAction) searchInAll: (id) sender;
- (IBAction) searchInNames: (id) sender;
- (IBAction) searchInKindNames: (id) sender;
- (IBAction) searchInPaths: (id) sender;

@end
