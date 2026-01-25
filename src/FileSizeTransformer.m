//
//  FileSizeTransformer.m
//  Disk Inventory X
//
//  Created by Tjark Derlien on 25.03.05.
//
//  Copyright (C) 2005 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

#import "FileSizeTransformer.h"


@implementation FileSizeTransformer

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

+ (id) transformer
{
	return [[[[self class] alloc] init] autorelease];
}

- (id)transformedValue:(id)value 
{
	if ( value == nil )
		return nil;
	
	return [_sizeFormatter stringForObjectValue: value];
}

+ (Class) transformedValueClass
{
	return [NSString class];
}

@end
