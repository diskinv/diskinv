//
//  NSURL-Extensions.h
//  DirectoryListingTest
//
//  Created by Tjark Derlien on 11.08.19.
//
//  Copyright (C) 2019 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

#import <Foundation/Foundation.h>

// Apple's documentation says: "For NSURL, all cached values (not temporary values) are automatically removed after each pass through the run loop."
// This NSURL category adds the functionality to duplicate needed values as temporary resource values (which are not removed by the framework).

@interface NSURL(AccessExtensions)


 #pragma mark --- functions to access NSURL resource keys (! removed after each pass through the run loop !) ---

- (BOOL) isFile;
- (BOOL) isDirectory;
- (BOOL) isVolume;
- (BOOL) isPackage;
- (BOOL) isAliasOrSymbolicLink;
- (BOOL) isFirmlink;
- (NSString*_Nonnull) name;
- (NSString*_Nonnull) displayName;
- (NSString*_Nonnull) displayPath;
- (NSString*_Nullable) UTI; // uniform type identifier
- (NSImage*_Nullable) icon;

- (NSNumber*_Nonnull) logicalSize;
- (NSNumber*_Nonnull) physicalSize;

- (NSDate*_Nonnull) creationDate;
- (NSDate*_Nonnull) modificationDate;

- (BOOL) stillExists; //works only for file URLs
- (BOOL) residesInDirectoryURL: (NSURL*_Nonnull) parentDir;

// volume info
- (BOOL) isLocalVolume;
- (NSNumber*_Nullable) volumeTotalCapacity;
- (NSNumber*_Nullable) volumeAvailableCapacity;
- (NSString*_Nonnull) volumeFormatName;

- (BOOL) isEqualToURL: (NSURL*_Nonnull) url;

- (BOOL) getBoolValue: (NSString*_Nonnull) ressourceName;
- (NSString*_Nullable) getStringValue: (NSString*_Nonnull) resourceName;
- (NSNumber*_Nullable) getNumberValue: (NSString*_Nonnull) resourceName;
- (NSDate*_Nullable) getDateValue: (NSString*_Nonnull) resourceName;

#pragma mark --- cached resource values (kept in memory as temporary resource keys) ---

- (BOOL) cachedIsFile;
- (BOOL) cachedIsDirectory;
- (BOOL) cachedIsVolume;
- (BOOL) cachedIsPackage;
- (BOOL) cachedIsAliasOrSymbolicLink;
- (NSString*_Nonnull) cachedName;
- (NSString*_Nonnull) cachedPath;
- (NSString*_Nonnull) cachedDisplayName;
- (NSString*_Nullable) cachedUTI; // uniform type identifier

- (NSNumber*_Nonnull) cachedLogicalSize;
- (NSNumber*_Nonnull) cachedPhysicalSize;

- (NSDate*_Nonnull) cachedCreationDate;
- (NSDate*_Nonnull) cachedModificationDate;

// volume info
- (BOOL) cachedIsLocalVolume;
- (NSNumber*_Nullable) cachedVolumeTotalCapacity;
- (NSNumber*_Nullable) cachedVolumeAvailableCapacity;
- (NSString*_Nonnull) cachedVolumeFormatName;


// cache a list of resources
- (void) cacheResourcesInArray: (NSArray<NSURLResourceKey>*_Nonnull) keys;

- (NSMutableDictionary*_Nonnull) resourceValueCache;

// get individual cached values (if not already cached they are load from NSURL)
- (BOOL) getCachedResourceValue:(out id _Nullable * _Nonnull)value forKey:(NSURLResourceKey _Nonnull )key error:(out NSError *_Nullable* _Nullable)error;
- (BOOL) getCachedBoolValue: (NSString * _Nonnull) ressourceName;
- (NSString*_Nullable) getCachedStringValue: (NSString*_Nonnull) resourceName;
- (NSNumber*_Nullable) getCachedNumberValue: (NSString*_Nonnull) resourceName;
- (NSDate*_Nullable) getCachedDateValue: (NSString*_Nonnull) resourceName;

@end
