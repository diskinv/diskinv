
#import <Cocoa/Cocoa.h>

@class NTID3;

@interface NTID3Helper : NSObject
{
    NTID3* _id3;
}

+ (NTID3Helper*)helperWithPath:(NSString*)path;

- (NSString*)infoString;
- (NSImage*)image;

@end
