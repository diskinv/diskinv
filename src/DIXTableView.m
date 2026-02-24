//
//  DIXTableView.m
//  Disk Inventory X
//
//  Created by Tjark Derlien on 31.03.05.
//
//  Copyright (C) 2005 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.

//

#import "DIXTableView.h"


@implementation DIXTableView

// ask the delegate which menu to show
-(NSMenu*) menuForEvent:(NSEvent*)evt
{
    NSPoint point = [self convertPoint: [evt locationInWindow] fromView: nil];
    
    NSInteger columnIndex = [self columnAtPoint:point];
    NSInteger rowIndex = [self rowAtPoint:point];
	
    if ( rowIndex >= 0 && [self numberOfSelectedRows] <= 1)
        [self selectRowIndexes:[NSIndexSet indexSetWithIndex:rowIndex] byExtendingSelection: NO];
	
    id delegate = [self delegate];
    
    if ( columnIndex >= 0 && rowIndex >= 0 )
    {
		//get context menu
        NSMenu *contextMenu = nil;
		if ( [delegate respondsToSelector:@selector(tableView:menuForTableColumn:item:)] )
		{
			NSTableColumn *column = [[self tableColumns] objectAtIndex: columnIndex];
			contextMenu = [delegate tableView:self menuForTableColumn: column row: rowIndex];
		}
		else
			contextMenu = [self menu];
		
		//set first responder if we will show a context menu
		//(isn't necessary for proper function, but makes sense as the user opens the context menu)
		if ( contextMenu != nil
			 && [self acceptsFirstResponder]
			 && [[self window] firstResponder] != self )
		{
			[[self window] makeFirstResponder: self];
		}
		
		return contextMenu;
    }
    else
        return NULL;
}

//ask the delegate which drag operations are supported (if we are the dragging source) 
- (NSDragOperation) draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    id delegate = [self delegate];
	
	//forward to our delegate, if possible
	if ( [delegate  respondsToSelector:@selector(draggingSourceOperationMaskForLocal:)] )
		return [delegate draggingSourceOperationMaskForLocal: isLocal];
	else
		//NSTableView implements draggingSourceOperationMaskForLocal 
		return [super draggingSourceOperationMaskForLocal: isLocal];
}


@end
