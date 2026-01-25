//
//  VolumeNameTransformer.m
//  Disk Inventory X
//
//  Created by Tjark Derlien on 08.11.04.
//
//  Copyright (C) 2004 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import "VolumeNameTransformer.h"
#import "NSURL-Extensions.h"


@implementation VolumeNameTransformer

+ (void) initialize
{
}

+ (id) transformer
{
	return [[[VolumeNameTransformer alloc] init] autorelease];
}

- (id)transformedValue:(id)value 
{
	if ( value == nil )
		return nil;
    
    NSURL *vol = value;
	
	NSString *name = [vol cachedDisplayName];
	NSString *volumeType = [vol cachedVolumeFormatName];
	
	//create an attributed string with the format "<volume display name><line break> <volume format>"
	
	//volume display name
	NSMutableAttributedString *attribString = [[NSMutableAttributedString alloc] initWithString: name 
																					 attributes: [VolumeNameTransformer volumeTitleAttributes]];
	
	//volume type (e.g. "HFS+")
    if ( volumeType != nil )
    {
        //add line break to string
        [attribString appendAttributedString: [[[NSAttributedString alloc] initWithString: @"\n "] autorelease]];

        NSAttributedString *volumeTypeString = [[NSAttributedString alloc] initWithString: volumeType
                                                                               attributes: [VolumeNameTransformer volumeTypeAttributes]];
	
        //add volume format as second line
        [attribString appendAttributedString: volumeTypeString];
        [volumeTypeString release];
    }
    
	return [attribString autorelease];
}

+ (NSDictionary*) volumeTitleAttributes
{
	static NSDictionary *attribs = nil;
	
	if ( attribs == nil )
	{
		NSFont *font = [NSFont systemFontOfSize: 0 /*default size*/];
		attribs = [[NSDictionary alloc] initWithObjectsAndKeys: font, NSFontAttributeName, nil];
	}
	
	return attribs;
}

+ (NSDictionary*) volumeTypeAttributes
{
	static NSDictionary *attribs = nil;
	
	if ( attribs == nil )
	{
		NSFont *font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
		attribs = [[NSDictionary alloc] initWithObjectsAndKeys: font, NSFontAttributeName, nil];
	}
	
	return attribs;
}

+ (Class) transformedValueClass
{
	return [NSAttributedString class];
}

@end
