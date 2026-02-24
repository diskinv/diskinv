#import "NTID3Helper.h"
#import <CocoaTechID3/CocoaTechID3.h>
#import <CocoaTechStrings/NTLocalizedString.h>

@implementation NTID3Helper

- (id)initWithPath:(NSString*)path;
{
    self = [super init];
    
    _id3 = [[NTID3 alloc] initWithPath:path];
    
    return self;
}

- (void)dealloc;
{
    [_id3 release];
    [super dealloc];   
}

+ (NTID3Helper*)helperWithPath:(NSString*)path;
{
    NTID3Helper *result = [[NTID3Helper alloc] initWithPath:path];
    
    return [result autorelease];
}

- (NSString*)infoString;
{
    NSMutableString* result = [NSMutableString stringWithString:[NTLocalizedString localize:@"Title" table:@"mp3"]];
    NSString *tmp;
    
    [result appendFormat:@": %@\n", [_id3 title]];
    
    [result appendString:[NTLocalizedString localize:@"Artist" table:@"mp3"]];
    [result appendFormat:@": %@\n", [_id3 artist]];
    
    [result appendString:[NTLocalizedString localize:@"Album" table:@"mp3"]];
    [result appendFormat:@": %@\n", [_id3 album]];
    
    tmp = [_id3 duration];
    if ([tmp length])
    {
        [result appendString:[NTLocalizedString localize:@"Length" table:@"mp3"]];
        [result appendFormat:@": %@\n", tmp];
    }
    
    tmp = [_id3 year];
    if ([tmp length])
    {
        [result appendString:[NTLocalizedString localize:@"Year" table:@"mp3"]];
        [result appendFormat:@": %@\n", tmp];
    }
    
    tmp = [_id3 genre];
    if ([tmp length])
    {
        [result appendString:[NTLocalizedString localize:@"Genre" table:@"mp3"]];
        [result appendFormat:@": %@\n", tmp];
    }
    
    [result appendString:[NTLocalizedString localize:@"Audio" table:@"mp3"]];
    [result appendFormat:@": %@, %@, %@\n", [_id3 bitRate], [_id3 sampleRate], [_id3 channels]];
    
    [result appendString:[NTLocalizedString localize:@"Format" table:@"mp3"]];
    [result appendFormat:@": %@\n", [_id3 format]];
    
    tmp = [_id3 track];
    if ([tmp length])
    {
        [result appendString:[NTLocalizedString localize:@"Track" table:@"mp3"]];
        [result appendFormat:@": %@\n", tmp];
    }
    
    /*
     tmp = [_id3 comments];
     if ([tmp length])
     {
         [result appendString:[NTLocalizedString localize:@"Comment" table:@"mp3"]];
         [result appendFormat:@": %@\n", tmp];
     }
     */
    
    /*
     [result appendString:[NTLocalizedString localize:@"Media Type" table:@"mp3"]];
     [result appendFormat:@": %@ %@\n", [_id3 getVersionString], [_id3 getLayerString]];
     */
    
    return result;
}

- (NSImage*)image;
{
    return [_id3 image];
}

@end
