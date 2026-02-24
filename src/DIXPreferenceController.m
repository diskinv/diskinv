//
//  DIXPreferenceController.m
//  Disk Inventory X
//
//  Replacement for OAPreferenceController
//

#import "DIXPreferenceController.h"

@implementation DIXPreferenceController

+ (NSArray *)allClientRecords {
    // Return empty array - not using client record system
    return @[];
}

+ (void)registerItemName:(NSString *)itemName bundle:(NSBundle *)bundle description:(NSDictionary *)description {
    // No-op - not using registration system
}

- (void)showPreferencesPanel:(id)sender {
    [self.window center];
    [self showWindow:sender];
}

- (void)_restoreDefaultsSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
    // Stub implementation
}

@end
