//
//  Shim.swift
//  Disk Inventory X
//
//  Placeholder Swift entry point for the project. Exists so the build
//  pipeline (Swift compiler, .swiftmodule generation, ObjC-to-Swift
//  bridging header, Swift-to-ObjC generated header) is wired into the
//  target and ready to host real ported code.
//
//  How to expand:
//   - Add more .swift files alongside this one. They'll get compiled
//     into the same module ("Disk_Inventory_Xs"), no further pbxproj
//     changes needed.
//   - To call Swift from ObjC: `#import "Disk_Inventory_Xs-Swift.h"`
//     in the .m file. That generated header exposes every @objc class
//     and method.
//   - To call ObjC from Swift: add the ObjC header you need to
//     `Disk Inventory X-Bridging-Header.h`. The header is currently
//     minimal (only <Cocoa/Cocoa.h>) so it doesn't transitively pick
//     up the .pch macros, which would fail to compile in the bridging
//     context.
//
//  This shim class is intentionally empty. Removing it would unwire
//  Swift from the target.
//

import Foundation

@objc(DIXSwiftShim)
public final class DIXSwiftShim: NSObject {

    /// True if Swift code is reachable from ObjC at runtime. Call from
    /// any .m file via `[DIXSwiftShim isReady]` to sanity-check the
    /// Swift/ObjC bridge.
    @objc public class func isReady() -> Bool {
        return true
    }
}
