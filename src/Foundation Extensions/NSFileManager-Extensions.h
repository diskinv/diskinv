//
//  NSFileManager-Extensions.h
//  Disk Inventory X
//
//  Created by Tjark Derlien on 08.11.19.
//
//  Copyright (C) 2019 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSFileManager(PrivacyProtectedFolders)

// list of folders and files on local volume which are under macOS' privacy protection
- (NSArray<NSURL*>*) localPrivacyProtectedFolders;

// list of folders and files below the specified URL which are under macOS' privacy protection
- (NSArray<NSURL*>*) privacyProtectedFoldersInURL: (NSURL *)url;

// access the protected URLs to trigger macOS' consent dialogs
- (void) triggerConsentDialogForPrivacyProtectedFolders: (NSArray<NSURL*>*) urls;

// access the protected URLs residing below "url" to trigger macOS' consent dialogs
- (void) triggerCosentDialogForPrivacyProtectedFoldersInURL: (NSURL *)url;


@end

NS_ASSUME_NONNULL_END
