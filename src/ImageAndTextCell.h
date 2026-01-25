//
//  ImageAndTextCell.h
//
//  Copyright (c) 2001-2002, Apple. All rights reserved.
//

//This class is taken from the AppKit example "DragNDropoutlineView".
//(installed with the Apple dev tools)

#import <Cocoa/Cocoa.h>

@interface ImageAndTextCell : NSTextFieldCell {
@private
    NSImage	*_image;
}

+ (id) cell;

- (void)setImage:(NSImage *)anImage;
- (NSImage *)image;

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView;
- (NSSize)cellSize;

+ (NSString *)stringByTruncatingToWidth:(CGFloat)width withFont:(NSFont *)font withString:(NSString *)string;

@end
