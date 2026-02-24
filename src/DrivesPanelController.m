//
//  DrivesPanelController.m
//  Disk Inventory X
//
//  Created by Tjark Derlien on 15.11.04.
//
//  Copyright (C) 2004 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import "DrivesPanelController.h"
#import "FileSizeFormatter.h"
#import "VolumeNameTransformer.h"
#import "VolumeUsageTransformer.h"
#import "NSURL-Extensions.h"

//NTStringShare is a private class in the CocoaFoundation framework; but as it is not fully thread safe,
//we need to declare it here to be accessible (see [DrivesPanelController init])
@interface NTStringShare : NSObject
+ (NTStringShare*)sharedInstance;
@end

//============ interface DrivesPanelController(Private) ==========================================================

@interface DrivesPanelController(Private)

- (void) rebuildVolumesArray;
- (void) rebuildProgressIndicatorArray;
- (void) onVolumesChanged: (NSNotification*) notification;

@end


@implementation DrivesPanelController

+ (DrivesPanelController*) sharedController
{
	static DrivesPanelController *controller = nil;
	
	if ( controller == nil )
		controller = [[DrivesPanelController alloc] init];
	
	return controller;
}

- (id) init
{
	self = [super init];
    
    _maxVolumeSize = 0;

	//register volume transformers needed in the volume tableview (before Nib is loaded!)
	[NSValueTransformer setValueTransformer:[VolumeNameTransformer transformer] forName: @"volumeNameTransformer"];
	[NSValueTransformer setValueTransformer:[VolumeUsageTransformer transformer] forName: @"volumeUsageTransformer"];

    NSNotificationCenter *wsNotiCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [wsNotiCenter addObserver: self
                     selector: @selector(onVolumesChanged:)
                         name: NSWorkspaceDidMountNotification
                       object: nil];
    
    [wsNotiCenter addObserver: self
                     selector: @selector(onVolumesChanged:)
                         name: NSWorkspaceDidUnmountNotification
                       object: nil];
    
    [wsNotiCenter addObserver: self
                     selector: @selector(onVolumesChanged:)
                         name: NSWorkspaceDidRenameVolumeNotification
                       object: nil];

	
	[self rebuildVolumesArray];
	
	//load Nib with volume panel
    if ( ![NSBundle loadNibNamed: @"VolumesPanel" owner: self] )
	{
		[self release];
		self = nil;
	}
	else
	{
		//open volume on double clicked (can't be configured in IB?)
		[_volumesTableView setDoubleAction: @selector(openVolume:)];
		
		//set FileSizeFormatter for the columns displaying sizes (capacity, free)
		FileSizeFormatter *sizeFormatter = [[[FileSizeFormatter alloc] init] autorelease];
		[[[_volumesTableView tableColumnWithIdentifier: @"totalSize"] dataCell] setFormatter: sizeFormatter];
		[[[_volumesTableView tableColumnWithIdentifier: @"freeBytes"] dataCell] setFormatter: sizeFormatter];
	}
	
	[_volumesPanel makeFirstResponder: _volumesTableView];
	
	return self;
}

- (void) dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver: self];

    [_volumes release];
	[_progressIndicators release];
	
    [super dealloc];
}

- (NSArray*) volumes
{
	return _volumes;
}

- (IBAction)openVolume:(id)sender
{
	NSIndexSet *selectedIndexes = [_volumesTableView selectedRowIndexes];
	NSUInteger index = [selectedIndexes firstIndex];
	
	//open volume in each of the selected rows
    while (index != NSNotFound)
    {
		NSURL *volume = [[_volumes objectAtIndex: index] objectForKey: @"volume"];
        if ( [volume stillExists] )
        {
            NSString *path = [volume path];
            
            //defer it till the next loop cycle (otherwise the "Open Volume" button stays in "pressed" mode during the loading)
            [[NSRunLoop currentRunLoop] performSelector: @selector(openDocumentWithContentsOfFile:)
                                                 target: [NSDocumentController sharedDocumentController]
                                               argument: path
                                                  order: 1
                                                  modes: [NSArray arrayWithObject: NSDefaultRunLoopMode]];
        }
        
        index = [selectedIndexes indexGreaterThanIndex: index];
    }	
}

- (BOOL) panelIsVisible
{
	return [[self panel] isVisible];
}

- (void) showPanel
{
	[[self panel] orderFront: nil];
}

- (NSWindow*) panel
{
	return _volumesPanel;
}


@end

//============ implementation DrivesPanelController(Private) ==========================================================

@implementation DrivesPanelController(Private)

//fill array "_volumes" with mounted volumes and their images
- (void) rebuildVolumesArray
{
    _maxVolumeSize = 0;
    
    NSArray *volProps = [NSArray arrayWithObjects:NSURLLocalizedNameKey
                                                , NSURLVolumeTotalCapacityKey
                                                , NSURLVolumeAvailableCapacityKey
                                                , NSURLVolumeSupportsVolumeSizesKey
                                                , NSURLVolumeLocalizedFormatDescriptionKey
                                                , nil];
    
    NSArray<NSURL *> *vols = [[NSFileManager defaultManager] mountedVolumeURLsIncludingResourceValuesForKeys: volProps
                                                                                                     options: NSVolumeEnumerationSkipHiddenVolumes];
    
    [self willChangeValueForKey: @"volumes"];
    
    NS_DURING
    [_volumes release];
    _volumes = [[NSMutableArray alloc] initWithCapacity: [vols count]];
    
    for ( NSURL *volumeURL in vols )
    {
        [volumeURL cacheResourcesInArray: volProps];
        
        //put NSURL object for key "volume" in the entry dictionary
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject: volumeURL forKey: @"volume"];
        
        //put volume icon for key "image" in the entry dictionary
        NSImage *volImage = [volumeURL icon];
        [volImage setSize: NSMakeSize(32,32)];
        
        [entry setObject: ( volImage == nil ? (id)[NSNull null] : volImage )
                  forKey: @"image"];
        
        [_volumes addObject: entry];
        
        if ( [[volumeURL volumeTotalCapacity] unsignedLongLongValue] > _maxVolumeSize)
            _maxVolumeSize = [[volumeURL volumeTotalCapacity] unsignedLongLongValue];
    }
    NS_HANDLER
    NS_ENDHANDLER
    
    [self rebuildProgressIndicatorArray];
    
    [self didChangeValueForKey: @"volumes"];
}

//keeps array of progress indicators (for graphical usage display) in sync with volumes array
- (void) rebuildProgressIndicatorArray
{
	if ( _progressIndicators == nil )
		_progressIndicators = [[NSMutableArray alloc] initWithCapacity: [_volumes count]];
	
	unsigned i;
	for ( i = 0; i < [_volumes count]; i++ )
	{
		NSProgressIndicator *progrInd = nil;
		if ( i >= [_progressIndicators count] )
		{
			progrInd = [[[NSProgressIndicator alloc] init] autorelease];
			[progrInd setStyle: NSProgressIndicatorBarStyle];
			[progrInd setIndeterminate: NO];
			
			[_progressIndicators addObject: progrInd];
		}
		else
			//reuse existing progress indicator
			progrInd = [_progressIndicators objectAtIndex: i];
		
		NSURL *vol = [[_volumes objectAtIndex: i] objectForKey : @"volume"];
        
        if ( [vol getCachedBoolValue: NSURLVolumeSupportsVolumeSizesKey] )
        {
            double totalBytes = [[vol volumeTotalCapacity] doubleValue];
            double freeBytes = [[vol volumeAvailableCapacity] doubleValue];

            [progrInd setMinValue: 0];
            [progrInd setMaxValue: totalBytes];
            [progrInd setDoubleValue: (totalBytes - freeBytes)];
        }
        else
        {
            [progrInd setMinValue: 0];
            [progrInd setMaxValue: 0];
            [progrInd setDoubleValue: 0];
        }
	}
	
	while ( [_progressIndicators count] > [_volumes count] )
	{
		[[_progressIndicators lastObject] removeFromSuperviewWithoutNeedingDisplay];
		[_progressIndicators removeLastObject];
	}
}

#pragma mark --------NTVolumeMgr notifications-----------------

- (void) onVolumesChanged: (NSNotification*) notification
{
    [self rebuildVolumesArray];
}

#pragma mark --------NSTableView notifications-----------------

- (void) tableViewSelectionDidChange: (NSNotification*) notification
{
}

#pragma mark --------NSTableView delegates-----------------

- (void) tableView:(NSTableView *) tableView willDisplayCell:(id) cell forTableColumn:(NSTableColumn *) tableColumn row:(int) row
{
	if ( [[tableColumn identifier] isEqualToString: @"usagePercent"] )
	{
		NSProgressIndicator *progrInd = [_progressIndicators objectAtIndex: row];
		
		//add progress indicator as subview of table view
		if ( [progrInd superview] != tableView )
			[tableView addSubview: progrInd];
		
		int colIndex = [tableView columnWithIdentifier: [tableColumn identifier]];
		NSRect cellRect = [tableView frameOfCellAtColumn: colIndex row: row];
		
		const float progrIndThickness = NSProgressIndicatorPreferredLargeThickness; 
		const float extraSpace = 16; //space before and after progress indicator (relative to left and right side of cell)
		
		//center it vertically in cell
		NSAssert( NSHeight(cellRect) > progrIndThickness, @"rows need to be higher than progress indicator thickness" );
		cellRect.origin.y += (NSHeight(cellRect) - progrIndThickness) / 2;
		cellRect.size.height = progrIndThickness;

		//add space before and after
		cellRect.origin.x += extraSpace;
		cellRect.size.width -= 2*extraSpace;
        
        NSURL *volURL = [[_volumes objectAtIndex: row] objectForKey : @"volume"];
        if ( [volURL getCachedBoolValue: NSURLVolumeSupportsVolumeSizesKey] )
        {
            double fraction = [[volURL cachedVolumeTotalCapacity] doubleValue] / (double)_maxVolumeSize;
            // each volume should at least be shown as 20% of the available space as it would be shown as too narrow (or not at all) otherwise
            cellRect.size.width *= fmax(fraction, 0.2);
        }
        else
            cellRect.size.width = 0; //no size information available; hide progress indicator
        
		[progrInd setFrame: cellRect];
		[progrInd stopAnimation: nil];
	}
}



@end
