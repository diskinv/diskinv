//
//  NTTitledInfoView.h
//  Path Finder
//
//  Created by sgehrman on Mon Aug 06 2001.
//  Copyright (c) 2001 CocoaTech. All rights reserved.
//

#import <AppKit/AppKit.h>

@interface NTTitledInfoView : NSView
{
    id _target;
    
    NSMutableArray* _pairs;
    NSMutableArray* _titleViews;
    NSMutableArray* _infoViews;
    
    CGFloat _titleWidth;
    CGFloat _horizontalOffset;
    CGFloat _verticalOffset;
    
    BOOL _inFrameChanged;
    
    NSMutableArray* _backgroundLineOffsets;
    CGFloat _backgroundShadowOffset;
}

- (void)setTarget:(id)target;
- (void)setWithArray:(NSArray*)pairArray;

- (void)setHorizontalOffset:(int)offset;
- (void)setVerticalOffset:(int)offset;
@end
