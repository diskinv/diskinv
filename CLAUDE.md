# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains **Disk Inventory Xs** (the "s" stands for Silicon) - the original Objective-C version of Disk Inventory X, modernized to run on Apple Silicon.

The Swift rewrite (**Disk Inventory Y**) lives in a separate repository at `../DIY`.

## Build Commands

```bash
# Build release version (from repo root)
cd src && ./BuildRelease.sh

# Or directly with xcodebuild
cd src && xcodebuild -project "Disk Inventory X.xcodeproj" -configuration Release

# Build TreeMapView framework separately
cd treemap && xcodebuild -project "TreeMapView.xcodeproj" -configuration Release
```

The build script builds both the TreeMapView framework and the main app, then renames the output to "Disk Inventory Xs".

No test suite exists. Benchmarking is available via `performRenderBenchmark` and `performLayoutBenchmark` methods in MainWindowController.

## Architecture Overview

Disk Inventory Xs is a macOS Cocoa application (Objective-C) that visualizes disk space usage using treemaps. It follows a document-based architecture with NSDocument/NSDocumentController patterns.

### Directory Structure

- `src/` - Main application source code
- `treemap/` - TreeMapView.framework source code

### Core Data Model

- **FSItem** (`FSItem.h/m`): Hierarchical representation of file system items. Root data structure for the entire scanned directory tree. Handles loading children, size calculation, and pasteboard operations. Uses delegate pattern for customization (e.g., `fsItemEnteringFolder:`, `fsItemShouldIgnoreCreatorCode:`).

- **FileSystemDoc** (`FileSystemDoc.h/m`): NSDocument subclass managing the scanned file system state. Contains the root FSItem, zoom stack for navigation, file kind statistics, and view options. Posts notifications for state changes.

- **FileKindStatistic**: Tracks count and total size of files by kind (e.g., all MP3 files). Defined within FileSystemDoc.h.

### Key Notifications

Components communicate via NSNotificationCenter:
- `GlobalSelectionChangedNotification` - selection changed
- `ZoomedItemChangedNotification` - user zoomed into/out of folder
- `FSItemsChangedNotification` - items modified, deleted, or added
- `ViewOptionChangedNotification` - display options changed

### External Frameworks

- **TreeMapView.framework** - Treemap visualization rendering (in `treemap/` directory)

Note: The original Omni Group frameworks have been removed and replaced with native implementations.

### View Controllers

- `MainWindowController` - Primary window coordination
- `TreeMapViewController` - Treemap visualization
- `FilesOutlineViewController` - Left-side file browser
- `FileKindsTableController` - File kind statistics drawer
- `SelectionListController` - Selection list drawer

## Key Design Patterns

- **Document-based app**: Uses NSDocument lifecycle for per-scan state
- **Notification-based**: Loose coupling between UI components
- **Delegate pattern**: FSItem customization without subclassing
- **Value transformers**: `FileSizeTransformer`, `VolumeNameTransformer` for bindings

## macOS Considerations

- Minimum deployment: macOS 10.13+
- Universal binary: Apple Silicon (arm64) and Intel (x86_64)
- Handles privacy-protected folders (Documents, Desktop, Downloads, etc.) with appropriate permission descriptors
- Dark mode support (10.14+)
- Retina display support for treemap rendering

## License

GPL v3
