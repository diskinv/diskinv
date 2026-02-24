//
//  TMVItem.h
//  DiskAccountant
//
//  Created by Tjark Derlien on Tue Sep 30 2003.
//  Copyright (c) 2003 Tjark Derlien. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TMVCushionRenderer.h"

//holds display information about one cell in the treemap
@interface TMVItem : NSObject
{
    id _dataSource; // tree map view's data source (implements TreeMapViewDataSource)
    id _delegate;   // tree map view's delegate (implements TreeMapViewDelegate)
    id _item;       // the data item in the data source which is represented by this tree map item
    id _view;       // the tree map view to which this item belongs
    
    NSRect _rect;   // tree map item's rectangle (in backing coordinates of the tree map view)
    NSMutableArray *_childRenderers;
    TMVCushionRenderer *_cushionRenderer;
}

- (id) initWithDataSource: (id) dataSource delegate: (id) delegate renderedItem: (id) item treeMapView: (id) view;

- (void) refreshWithItem: (id) item;

- (void) setCushionColor: (NSColor*) color; 

- (void) calcLayout: (NSRect) rect;

- (void) drawGrid;
- (void) drawHighlightFrame;

- (void) drawCushionInBitmap: (NSBitmapImageRep*) bitmap;

- (BOOL) isLeaf;
- (id) item;
- (unsigned long long) weight;

- (NSEnumerator *) childEnumerator;
- (TMVItem*) childAtIndex: (unsigned) index;
- (NSUInteger) childCount;

- (NSRect) rect;
- (TMVItem *) hitTest: (NSPoint) aPoint;

@end
