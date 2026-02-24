//
//  DIXFileInfoView.m
//  Disk Inventory X
//
//  Created by Tjark Derlien on 04.12.04.
//
//  Copyright (C) 2004 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import "DIXFileInfoView.h"
#import "NTTitledInfoPair.h"

@interface NTInfoView (MakeVisible)
- (NSArray*)infoPairs;
- (NSArray*)longInfoPairs;
@end

@interface DIXFileInfoView(Private)
- (NSArray*)infoPairs;
@end

@implementation DIXFileInfoView

@end

@implementation DIXFileInfoView(Private)

- (NSArray*)infoPairs
{
	NSURL *url = [self URL];
	
	NSMutableArray *infoPairs = (NSMutableArray*) [super infoPairs];
	OBPRECONDITION( [infoPairs isKindOfClass: [NSMutableArray class]] );

	//NTInfoView shows the display name (possibly localized and with hidden extension), but we want the "raw" name
	//(the display name is shown above next to the image in the inspector panel)
	if ( url != nil && infoPairs != nil && [infoPairs count] > 0 )
	{
		NTTitledInfoPair *oldNameInfoPair = [infoPairs objectAtIndex: 0];
		
		[infoPairs replaceObjectAtIndex: 0
							 withObject: [NTTitledInfoPair infoPair: [oldNameInfoPair title] info: [url name]]];
	}

	return infoPairs;
}


@end
