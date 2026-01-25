//
//  NTFilePasteboardSource.m
//  Path Finder
//
//  Created by Steve Gehrman on Sun Feb 02 2003.
//  Copyright (c) 2003 CocoaTech. All rights reserved.
//

#import "NTFilePasteboardSource.h"
#import <OmniAppKit/OAPasteboardHelper.h>
#import "NSURL-Extensions.h"

// SNG 666 add NSPICTPboardType

@interface NTFilePasteboardSource (Private)
- (NSArray<NSString*>*)pasteboardTypes:(NSArray<NSPasteboardType> *)types;
@end

@implementation NTFilePasteboardSource

- (id)initWithURLs:(NSArray<NSURL*>*)URLs;
{
    self = [super init];

    _URLs = [URLs retain];

    return self;
}

- (void)dealloc;
{
    [_URLs release];

    [super dealloc];
}

+ (NSArray<NSPasteboardType>*)defaultTypes;
{
    return [NSArray arrayWithObjects:
        NSTIFFPboardType,
        NSPDFPboardType,
        NSPostScriptPboardType,

        NSRTFPboardType,
        NSRTFDPboardType,
        NSHTMLPboardType,

        NSFileContentsPboardType,

        NSFilenamesPboardType,
        NSStringPboardType,
        nil];
}

+ (NSArray<NSPasteboardType>*)imageTypes;
{
    return [NSArray arrayWithObjects:
        NSTIFFPboardType,
        NSPDFPboardType,
        NSPostScriptPboardType,
        nil];
}

+ (NTFilePasteboardSource*)file:(NSURL *)URL toPasteboard:(NSPasteboard *)pboard types:(NSArray<NSPasteboardType> *)types;
{
    return [NTFilePasteboardSource files:[NSArray<NSURL*> arrayWithObject:URL] toPasteboard:pboard types:types];
}

+ (NTFilePasteboardSource*)files:(NSArray<NSURL*> *)URLs toPasteboard:(NSPasteboard *)pboard types:(NSArray<NSPasteboardType> *)types;
{
    NTFilePasteboardSource* source = [[[NTFilePasteboardSource alloc] initWithURLs:URLs] autorelease];
    OAPasteboardHelper *helper;
    NSArray<NSPasteboardType>* pasteboardTypes = [source pasteboardTypes:types];

    if (pasteboardTypes)
    {
        helper = [OAPasteboardHelper helperWithPasteboard:pboard];

        // the helper is retained for as long as it stays in the pasteboard, the source is retained by the helper
        [helper declareTypes:pasteboardTypes owner:source];
    }

    return source;
}

@end

@implementation NTFilePasteboardSource (Private)

- (NSArray<NSPasteboardType>*)pasteboardTypes:(NSArray<NSPasteboardType> *)types;
{
    if ([_URLs count])
    {
        NSURL* url = [_URLs objectAtIndex:0];

        // figure out what type of file the current selection is
        if (url)
        {
            NSMutableArray<NSPasteboardType> *pasteTypes = [NSMutableArray<NSPasteboardType> array];
            NSString* uti = [url UTI];
            
            for (NSString *type in types)
            {
                if ([type isEqualToString:NSFilenamesPboardType])
                    [pasteTypes addObject:type];
                else if ([type isEqualToString:NSStringPboardType])
                    [pasteTypes addObject:type];
                else if ([type isEqualToString:NSFileContentsPboardType])
                    [pasteTypes addObject:type];
                else if ([type isEqualToString:NSTIFFPboardType]) // we use the icon if not an image, so don't check isImage && [identifier isImage])
                    [pasteTypes addObject:type];
                else if ([type isEqualToString:NSRTFPboardType] && [uti isEqualToString: (__bridge NSString *)kUTTypeRTF])
                    [pasteTypes addObject:type];
                else if ([type isEqualToString:NSRTFDPboardType] && [uti isEqualToString: (__bridge NSString *)kUTTypeFlatRTFD])
                    [pasteTypes addObject:type];
                else if ([type isEqualToString:NSHTMLPboardType] && [uti isEqualToString: (__bridge NSString *)kUTTypeHTML])
                    [pasteTypes addObject:type];
                else if ([type isEqualToString:NSPDFPboardType] && [uti isEqualToString: (__bridge NSString *)kUTTypePDF])
                    [pasteTypes addObject:type];
            }

            if ([pasteTypes count])
                return pasteTypes;
        }
    }

    return nil;
}

- (void)pasteboard:(NSPasteboard *)pboard provideDataForType:(NSString *)type
{
    if (_URLs && [_URLs count])
    {
        NSURL* url = [_URLs objectAtIndex:0];

        if (url)
        {
            NSString* uti = [url UTI];

            if ([type isEqualToString:NSFilenamesPboardType])
            {
                NSMutableArray* pathsArray = [NSMutableArray array];

                for (url in _URLs)
                    [pathsArray addObject:[url path]];

                [pboard setPropertyList:pathsArray forType:NSFilenamesPboardType];
            }
            else if ([type isEqualToString:NSStringPboardType])
            {
                // set the path
                [pboard setString:[url path] forType:NSStringPboardType];
            }
            else if ([type isEqualToString:NSFileContentsPboardType])
            {
                // write the contents
                [pboard writeFileContents:[url path]];
            }
            else if ([type isEqualToString:NSTIFFPboardType])
            {
                if ([uti isEqualToString: (__bridge NSString *)kUTTypeTIFF])
                    [pboard setData:[NSData dataWithContentsOfFile:[url path]] forType:NSTIFFPboardType];
                else if ( UTTypeConformsTo((__bridge CFStringRef)uti, kUTTypeImage) )
                {
                    // open the image and return TIFFRepresentation
                    NSImage *image = [[[NSImage alloc] initWithContentsOfFile:[url path]] autorelease];

                    if (image)
                    {
                        NSData* data = [image TIFFRepresentation];

                        if (data)
                            [pboard setData:data forType:NSTIFFPboardType];
                    }
                }
                else // else send the icon
                {
#pragma warning "NTFilePasteBoardSource: providing file icon not implemented"
 /*                   // open the image and return TIFFRepresentation
                    NSImage* image = [NSImage iconRef:[[desc icon] iconRef] toImage:128 label:[desc label] select:NO];

                    if (image)
                    {
                        NSData* data = [image TIFFRepresentation];

                        if (data)
                            [pboard setData:data forType:NSTIFFPboardType];
                    }                    
 */
                }
            }
            else if ([type isEqualToString:NSRTFPboardType])
            {
                if ([uti isEqualToString: (__bridge NSString *)kUTTypeRTF])
                    [pboard setData:[NSData dataWithContentsOfFile:[url path]] forType:NSRTFPboardType];
            }
            else if ([type isEqualToString:NSRTFDPboardType])
            {
                if ([uti isEqualToString: (__bridge NSString *)kUTTypeFlatRTFD])
                {
                    NSFileWrapper *tempRTFDData = [[[NSFileWrapper alloc] initWithPath:[url path]] autorelease];
                    [pboard setData:[tempRTFDData serializedRepresentation] forType:NSRTFDPboardType];
                }
            }
            else if ([type isEqualToString:NSHTMLPboardType])
            {
                if ([uti isEqualToString: (__bridge NSString *)kUTTypeHTML])
                    [pboard setData:[NSData dataWithContentsOfFile:[url path]] forType:NSHTMLPboardType];
            }
            else if ([type isEqualToString:NSPDFPboardType])
            {
                if ([uti isEqualToString: (__bridge NSString *)kUTTypePDF])
                    [pboard setData:[NSData dataWithContentsOfFile:[url path]] forType:NSPDFPboardType];
            }
        }
    }
}

@end
