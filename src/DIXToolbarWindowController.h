//
//  DIXToolbarWindowController.h
//  Disk Inventory X
//
//  Replacement for OAToolbarWindowController
//

#import <Cocoa/Cocoa.h>

@interface DIXToolbarWindowController : NSWindowController <NSToolbarDelegate>

@property (nonatomic, readonly) NSString *toolbarConfigurationName;
@property (nonatomic, readonly) NSDictionary *toolbarConfiguration;

- (NSDictionary *)toolbarInfoForItem:(NSString *)identifier;

@end
