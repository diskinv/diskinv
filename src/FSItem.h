//
//  FSItem.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on Mon Sep 29 2003.
//
//  Copyright (C) 2003 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

//

extern unsigned g_fileCount;
extern unsigned g_folderCount;

@interface NSString (ComparisonAdditions)
- (NSComparisonResult) compareAsFilesystemName: (NSString*) other;
@end

typedef enum
{
	FileFolderItem, //regular file or folder
	OtherSpaceItem, //represents "other" space (that means the space occupied by the rest of the files on the volume)
	FreeSpaceItem	//free space on volume
} FSItemType;

@interface FSItem : NSObject {
	NSURL *_fileURL;
    FSItem *_parent;	//only valid for non-root items
	NSMutableDictionary *_icons; //holds icons in various sizes (see iconWithSize:)
	FSItemType _type;
    NSNumber *_size;
	UInt64 _sizeValue;
    NSString *_kindName;
    //unsigned _hash;
    NSMutableArray<FSItem*> *_childs;
	id _delegate;
}

- (id) initWithPath: (NSString *) path;
- (id) initWithURL: (NSURL *) url;

- (id) initAsOtherSpaceItemForParent: (FSItem*) parent;
- (id) initAsFreeSpaceItemForParent: (FSItem*) parent;

- (id) delegate;
- (void) setDelegate: (id) delegate;

- (FSItemType) type;
- (BOOL) isSpecialItem;

- (NSURL *) fileURL;
- (void) setFileURL: (NSURL*) url;

- (void) loadChildren;

- (NSString *) description;

- (BOOL) isFolder; //returns NO for an alias pointing to a directory (in contrast to NTFileDesc.isDirectory)
- (BOOL) isPackage;
- (BOOL) isAlias;

- (BOOL) exists;

- (BOOL) isRoot;
- (FSItem*) parent;
- (FSItem*) root;

- (NSImage*) iconWithSize: (unsigned) iconSize;

- (NSEnumerator *) childEnumerator;
- (FSItem*) childAtIndex: (unsigned) index;
- (unsigned) childCount;

- (void) removeChild: (FSItem*) child updateParent: (BOOL) updateParent; //child will be released!
- (void) insertChild: (FSItem*) newChild updateParent: (BOOL) updateParent;
- (void) replaceChild: (FSItem*) oldChild withItem: (FSItem*) newChild updateParent: (BOOL) updateParent;

- (void) recalculateSize: (BOOL) usePhysicalSize updateParent: (BOOL) updateParent;
	//just recalculates size (no file system access)

- (void) setKindString; //will ask delegate whether to ignore creator codes
- (void) setKindStringIncludingChildren: (BOOL) includingChildren;

- (NSNumber*) size;
- (unsigned long long) sizeValue;

- (NSString *) name;
- (NSString *) path;
- (NSString *) folderName;

- (NSString *) displayName;
- (NSString *) displayFolderName; //folder name relative to root item, not "/"
- (NSString *) displayPath; //path relative to root item, not "/"
- (NSString *) kindName;

- (NSComparisonResult) compareSize: (FSItem*) other;
- (NSComparisonResult) compareDisplayName: (FSItem*) other;

- (NSArray<NSPasteboardType>*) supportedPasteboardTypes;
- (BOOL) supportsPasteboardType: (NSString*) type;
- (void) writeToPasteboard: (NSPasteboard*) pasteboard;
- (void) writeToPasteboard: (NSPasteboard*) pasteboard withTypes: (NSArray*) types;

//- (unsigned) hash;
@end

/* optional delegate methods */
@interface NSObject(FSItemDelegate)
- (BOOL) fsItemEnteringFolder: (FSItem*) item; //delegate may return NO to stop loading in "loadChilds"
- (BOOL) fsItemExittingFolder: (FSItem*) item;
- (BOOL) fsItemShouldIgnoreCreatorCode: (FSItem*) item; //default is NO (if not implemented by delegate)
- (BOOL) fsItemShouldLookIntoPackages: (FSItem*) item; //set kind string in "loadChilds?";
													   //default is NO (if not implemented by delegate)
- (BOOL) fsItemShouldUsePhysicalFileSize: (FSItem*) item;
@end

//Exception raised by FSItem
//delegate canceled the loading (see above)
extern NSString* FSItemLoadingCanceledException;
//error while enumerating files/folders (e.g. volume has been ejected (unmounted)) 
extern NSString* FSItemLoadingFailedException;
