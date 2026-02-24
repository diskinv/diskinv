//
//  FileSizeFormatter.m
//  Disk Inventory X
//
//  Created by Tjark Derlien on Sat Mar 27 2004.
//  Copyright (c) 2004 Tjark Derlien. All rights reserved.
//

#import "FileSizeFormatter.h"


@implementation FileSizeFormatter

- (id) init
{
	self = [super init];
	
    [self setFormatterBehavior:NSNumberFormatterBehavior10_0];
	[self setLocalizesFormat: YES];
	[self setFormat: @"#,#0.0"];
	
	return self;
}

- (NSString *) stringForObjectValue:(id)anObject
{
	NSParameterAssert( [anObject respondsToSelector: @selector(doubleValue)] );
	
	double dsize = [anObject doubleValue];
	
	static NSString* units[] = {@"Bytes", @"kB", @"MB", @"GB", @"TB"};
    static size_t iUnitCount = sizeof(units)/sizeof(units[0]);
	
    static double unitFactor = 1000/*1024*/;
    
    size_t i = 0;
    for ( ; dsize >= unitFactor && i < (iUnitCount-1); i++ )
		dsize /= unitFactor;
	
	if ( i <= 1 )
		//Bytes, kB are displayed as integers (like the finder does)
		return [NSString stringWithFormat: @"%u %@", (unsigned) round(dsize), units[i] ];
	else
	{
		//MB, GB or TB
		NSString *ret = [super stringForObjectValue: [NSNumber numberWithDouble: dsize]];
		return [ret stringByAppendingFormat: @" %@", units[i]];
	}	
}


@end
