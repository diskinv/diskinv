//
//  FSItemIndex.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on 01.04.05.
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

typedef enum
{
	FSItemIndexName = 1,
	FSItemIndexKind = 2,
	FSItemIndexPath = 4,
	FSItemIndexAll = 0xffff
} FSItemIndexType;

//this class let search FSItems by their display names, kinds and path
//(I implemented this with SearchKit, but it is so damn slow that I replaced it with
//a stupid simple but still faster implementation)
@interface FSItemIndex : NSObject
{
	NSMutableDictionary *_displayNameIndex;
	NSMutableDictionary *_displayFolderIndex;
	NSDictionary *_kindStatistics;
	
/*	NSMutableDictionary *_indexedItems;
	
	SKIndexRef _kindNameIndex;
	SKIndexRef _displayNameIndex;
	SKSearchGroupRef _searchGroupAll;
	*/
}

- (id) initWithKindStatistics: (NSDictionary*) kindStatistics;

- (void) addItem: (FSItem*) item;
- (void) addItemsFromArray: (NSArray*) items;

- (NSArray*) searchItems: (NSString*) searchString inIndex: (FSItemIndexType) indexesToSearch;

@end
