//
//  NTTitledInfoView.m
//  Path Finder
//
//  Created by sgehrman on Mon Aug 06 2001.
//  Copyright (c) 2001 CocoaTech. All rights reserved.
//

#import "NTTitledInfoView.h"
//#import "NTGlyphBlitter.h"
#import "NTTitledInfoPair.h"

#define kColumnDivider 4

@interface NTFastTextView : NSView
{
    //NTGlyphBlitter *_blitter;
    NSString* _textString;
    NSDictionary *_attributes;
    SEL _action;
    id _target;
}

+ (NTFastTextView*)fastTextView:(NSString*)title action:(SEL)action target:(id)target attributes:(NSDictionary*)attributes;
- (NSSize)sizeForBounds:(NSRect)bounds;
//- (NTGlyphBlitter*)blitterForSize:(NSSize)size;
@end

// ========================================================================================

@interface NTTitledInfoView (Private)
- (CGFloat)totalHeight;
- (void)resizeFrameToFit;
- (void)reset;
- (void)createViews;
- (void)positionViews;
- (void)doDrawRect:(NSRect)rect;

- (void)resetBackgroundLineOffsets;
- (void)resetBackgroundShadowOffset;
- (void)drawBackgroundShadow;
- (void)drawBackgroundLines;

- (NSDictionary*)infoAttributes;
- (NSDictionary*)titleAttributes;

@end;

@implementation NTTitledInfoView

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];

    if (self)
    {
        [self setAutoresizesSubviews:YES];
        [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        [self reset];

        _horizontalOffset = 6;
        _verticalOffset = 6;
        _backgroundShadowOffset = 72;
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [_pairs release];
    [_titleViews release];
    [_infoViews release];

    [_backgroundLineOffsets release];

    [super dealloc];
}

- (void)setTarget:(id)target;
{
    _target = target;  // don't retain
}

- (BOOL)isFlipped;
{
    return YES;
}

- (void)setHorizontalOffset:(int)offset;
{
    _horizontalOffset = offset;
}

- (void)setVerticalOffset:(int)offset;
{
    _verticalOffset = offset;
}

- (void)setWithArray:(NSArray*)pairs;
{
    // clear out the existing views
    [self reset];

    if (pairs)
    {
        _pairs = [pairs mutableCopy];

        [self createViews];
        [self positionViews];
    }

    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect;
{
    NSWindow *viewWindow = [self window];
    BOOL disabledFlush = NO;
    
    // disable window flush for speed
    if ([viewWindow isFlushWindowDisabled])
    {
        disabledFlush = YES;
        [viewWindow disableFlushWindow];
    }
    
    [self doDrawRect:rect];
    
    // restore 
    if (disabledFlush)
        [viewWindow enableFlushWindow];    
}

// set to resize automatically for the width
- (void)resizeSubviewsWithOldSize:(NSSize)oldBoundsSize
{
    if (!_inFrameChanged)
    {
        _inFrameChanged = YES;
        
        NSWindow *viewWindow = [self window];
        BOOL disabledFlush = NO;
        
        // disable window flush for speed
        if ([viewWindow isFlushWindowDisabled])
        {
            disabledFlush = YES;
            [viewWindow disableFlushWindow];
        }
        
        // first must set a valid frame
        NSScrollView* scrollView = [self enclosingScrollView];
        [self setFrame:[scrollView documentVisibleRect]];
        
        [self positionViews];
        
        // restore 
        if (disabledFlush)
            [viewWindow enableFlushWindow];   
        
        _inFrameChanged = NO;
    }
}

@end

@implementation NTTitledInfoView (Private)

- (void)doDrawRect:(NSRect)rect
{
    [self drawBackgroundShadow];
    [self drawBackgroundLines];
    
    [super drawRect:rect];
}

- (void)resizeFrameToFit;
{
    NSScrollView* scrollView = [self enclosingScrollView];
    CGFloat height = [self totalHeight];

    if (height != 0)
    {
        NSSize newSize = {[scrollView documentVisibleRect].size.width, height};
        
        // never be smaller than the current visible rect
        newSize.height = MAX(newSize.height, [scrollView documentVisibleRect].size.height);
        newSize.width = MAX(newSize.width, [scrollView documentVisibleRect].size.width);
        
        if (newSize.height != [self frame].size.height || newSize.width != [self frame].size.width)
            [self setFrameSize:NSMakeSize(newSize.width, newSize.height)];
    }
    else
        [self setFrameSize:[scrollView documentVisibleRect].size];
    
    [self resetBackgroundShadowOffset];
    [self resetBackgroundLineOffsets];
}

- (void)reset;
{
    int i, cnt;
    NTFastTextView* view;

    cnt = [_titleViews count];
    for (i=0;i<cnt;i++)
    {
        view = [_titleViews objectAtIndex:i];
        [view removeFromSuperview];
    }

    cnt = [_infoViews count];
    for (i=0;i<cnt;i++)
    {
        view = [_infoViews objectAtIndex:i];
        [view removeFromSuperview];
    }

    [_titleViews release];
    _titleViews = [[NSMutableArray alloc] init];

    [_infoViews release];
    _infoViews = [[NSMutableArray alloc] init];

    [_pairs release];
    _pairs = nil;

    _titleWidth = 0;
    
    [self resizeFrameToFit];
}

- (void)createViews;
{
    int i, cnt = [_pairs count];

    for (i=0;i<cnt;i++)
    {
        NTTitledInfoPair* pair = [_pairs objectAtIndex:i];
        NSSize titleSize;
        NTFastTextView* titleView;
        NTFastTextView* infoView;

        // init the text views
        titleView = [NTFastTextView fastTextView:[pair title] action:nil target:nil attributes:[self titleAttributes]];
        [_titleViews addObject:titleView];
        [self addSubview:titleView];

        infoView = [NTFastTextView fastTextView:[pair info] action:[pair action] target:[pair target] attributes:[self infoAttributes]];
        [_infoViews addObject:infoView];
        [self addSubview:infoView];

        // calc the widest title
        titleSize = [titleView sizeForBounds:NSMakeRect(0,0,1000, 10000)];
        if (titleSize.width > _titleWidth)
            _titleWidth = titleSize.width;
    }
}

- (void)positionViews;
{        
    int i,cnt=[_titleViews count];
    
    if (cnt)
    {
        NSRect rect = NSInsetRect([self bounds], _horizontalOffset, _verticalOffset);
        NSRect rectBetween,itemRect, titleRect, infoRect;
        NTFastTextView* titleView, *infoView;
        NSSize titleSize, infoSize;
        
        rect.size.width = MAX((_titleWidth+100), rect.size.width);  // enforce a minimum width
        rect.size.height = 10000;  // give enough vertical room to work with
        
        NSDivideRect(rect, &titleRect, &infoRect, _titleWidth+kColumnDivider, NSMinXEdge);
        NSDivideRect(infoRect, &rectBetween, &infoRect, kColumnDivider, NSMinXEdge);
        
        for (i=0;i<cnt;i++)
        {
            titleView = [_titleViews objectAtIndex:i];
            infoView = [_infoViews objectAtIndex:i];
            
            titleSize = [titleView sizeForBounds:titleRect];
            infoSize = [infoView sizeForBounds:infoRect];
            
            NSDivideRect(titleRect, &itemRect, &titleRect, MAX(titleSize.height, infoSize.height), NSMinYEdge);
            itemRect.size.height = titleSize.height;
            [titleView setFrame:itemRect];
            
            NSDivideRect(infoRect, &itemRect, &infoRect, MAX(titleSize.height, infoSize.height), NSMinYEdge);
            itemRect.size.height = infoSize.height;
            [infoView setFrame:itemRect];
        }
    }
    
    [self resizeFrameToFit];
}

- (CGFloat)totalHeight;
{
    CGFloat height=0;

    // just look at the last infoView
    if ([_infoViews count])
    {
        height = _verticalOffset*2;
        
        NTFastTextView* view = [_infoViews objectAtIndex:[_infoViews count]-1];

        height = NSMaxY([view frame]) + _verticalOffset;
    }

    return height;
}

// =========================================================================

- (void)resetBackgroundLineOffsets;
{    
    [_backgroundLineOffsets release];
    _backgroundLineOffsets = [[NSMutableArray alloc] init];
        
    if ([_infoViews count])
    {
        NSRect bounds = [self bounds];
        NSRect viewRect;
        
        // draw lines
        int i, cnt = [_infoViews count];
        for (i=0;i<cnt;i++)
        {
            viewRect = [[_infoViews objectAtIndex:i] frame];
            
            viewRect.size.width = bounds.size.width;
            viewRect.origin.y += viewRect.size.height - 1;
            
#if defined(CGFLOAT_IS_DOUBLE) && CGFLOAT_IS_DOUBLE
            [_backgroundLineOffsets addObject:[NSNumber numberWithDouble:viewRect.origin.y]];
#else
            [_backgroundLineOffsets addObject:[NSNumber numberWithFloat:viewRect.origin.y]];
#endif
        }
    }
}

- (void)resetBackgroundShadowOffset;
{    
    if ([_titleViews count])
    {
        NSRect bounds = [self bounds];
        NSRect viewRect = [[_titleViews objectAtIndex:0] frame];
        
        viewRect.size.height = bounds.size.height;
        viewRect.size.width += (kColumnDivider / 2) + (viewRect.origin.x - bounds.origin.x);
        
        _backgroundShadowOffset = viewRect.size.width;
    }
}

- (NSColor*)titleShadowColor;
{
    static NSColor *color = nil;
    
    if (!color)
        color = [[[NSColor colorWithCalibratedRed:0.6 green:0.6 blue:0.9 alpha:0.1] colorWithAlphaComponent:0.1] retain];
    
    return color;
}

- (NSColor*)infoLineColor;
{
    static NSColor *color = nil;
    
    if (!color)
        color = [[NSColor colorWithCalibratedRed:0.6 green:0.6 blue:0.9 alpha:0.1] retain];
    
    return color;
}

- (void)drawBackgroundShadow;
{
    NSRect viewRect = [self bounds];
    
    viewRect.size.width = _backgroundShadowOffset;
    
    [[self titleShadowColor] set];
    [NSBezierPath fillRect:viewRect];
}

- (void)drawBackgroundLines;
{
    NSRect bounds = [self bounds];
    NSRect viewRect = bounds;
    int i, cnt;
    
    NSColor *whiteLineColor = [[NSColor whiteColor] colorWithAlphaComponent:.7];
    if (@available(macOS 10.14, *))
        whiteLineColor = [NSColor separatorColor];
    
    // draw lines
    cnt = [_backgroundLineOffsets count];
    for (i=0;i<cnt;i++)
    {
        viewRect = bounds;
        
        viewRect.origin.y = [[_backgroundLineOffsets objectAtIndex:i] floatValue];
        viewRect.size.height = 1;
        
        viewRect.size.width += _backgroundShadowOffset;
        
        [whiteLineColor set];
        [NSBezierPath fillRect:viewRect];

        viewRect.origin.x += _backgroundShadowOffset;
        viewRect.size.width = bounds.size.width;

        [[self infoLineColor] set];
        [NSBezierPath fillRect:viewRect];
    }
    
    CGFloat lastLineHeight=12.0;
    if ([_backgroundLineOffsets count] > 2)
#if defined(CGFLOAT_IS_DOUBLE) && CGFLOAT_IS_DOUBLE
        lastLineHeight = [[_backgroundLineOffsets objectAtIndex:[_backgroundLineOffsets count]-1] doubleValue]
                       - [[_backgroundLineOffsets objectAtIndex:[_backgroundLineOffsets count]-2] doubleValue];
#else
        lastLineHeight = [[_backgroundLineOffsets objectAtIndex:[_backgroundLineOffsets count]-1] floatValue]
                       - [[_backgroundLineOffsets objectAtIndex:[_backgroundLineOffsets count]-2] floatValue];
#endif
    
    CGFloat maxBounds = MIN(NSMaxY(bounds), 10000.0); // had a strange bug where bounds was like 10e23 and looped forever, bounds was not set or negative or something
    while (viewRect.origin.y < maxBounds)
    {
        viewRect.origin.y += lastLineHeight;
        viewRect.size.height = 1.0;
        
        viewRect.origin.x = bounds.origin.x;
        viewRect.size.width += _backgroundShadowOffset;
        
        [whiteLineColor set];
        [NSBezierPath fillRect:viewRect];
        
        viewRect.origin.x = bounds.origin.x + _backgroundShadowOffset;
        viewRect.size.width = bounds.size.width;
        
        [[self infoLineColor] set];
        [NSBezierPath fillRect:viewRect];
    }
}

- (NSDictionary*)titleAttributes;
{
    static NSMutableDictionary* attributes = nil;
    
    if (!attributes)
    {
        attributes = [[NSMutableDictionary alloc] init];
        
        NSMutableParagraphStyle *paragraphStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
        
        [paragraphStyle setAlignment:NSRightTextAlignment];
        [paragraphStyle setLineBreakMode:NSLineBreakByWordWrapping];
        
        [attributes setObject:paragraphStyle forKey:NSParagraphStyleAttributeName];
        [attributes setObject:[NSFont boldSystemFontOfSize:10] forKey:NSFontAttributeName];
        
        [attributes setObject:[NSColor controlTextColor] forKey:NSForegroundColorAttributeName];
    }
    
    return attributes;
}

- (NSDictionary*)infoAttributes;
{
    static NSMutableDictionary* attributes = nil;
    
    if (!attributes)
    {
        attributes = [[NSMutableDictionary alloc] init];
                
        NSMutableParagraphStyle *paragraphStyle = [[[NSMutableParagraphStyle alloc] init] autorelease];
        
        [paragraphStyle setAlignment:NSLeftTextAlignment];
        [paragraphStyle setLineBreakMode:NSLineBreakByWordWrapping];
        
        [attributes setObject:paragraphStyle forKey:NSParagraphStyleAttributeName];
        [attributes setObject:[NSFont systemFontOfSize:10] forKey:NSFontAttributeName];
        
        [attributes setObject:[NSColor controlTextColor] forKey:NSForegroundColorAttributeName];
    }
    
    return attributes;
}

@end

// =====================================================================================================

@implementation NTFastTextView

- (id)initWithString:(NSString*)title action:(SEL)action target:(id)target attributes:(NSDictionary*)attributes;
{
    self = [super init];
    
    _textString = [title retain];
    _attributes = [attributes retain];
    _action = action;
    _target = target;
    
    return self;
}

+ (NTFastTextView*)fastTextView:(NSString*)title action:(SEL)action target:(id)target attributes:(NSDictionary*)attributes;
{
    NTFastTextView* result = [[NTFastTextView alloc] initWithString:title action:action target:target attributes:attributes];
    
    return [result autorelease];
}

- (void)dealloc;
{
    //[_blitter release];
    [_textString release];
    [_attributes release];
    
    [super dealloc];
}

- (void)mouseDown:(NSEvent*)event;
{
    if (_target)
        [NSApp sendAction:_action to:_target from:self];
}

- (BOOL)isFlipped;
{
    return YES;
}

- (NSSize)sizeForBounds:(NSRect)bounds;
{
	NSRect stringBounds = [_textString boundingRectWithSize: bounds.size
                                                    options: NSStringDrawingUsesLineFragmentOrigin
                                                 attributes: _attributes];
    
	return NSMakeSize( MIN(bounds.size.width, stringBounds.size.width), stringBounds.size.height );
/*
	NTGlyphBlitter* blitter = [self blitterForSize:bounds.size];
    
    return [blitter textRectForRect:bounds].size;
 */
}

- (void)drawRect:(NSRect)rect;
{
    NSRect bounds = [self bounds];
	
	[_textString drawInRect: bounds withAttributes: _attributes];
    
/*
	NTGlyphBlitter* blitter = [self blitterForSize:bounds.size];
    
    NSColor *backColor=nil, *textColor=nil;
    if (_target)
    {
        backColor = [[NSColor lightGrayColor] colorWithAlphaComponent:.4];
        textColor = [NSColor blackColor];
    }
    
    [blitter drawRect:bounds textColor:textColor backColor:backColor];
*/
}
/*
- (NTGlyphBlitter*)blitterForSize:(NSSize)size;
{
    if (_blitter)
    {
        if (size.width != [_blitter size].width)
        {
            [_blitter release];
            _blitter = nil;
        }
    }
    
    if (!_blitter)
    {        
        _blitter = [[NTGlyphBlitter blitterWithString:_textString 
                                                 size:size 
                                             numLines:0
                                     verticallyCenter:YES
                                           attributes:_attributes
                                            backColor:nil
                                       ovalBackground:(_target != nil)
                                            antialias:YES
                                               shadow:NO] retain];
    }
    
    return _blitter;
}
*/
@end

