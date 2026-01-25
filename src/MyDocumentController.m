//
//  MyDocumentController.m
//  Disk Accountant
//
//  Created by Tjark Derlien on Wed Oct 08 2003.
//
//  Copyright (C) 2003 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

//

#import "MyDocumentController.h"
#import "DrivesPanelController.h"
#import "Preferences.h"
#import "PrefsPanelController.h"
#import "FileSystemDoc.h"
#import "AppController.h"

//global variable which enables/disables logging
BOOL g_EnableLogging;

//============ implementation MyDocumentController ==========================================================

@implementation MyDocumentController

- (NSInteger) runModalOpenPanel: (NSOpenPanel*) openPanel forTypes: (NSArray*) extensions
{
    //we want the user to choose a directory (including packages)
    [openPanel setCanChooseDirectories: YES];
    [openPanel setCanChooseFiles: NO];
    [openPanel setTreatsFilePackagesAsDirectories: YES];
	
//	if ( ![[DrivesPanelController sharedController] panelIsVisible] )
	{
		//volumes panel isn't (yet) loaded, so show the open panel the normal way (as a modal window)
		return [openPanel runModal];
	}
/*	else
	{
		//the volumes panel is loaded, so display the open panel as a nice sheet
		
		[openPanel beginSheetForDirectory: nil
									 file: nil
						   modalForWindow: [[DrivesPanelController sharedController] panel]
							modalDelegate: self
						   didEndSelector: @selector(openPanelDidEnd:returnCode:contextInfo:)
							  contextInfo: nil];
		
		//we will be called back after the sheet is closed, so return "Cancel" for now
		return NSCancelButton;
	}
	*/
}

- (void) openPanelDidEnd:(NSOpenPanel *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	if ( returnCode == NSModalResponseOK )
	{
		//open selected folders
		for ( NSURL *fileURL in [sheet URLs] )
		{
			//defer it till the next loop cycle to let the sheet closes itself first
			[[NSRunLoop currentRunLoop] performSelector:@selector(openDocumentWithContentsOfFile:)
												 target: self
                                               argument: [fileURL path]
												  order: 1
												  modes: [NSArray arrayWithObject: NSDefaultRunLoopMode]];
		}
	}
}

- (void) openDocumentWithContentsOfFile: (NSString*) fileName
{
	[self openDocumentWithContentsOfFile: fileName display: [self shouldCreateUI]];
}

- (BOOL) applicationShouldOpenUntitledFile: (NSApplication*) sender
{
    //we don't want any untitled document as we need an existing folder
    return NO;
}

- (id)makeDocumentWithContentsOfFile:(NSString *)fileName ofType:(NSString *)docType
{
	//check whether "fileName" is a folder
	NSDictionary *attribs = [[NSFileManager defaultManager] fileAttributesAtPath: fileName traverseLink: NO];
    if ( attribs != nil )
	{
		NSString *type = [attribs fileType];
		if ( type != nil && [type isEqualToString: NSFileTypeDirectory] )
			return [super makeDocumentWithContentsOfFile:fileName ofType: @"Folder"];
	}
	
	return nil;
}

//"Open..." menu handler
- (IBAction)openDocument:(id)sender
{
	//we implement this method by ourself, so we can avoid that stupid message "document couldn't be opened"
	//in the case the user canceled the opening
	NSArray<NSURL *> *fileNames = [self URLsFromRunningOpenPanel];
	
	if ( fileNames == nil )
		return; //cancel pressed in open panel
	
	for ( NSURL *dir in fileNames )
	{
		[self openDocumentWithContentsOfFile: [dir path] display: YES];
	}
}

+ (void)restoreWindowWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                              state:(NSCoder *)state
                  completionHandler:(void (^)(NSWindow *, NSError *))completionHandler
{
    // prevent any window, which was open when quitting the app last time, to be re-opened now at the next lauch
    // (see https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/StandardBehaviors/StandardBehaviors.html#//apple_ref/doc/uid/TP40011179-CH5-SW4
    // Document-Based App Programming Guide for Mac/Core App Behaviors/Windows Are Restored Automatically)
    completionHandler(nil, nil);
}

//Application's delegate; called if file from recent list is selected
- (BOOL) application: (NSApplication*) theApp openFile: (NSString*) fileName
{
	//if "fileName" doesn't exist or isn't a folder, return NO so that it is removed from the recent list
	NSDictionary *attribs = [[NSFileManager defaultManager] attributesOfItemAtPath: fileName error:nil];
    if ( attribs == nil || ![[attribs fileType] isEqualToString: NSFileTypeDirectory] )
		return NO;

	[self openDocumentWithContentsOfFile: fileName];
	
	//return TRUE to avoid nasty message if user canceled loading
	return TRUE;
}

- (NSString *)typeFromFileExtension:(NSString *)fileExtensionOrHFSFileType
{
	OSType type = NSHFSTypeCodeFromFileType(fileExtensionOrHFSFileType);
	if ( type == 0 )
		return @"Folder";
	else	
		return [super typeFromFileExtension: fileExtensionOrHFSFileType];
}

- (IBAction) showPreferencesPanel: (id) sender
{
	[[PrefsPanelController sharedPreferenceController] showPreferencesPanel: self];
	//[[OAPreferenceController sharedPreferenceController] showPreferencesPanel: self];
}

- (IBAction) gotoHomepage: (id) sender
{
	[[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: @"http://www.derlien.com"]];
}

- (IBAction) closeDonationPanel: (id) sender;
{
	[_donationPanel close]; //will release itself
	_donationPanel = nil;
}


#pragma mark --------app notifications-----------------

- (void) applicationWillFinishLaunching: (NSNotification*) notification
{
    //verify that our custom DocumentController is in use 
    NSAssert( [[NSDocumentController sharedDocumentController] isKindOfClass: [MyDocumentController class]], @"the shared DocumentController is not our custom class!" );
    
    //@@test
    //[[OAController sharedController] applicationWillFinishLaunching:notification];
	
	g_EnableLogging = [[NSUserDefaults standardUserDefaults] boolForKey: EnableLogging];
    
	//show the drives panel before "applicationDidFinishLaunching" so the panel is visible before the first document is loaded
	//(e.g. through drag&drop)
	[[DrivesPanelController sharedController] showPanel];
}

- (void) applicationDidFinishLaunching:(NSNotification *)notification
{
    //@@test
    //[[OAController sharedController] applicationDidFinishLaunching:notification];

    //show donate message
	if ( ![[NSUserDefaults standardUserDefaults] boolForKey: DontShowDonationMessage] )
	{
		[NSBundle loadNibNamed: @"DonationPanel" owner:self];
		[_donationPanel setWorksWhenModal: YES];
	}
	
//	DIXFinderCMInstaller *installer = [DIXFinderCMInstaller installer];
//	if ( ![installer isInstalled] )
//		[installer installToDomain: kUserDomain];
}

#pragma mark -----------------NSMenu delegates-----------------------

- (void) menuNeedsUpdate: (NSMenu*) zoomStackMenu
{
	OBPRECONDITION( _zoomStackMenu == zoomStackMenu );
	
	FileSystemDoc *doc = [self currentDocument];
	NSArray *zoomStack = [doc zoomStack];
	
	//thanks to ObjC, [zoomStack count] will evaluate to 0 if there is no current doc
	unsigned i;
	for ( i = 0; i < [zoomStack count]; i++ )
	{
		FSItem *fsItem = nil;
		if ( i == 0 )
			fsItem = [doc rootItem];
		else
			fsItem = [zoomStack objectAtIndex: i-1];
		
		if ( i >= ((unsigned) [zoomStackMenu numberOfItems]) )
			[zoomStackMenu addItem: [[[NSMenuItem alloc] init] autorelease]];
		
		NSMenuItem *menuItem = [zoomStackMenu itemAtIndex: i];
		
		[menuItem setTitle: [fsItem displayName]];
		if ( i > 0 ) //no tooltip for first item as the tooltip is the same as the title
			[menuItem setToolTip: [fsItem displayPath]];
		[menuItem setImage: [fsItem iconWithSize: 16]];
		[menuItem setRepresentedObject: fsItem];
		[menuItem setTarget: nil];
		[menuItem setAction: @selector(zoomOutTo:)];
	}
	
	//remove any supernumerary menu items
	while ( ((unsigned) [zoomStackMenu numberOfItems]) > [zoomStack count] )
		[zoomStackMenu removeItemAtIndex: [zoomStackMenu numberOfItems] -1];
}

@end

