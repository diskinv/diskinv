//
//  DIXPreferenceController.h
//  Disk Inventory X
//
//  Replacement for OAPreferenceController
//

#import <Cocoa/Cocoa.h>

@interface DIXPreferenceController : NSWindowController

+ (NSArray *)allClientRecords;
- (void)showPreferencesPanel:(id)sender;

@end
