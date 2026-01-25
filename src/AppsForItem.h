//
//  AppsForItem.h
//  Disk Inventory X new
//
//  Created by Tjark Derlien on 20.01.06.
//
//  Copyright (C) 2006,2019 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

#import <Cocoa/Cocoa.h>


@interface AppsForItem : NSObject {
	NSURL *_defaultAppURL;
	NSMutableArray<NSURL*> *_additionalAppURLs;
	NSURL *_itemURL; //file/folder for which to search for applications
}

+ (id) appsForItemURL: (NSURL*) url;
- (id) initWithItemURL: (NSURL*) url;

- (NSURL*) defaultAppURL; //may return nil
- (NSArray<NSURL*>*) additionalAppURLs; //may return empty array (but never nil)

- (NSURL*) itemURL;

- (void) openItemWithAppURL: (NSURL*) appDesc;
+ (void) openItemURL: (NSURL*) item withAppURL: (NSURL*) appDesc;

@end
