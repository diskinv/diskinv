/* FilesOutlineViewController */

#import <Cocoa/Cocoa.h>
#import "FileSystemDoc.h"
#import "ImageAndTextCell.h"
#import "FileSizeFormatter.h"
#import "DIXOutlineView.h"

@interface FilesOutlineViewController : NSObject
{
    IBOutlet FileSystemDoc *_document;
    IBOutlet DIXOutlineView *_outlineView;
    IBOutlet NSMenu *_contextMenu;
}

- (FileSystemDoc*) document;

- (FSItem*) rootItem;

@end
