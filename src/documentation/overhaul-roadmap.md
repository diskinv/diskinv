# Swift Overhaul Roadmap

Status of the modernization pass on the shipping `src/` AppKit codebase, and the
work that remains. Generated from a multi-agent review of all Swift files.

## Context: which code is live

This repo contains the **shipping AppKit app** under `src/` (entry point
`main.swift` → `NSApplicationMain` → `MainMenu.nib`; built by `src/BuildRelease.sh`
and `notarize.sh`). A separate SwiftUI project that used to sit under
`DiskInventoryX/` was **orphaned dead code** (never wired into any build) and has
been deleted; the maintained SwiftUI rewrite lives in the sibling "Disk Inventory Y"
repo. All modernization below targets the `src/` AppKit code.

## Done (this branch, build-verified)

These were mechanical or internal-only changes, each verified with a clean
`xcodebuild` Debug build and committed:

- **Deprecated API removal**
  - `AppsForItem`: LaunchServices `LSCopy*` / `NSWorkspace.openFile` →
    `NSWorkspace.urlForApplication(toOpen:)` / `urlsForApplications(toOpen:)` /
    `open(_:withApplicationAt:configuration:)`, availability-gated (macOS 12 / 10.15)
    with the legacy LaunchServices path kept as the `< target` fallback.
  - `FSItem` + `NTFilePasteboardSource`: CoreServices `kUTType*` /
    `UTTypeConformsTo` / `UTTypeCopyDescription` → `UniformTypeIdentifiers.UTType`
    (`.conforms(to:)`, `.localizedDescription`), availability-gated for macOS 11+.
- **`Timing`**: `mach_absolute_time` + `mach_timebase_info` →
  `DispatchTime.now().uptimeNanoseconds`; public `getTime()/subtractTime()` API
  preserved byte-for-byte.
- **Model collections**: private `NSMutableArray/Dictionary/Set` storage in
  `FSItem`, `FileSystemDoc`, `FileKindStatistic`, `FSItemIndex` → native Swift
  collections; selector-based `sort(using:)` → Swift `sort(by:)`. Every
  `@objc`/KVC/binding-exposed signature and all `willChangeValue/didChangeValue`
  plumbing was preserved.
- **Deferred calls / menus**: `RunLoop.perform(NSSelectorFromString(...))` →
  `DispatchQueue.main.async` typed calls; `addItem/removeItem(at:)` menu
  index-juggling → `menu.items = mapped array` ("Open With", zoom stack).
- **Dead code**: removed the permanently-dead `menu(for:)` branch in `DIXTableView`.

## Deferred — needs Interface Builder surgery and/or a running-app smoke test

Everything below was **intentionally not auto-applied**. The shipping app is
nib-driven, and these changes touch runtime wiring whose correctness the Swift
compiler cannot check: a wrong move silently breaks the UI (no update, blank pane,
launch crash) without a build error. Each needs `.xib`/`.nib` edits and/or a manual
run of the app to verify. Listed by reward-to-risk.

### 1. KVO → `NSKeyValueObservation` sweep  (Med effort / Med impact)
**Files:** `FileSystemDoc`, `FilesOutlineViewController`, `SelectionListController`,
`SelectionListTableController`, `FileKindsTableController`, `FileKindsPopupController`,
`DrivesPanelController`.
Replace `addObserver(forKeyPath:options:context:)` + `observeValue(forKeyPath:)`
raw-context KVO and selector-based `NotificationCenter` observers with
`NSKeyValueObservation` tokens / block-based observers, dropping the
`windowWillClose` teardown methods.
**Why deferred:** behavioral, not mechanical — it changes *when* observers fire and
are torn down. Several observed keys (`arrangedObjects`, `selection`, user-defaults
string keys) have **no typed Swift keypath**, so they can't use
`NSKeyValueObservation` at all and must stay string-based. A lifecycle slip (retain
cycle, token freed early) silently stops UI refresh with no compile error. Do this
file-by-file with an app smoke-test after each.

### 2. Drop `GenericArrayController` → diffable data sources + view-based cells  (High / High)
**Files:** `GenericArrayController` (276 lines), `ImageAndTextCell` (~120 lines), and
the controllers that consume them (`FilesOutlineViewController`,
`SelectionListController`, `SelectionListTableController`, `FileKindsTableController`,
`FileKindsPopupController`, `DrivesPanelController`).
Replace the hand-rolled `NSArrayController` subclass + cell-based tables with plain
Swift model arrays driving `NSTableViewDiffableDataSource` /
`NSOutlineViewDiffableDataSource`, and replace `ImageAndTextCell` +
`willDisplayCell:` icon/swatch/progress-bar hacks with view-based `NSTableCellView`.
**Why deferred:** the nibs bind columns/selection/content to the array controllers
and use cell-based columns (`dataCell`). Rewiring requires editing `MainMenu.nib` /
`TreeMap.nib` and removing the bindings; a mismatch crashes or yields empty tables at
runtime. Biggest single cleanup, but must be done with the app open. The
`FileKindsPopupController` "(all kinds)" sentinel (`NSDictionary.isAllFileKindsItem`)
should become an `enum KindSelection { case all; case kind(FileKindStatistic) }` as
part of this.

### 3. `NTTitledInfoView` stack → `NSGridView`  (High / High)
**Files:** `NTTitledInfoView` (452 lines), its private `NTFastTextView`,
`NTTitledInfoPair`, `NTInfoView`, `DIXFileInfoView`, `InfoPanelController`.
Replace the hand-drawn two-column info layout (`NSDivideRect` math, alternating
backgrounds, `disableFlushing()`, custom string-drawing view) with an `NSGridView`
(two columns: right-aligned bold titles, left-aligned values). ~600 lines deleted,
real text selection, automatic sizing.
**Why deferred:** the info panel is nib-loaded and the view hierarchy is wired in IB;
rebuilding it as `NSGridView` is a panel redesign that needs visual verification.
Also fix the **`NTInfoView.sizePairs()` stub** (currently returns `[]` — folder
size/capacity in the info panel is silently disabled) as part of this, via
`URLResourceValues` (`.totalFileAllocatedSize`, `.volumeAvailableCapacity`).

### 4. `.toolbar`-plist subsystem → modern `NSToolbar`  (High / High)
**Files:** `OAToolbarWindowControllerEx`, `DIXToolbarWindowController`, the `.toolbar`
plist, `MainMenu.nib`.
Replace the plist-driven toolbar construction (KVC target resolution,
`NSMutableDictionary` image caches, menu-derived labels) with a storyboard/code
`NSToolbar` + standard `NSToolbarItem`/`NSToolbarItemGroup` and
`NSToolbarItemValidation`.
**Why deferred:** the toolbar identity/items live in the plist + nib; this is a
window-chrome rewrite that must be eyeballed in a running window. Bumping the
deployment target past 10.15 also lets `NSToolbarItem.title` and `isBordered` drop
their `#available` guards here.

### 5. `NSDrawer` → split-view / popover  (High / High)
**Files:** `MainWindowController` (the `_kindsDrawer` / `_selectionListDrawer`
`NSDrawer`s), and the drawer-open/close observers in `SelectionListTableController`.
`NSDrawer` has been deprecated since 10.13. Move the kinds and selection-list panes
into an `NSSplitViewController` sidebar/inspector (or `NSPopover` for the kinds list).
**Why deferred:** drawers are instantiated and wired in the nib; replacing them is a
window-layout change requiring IB work and visual verification. Unblocks the
drawer-driven array-controller suspend/resume machinery in
`SelectionListTableController`.

### 6. Async scanning  (High / Med)
**Files:** `LoadingPanelController` (manual `runModalSession` + `RunLoop.run(until:)`
pump, hand-throttled 5 Hz refresh), `FSItem` (cancellation threaded through delegate
callbacks).
Move the scan off the main actor with `async`/`await` + `Task.checkCancellation()`
and drive a progress sheet from `@MainActor` updates.
**Why deferred:** restructures the core scan control flow and its modal UI; high blast
radius, needs end-to-end runtime testing (scan a large volume, cancel mid-scan).

### 7. `FileSystemDoc` notifications → `@Observable`  (High / Med)
Replace the manual `willChangeValue/didChangeValue` surface and untyped
`NSNotification.Name` + `userInfo` dictionaries with the Observation framework.
**Why deferred:** ripples through every observer (the controllers and the nib
bindings) at once; only worth doing after items 1–2 modernize those observers.

## Suggested sequencing for the deferred work

1. KVO sweep (item 1) — file by file, smoke-test each. Lowest blast radius.
2. Array-controller / view-based-cell migration (item 2) — the central cleanup;
   subsumes much of the leftover KVO glue and removes `ImageAndTextCell`.
3. `NSGridView` info panel (item 3) + the `sizePairs()` fix.
4. Modern `NSToolbar` (item 4) and `NSDrawer` removal (item 5) — independent window
   chrome; can be done in either order.
5. Async scanning (item 6), then `@Observable` doc model (item 7) — the deepest
   architectural changes, last.

Each step should land as its own PR with a manual smoke test (launch, scan a folder,
zoom in/out, open the info panel, toggle kind colors, drag a file out).
