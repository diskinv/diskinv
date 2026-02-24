//
//  FileSizeTransformer.h
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


#import <Cocoa/Cocoa.h>
#import "FileSizeFormatter.h"


@interface FileSizeTransformer : NSValueTransformer
{
	FileSizeFormatter *_sizeFormatter;
}

+ (id) transformer;

@end
