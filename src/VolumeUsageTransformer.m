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

#import "VolumeUsageTransformer.h"
#import "NSURL-Extensions.h"


@implementation VolumeUsageTransformer

+ (id) transformer
{
	return [[[VolumeUsageTransformer alloc] init] autorelease];
}

- (id) init
{
	self = [super init];
	
	_sizeFormatter = [[FileSizeFormatter alloc] init];
	
	return self;
}

- (void) dealloc
{
	[_sizeFormatter release];
	
	[super dealloc];
}

- (id)transformedValue:(id)value 
{
    if ( value == nil )
		return nil;
	
    NSString *strCapacity = @"n/a";
    NSString *strFree = @"n/a";
    NSString *strUsed = @"n/a";
    
    NSURL *volume = (NSURL*)value;

    if ( [volume getCachedBoolValue: NSURLVolumeSupportsVolumeSizesKey] )
    {
        //get values as NSNumbers
        NSNumber *numCapacity = [volume cachedVolumeTotalCapacity];
        NSNumber *numFree = [volume cachedVolumeAvailableCapacity];
        NSNumber *numUsed = [NSNumber numberWithUnsignedLongLong:
                                [numCapacity unsignedLongLongValue] - [numFree unsignedLongLongValue]];
        
        //convert values to formatted strings
        strCapacity = [_sizeFormatter stringForObjectValue: numCapacity];
        strFree = [_sizeFormatter stringForObjectValue: numFree];
        strUsed = [_sizeFormatter stringForObjectValue: numUsed];
    }
	
	//create display strings from formatted values
	NSString *capacityField = [NSString stringWithFormat: @"%@: %@", NSLocalizedString(@"Capacity",@""), strCapacity];
	NSString *usedAndFreeFields = [NSString stringWithFormat: @"\n%@: %@\n%@: %@", NSLocalizedString(@"Used",@""), strUsed, NSLocalizedString(@"Free",@""), strFree];
	
	//create and return an attributed string from display strings
	NSMutableAttributedString *attribString = [[NSMutableAttributedString alloc] initWithString: capacityField 
																					 attributes: [VolumeUsageTransformer capacityStringAttributes]];
	
	[attribString appendAttributedString:[[[NSMutableAttributedString alloc] initWithString: usedAndFreeFields 
																				 attributes: [VolumeUsageTransformer usedAndFreeStringAttributes]] autorelease]];
	
	
	
	return [attribString autorelease];
}

+ (NSDictionary*) capacityStringAttributes
{
	static NSDictionary *attribs = nil;
	
	if ( attribs == nil )
	{
		NSMutableParagraphStyle *rightAlignStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
		[rightAlignStyle setAlignment: NSRightTextAlignment];
		
		NSFont *font = [NSFont boldSystemFontOfSize: [NSFont smallSystemFontSize]];
		attribs = [[NSDictionary alloc] initWithObjectsAndKeys: font, NSFontAttributeName, rightAlignStyle, NSParagraphStyleAttributeName, nil];
		
		[rightAlignStyle release];
	}
	
	return attribs;
}

+ (NSDictionary*) usedAndFreeStringAttributes
{
	static NSDictionary *attribs = nil;
	
	if ( attribs == nil )
	{
		NSMutableParagraphStyle *rightAlignStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
		[rightAlignStyle setAlignment: NSRightTextAlignment];
		
		NSFont *font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
		attribs = [[NSDictionary alloc] initWithObjectsAndKeys: font, NSFontAttributeName, rightAlignStyle, NSParagraphStyleAttributeName, nil];
		
		[rightAlignStyle release];
	}
	
	return attribs;
}



+ (Class) transformedValueClass
{
	return [NSString class];
}

@end
