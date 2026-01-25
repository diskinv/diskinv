//
//  AppsForItem.m
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

#import "AppsForItem.h"
#import <OmniFoundation/NSMutableArray-OFExtensions.h>
#import "NSURL-Extensions.h"

@interface AppsForItem(Private)

+ (NSArray<NSURL*>*)applicationURLsForItemURL:(NSURL*)inItemURL;
- (BOOL) checkAppURL: (NSURL*) appURL checkDefaultApp: (BOOL) checkDefApp;

@end


@implementation AppsForItem

+ (id) appsForItemURL: (NSURL*) url
{
	AppsForItem *appsForFile = [[[self class] alloc] initWithItemURL: url];
		
	return [appsForFile autorelease];
}

- (id) initWithItemURL: (NSURL*) url
{
	self = [super init];
	if ( self != nil )
	{
		_itemURL = [url retain];
	}
	
	return self;
}

- (void) dealloc
{
	[_itemURL release];
	[_defaultAppURL release];
	[_additionalAppURLs release];
	
	[super dealloc];
}

- (NSURL*) defaultAppURL //may return nil
{
	if ( _defaultAppURL == nil )
	{
		_defaultAppURL = (id) [NSNull null]; //retain not necessary for NSNull
		
		LSRolesMask RoleMask = kLSRolesViewer | kLSRolesEditor;

        NSURL *appURL = (NSURL*)LSCopyDefaultApplicationURLForURL( (CFURLRef)[self itemURL], RoleMask, nil );
        
		if ( [self checkAppURL: appURL checkDefaultApp: NO] )
			_defaultAppURL = appURL;
        else
            [appURL release];
	}
	
	return (_defaultAppURL == (id)[NSNull null]) ? nil : _defaultAppURL;
}

- (NSArray<NSURL*>*) additionalAppURLs //may return empty array (but never nil)
{
	if ( _additionalAppURLs == nil )
	{
		NSURL *itemURL = [self itemURL];
		NSArray<NSURL*> *appURLs = [[self class] applicationURLsForItemURL: itemURL];
		
		_additionalAppURLs = [[NSMutableArray<NSURL*> alloc] initWithCapacity: [appURLs count]];
		for ( NSURL *appURL in appURLs )
		{
			if ( [appURL isFileURL]
                && [self checkAppURL: appURL checkDefaultApp: YES] )
            {
                [_additionalAppURLs addObject: appURL];
			}
		}
		
		[_additionalAppURLs sortOnAttribute: @selector(name) usingSelector: @selector(caseInsensitiveCompare:)];
	}
	
	return _additionalAppURLs;
}

- (NSURL*) itemURL
{
	return _itemURL;
}

- (void) openItemWithAppURL: (NSURL*) appURL
{
	[[self class] openItemURL: [self itemURL] withAppURL: appURL];
}

+ (void) openItemURL: (NSURL*) itemURL withAppURL: (NSURL*) appURL
{
	[[NSWorkspace sharedWorkspace] openFile: [itemURL path] withApplication: [appURL path]];
}

@end

@implementation AppsForItem(Private)

- (BOOL) checkAppURL: (NSURL*) appURL checkDefaultApp: (BOOL) checkDefApp
{
	if ( appURL == nil )
		return NO;
	
	if ( checkDefApp && [appURL isEqualToURL: [self defaultAppURL]] )
		return NO;
	
	BOOL isDIX = [[appURL name] isEqualToString: @"Disk Inventory X.app"];
	BOOL isFinder = [[appURL name] isEqualToString: @"Finder.app"];
	
	//filter out the Finder (for simple folders, the Finder is returned by "LSGetApplicationForItem" and "LSCopyApplicationURLsForURL")
	//it would be better to identify the Finder by it's bundle identifier, but then we would have to load it's bundle (?)
	return !isDIX
			&& ( [appURL isFile]
				 || [appURL isPackage] 
				 || !isFinder );
}

// get a list of apps that can open a document
// NOTE: this searches network volumes!!
+ (NSArray<NSURL*>*) applicationURLsForItemURL:(NSURL*)inItemURL;
{
    CFArrayRef outURLs;
    NSMutableArray* result=nil;
	
    outURLs = LSCopyApplicationURLsForURL( (CFURLRef) inItemURL, kLSRolesViewer | kLSRolesEditor );
    if (outURLs)
    {
        if ([(id)outURLs isKindOfClass:[NSArray class]])
        {
            result = [NSMutableArray arrayWithArray:(NSArray*)outURLs];
            
            // filter out .exe files
            int i, cnt = [result count];
            NSURL *url;
            
            for (i=(cnt-1);i>=0;i--)
            {
                url = [result objectAtIndex:i];
                
                if ([[[url path] pathExtension] caseInsensitiveCompare:@"exe"] == NSOrderedSame)
                    [result removeObjectAtIndex:i];
            }            
        }
        
        CFRelease(outURLs);
    }
	
    return result;
}

@end
