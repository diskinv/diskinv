//
//  DIXPreferenceClient.h
//  Disk Inventory X
//
//  Replacement for OAPreferenceClient
//

#import <Cocoa/Cocoa.h>

@interface DIXPreferenceClient : NSViewController

- (void)restoreDefaultsNoPrompt;
- (BOOL)haveAnyDefaultsChanged;

@end
