//
//  GenericArrayController.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on 19.03.05.
//
//  Copyright (C) 2005 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import <Cocoa/Cocoa.h>

@interface GenericArrayController : NSArrayController
{
	NSArray *_cachedObjects;
	NSMutableIndexSet *_mySelectionIndexes;
	
	id _model;
	NSString *_collectionKeyPath;
	
	struct
	{
		BOOL suspendUpdates;
		BOOL arrayIsValid;
	} _updateSuspensionInfo;
}

- (BOOL) suspendingArrangedObjectsUpdates;
- (void) suspendArrangedObjectsUpdates;
- (void) resumeArrangedObjectsUpdates;

- (id) collectionModel;
	//model's array (e.g. document.content)

- (void) onSelectionChanging;
- (void) onSelectionChanged;
- (NSIndexSet*) indexesForObjects: (NSArray*) objects;

@end
