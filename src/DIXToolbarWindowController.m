//
//  DIXToolbarWindowController.m
//  Disk Inventory X
//
//  Replacement for OAToolbarWindowController
//

#import "DIXToolbarWindowController.h"

@implementation DIXToolbarWindowController {
    NSDictionary *_toolbarConfiguration;
}

- (NSString *)toolbarConfigurationName {
    // Override in subclass or return class-based name
    return NSStringFromClass([self class]);
}

- (NSDictionary *)toolbarConfiguration {
    if (!_toolbarConfiguration) {
        NSString *name = [self toolbarConfigurationName];
        NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"toolbar"];
        if (path) {
            _toolbarConfiguration = [NSDictionary dictionaryWithContentsOfFile:path];
        }
    }
    return _toolbarConfiguration;
}

- (NSDictionary *)toolbarInfoForItem:(NSString *)identifier {
    return self.toolbarConfiguration[@"items"][identifier];
}

#pragma mark - NSToolbarDelegate

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return self.toolbarConfiguration[@"defaultItems"] ?: @[];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return self.toolbarConfiguration[@"allowedItems"] ?: @[];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {

    NSDictionary *info = [self toolbarInfoForItem:itemIdentifier];
    if (!info) return nil;

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];

    // Set label from info or localized string
    NSString *label = info[@"label"];
    if (label) {
        item.label = NSLocalizedString(label, nil);
        item.paletteLabel = item.label;
    }

    // Set tooltip
    NSString *toolTip = info[@"toolTip"];
    if (toolTip) {
        item.toolTip = NSLocalizedString(toolTip, nil);
    }

    // Set image
    NSString *imageName = info[@"imageName"];
    if (imageName) {
        item.image = [NSImage imageNamed:imageName];
    }

    // Set action
    NSString *actionString = info[@"action"];
    if (actionString) {
        if (![actionString hasSuffix:@":"]) {
            actionString = [actionString stringByAppendingString:@":"];
        }
        item.action = NSSelectorFromString(actionString);
    }

    // Set target
    NSString *targetPath = info[@"target"];
    if (targetPath) {
        item.target = [self valueForKeyPath:targetPath];
    }

    // Modern bordered style (macOS 10.15+)
    if (@available(macOS 10.15, *)) {
        item.bordered = YES;
    }

    return item;
}

@end
