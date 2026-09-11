# Disk Inventory Xs

Disk Inventory Xs is a macOS 14 app for finding large files and folders. It shows a hierarchical file list beside a cushion-shaded treemap, with file-kind totals in a right inspector.

## Scan behavior

The scanner enumerates hidden entries and package contents. Metadata reads use a bounded parallel worker pool; the default setting of 0 uses all but one active CPU core. The package setting changes presentation only, so closing a package in the UI never removes its contents from the measured size. Symbolic links and Finder aliases appear as entries but are not followed.

macOS can deny access to protected paths. The app counts these failures and lists the first 500 after the scan instead of presenting unreadable directories as empty. Grant Full Disk Access in System Settings when a complete volume scan requires it.

Logical size and allocated size are available. Allocated size is summed per path, so hard links and APFS clones can make the total larger than the volume's unique physical blocks. Volume free-space arithmetic clamps at zero.

## Test and build

Run the scanner and treemap checks with Swift Package Manager:

```sh
swift test
```

Build the macOS app from the command line:

```sh
DiskInventoryX/BuildRelease.sh
```

The ad hoc signed local build is written to `DiskInventoryX/build/Release/Disk Inventory Xs.app`. Set `SIGN_IDENTITY` to a Developer ID Application identity when producing a distributable build.

## Source layout

- `DiskInventoryX/App` owns window state, scanning, selection, and commands.
- `DiskInventoryX/Models` contains immutable scan results.
- `DiskInventoryX/Services/FileScanner.swift` contains the filesystem walk.
- `DiskInventoryX/Views` contains the file list, treemap, file-kind inspector, and settings.
- `Tests/DiskInventoryCoreTests` checks enumeration and treemap geometry without launching the app.

## Credits and license

Tjark Derlien created Disk Inventory X. Disk Inventory Xs remains available under GPL v3; see `LICENSE`.
