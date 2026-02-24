# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build release version
./BuildRelease.sh

# Or directly with xcodebuild
xcodebuild -project "Disk Inventory X.xcodeproj" -configuration Release

# Build debug version
xcodebuild -project "Disk Inventory X.xcodeproj" -configuration Debug
```

No test suite exists. Benchmarking is available via `performRenderBenchmark` and `performLayoutBenchmark` methods in MainWindowController.

## Architecture Overview

Disk Inventory X is a macOS Cocoa application (Objective-C) that visualizes disk space usage using treemaps. It follows a document-based architecture with NSDocument/NSDocumentController patterns.

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

Located in project directory:
- **TreeMapView.framework** - Treemap visualization rendering
- **OmniAppKit/OmniFoundation/OmniBase** - Omni Group utility frameworks

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
- 64-bit Intel only
- Handles privacy-protected folders (Documents, Desktop, Downloads, etc.) with appropriate permission descriptors
- Dark mode support (10.14+)
- Retina display support for treemap rendering

## License

GPL v3
