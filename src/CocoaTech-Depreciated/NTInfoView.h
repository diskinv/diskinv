//
//  NTInfoView.h
//  Path Finder
//
//  Created by Steve Gehrman on Sat Jul 12 2003.
//  Copyright (c) 2003 __MyCompanyName__. All rights reserved.
//

#import "NTTitledInfoView.h"
#import "NSURL-Extensions.h"

@interface NTInfoView : NSView 
{
    NTTitledInfoView* _titledInfoView;
    NSURL* _URL;
    BOOL _longFormat;
    
    NSString* _calculatedFolderSize, *_calculatedFolderNumItems;
}

- (id)initWithFrame:(NSRect)frame longFormat:(BOOL)longFormat;
- (id)initWithFrame:(NSRect)frame;  // long format is NO by default

- (NSURL*)URL;
- (void)setURL:(NSURL*)url;

@end
