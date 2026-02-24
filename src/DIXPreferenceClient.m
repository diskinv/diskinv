//
//  DIXPreferenceClient.m
//  Disk Inventory X
//
//  Replacement for OAPreferenceClient
//

#import "DIXPreferenceClient.h"

@implementation DIXPreferenceClient

- (void)restoreDefaultsNoPrompt {
    // Override in subclass if needed
}

- (BOOL)haveAnyDefaultsChanged {
    // Override in subclass if needed
    return NO;
}

@end
