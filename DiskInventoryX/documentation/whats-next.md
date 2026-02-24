# What's Next - Swift Rewrite

## Completed
- [x] Basic SwiftUI app structure
- [x] FileNode model (replaces FSItem)
- [x] FileScanner actor (async scanning)
- [x] TreeMapView with Canvas rendering
- [x] NavigationSplitView layout (sidebar, file list, treemap)
- [x] Settings view with @AppStorage
- [x] Ported original treemap layout algorithm from TMVItem.m
- [x] Cushion shading with depth-based brightness
- [x] Fixed "Other Space" / "Free Space" to only show on volume roots

## High Priority
- [ ] Add the app icon - copy from `src/Disk Inventory Icon.png`
- [ ] Universal Binary - add x86_64 architecture for Intel Macs
- [ ] Test with large directories for performance

## Features to Add
- [ ] Drag & drop - drop folders onto window to scan
- [ ] Zoom animations - smooth transitions when zooming in/out
- [ ] Selection sync - click in treemap highlights in file list and vice versa
- [ ] Keyboard navigation - arrow keys to navigate treemap
- [ ] Context menu in treemap - Show in Finder, Move to Trash, etc.

## Polish
- [ ] Full Disk Access - prompt user for permission, handle protected folders
- [ ] Localizations - port German/Spanish/French from original `src/*.lproj`
- [ ] Menu bar - add View menu for zoom controls, sidebar toggles
- [ ] Recent documents - remember recently scanned folders
- [ ] Window restoration - remember window size/position

## Testing
- [ ] Large directories - test performance on folders with 100k+ files
- [ ] Memory profiling - check for leaks with Instruments
- [ ] Edge cases - empty folders, permission denied, symlinks

## Future Enhancements
- [ ] File type filtering - show/hide specific file types
- [ ] Search - find files by name within scanned folder
- [ ] Comparison - compare two scans to see what changed
- [ ] Export - save scan results to file for later viewing
