//
//  main.m
//  Disk Accountant
//
//  Created by Tjark Derlien on Sun Oct 26 2003.
//
//  Copyright (C) 2003 Tjark Derlien.
//  
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 3
//  of the License, or any later version.
//

//

#import <Cocoa/Cocoa.h>

// Xcode generates this header from every @objc-exposed Swift declaration
// in the target. Imported here as a one-time sanity check that the
// Swift/ObjC bridge is live; can be removed once real Swift consumers
// exist elsewhere.
#import "Disk_Inventory_Xs-Swift.h"

int main(int argc, const char *argv[])
{
    NSCAssert([DIXSwiftShim isReady], @"Swift bridge not initialised");
    return NSApplicationMain(argc, argv);
}
