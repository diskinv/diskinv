# DIXKit: design

The engine of the next Disk Inventory X, built as libraries and command-line
tools so that scanning and drawing can each be tested and iterated on alone.
The app shell (phase 2) will sit on top and stay thin.

```
 folder ──dix-scan──▶ .dixsnap file ──dix-render──▶ PNG
          (DIXScan)    (DIXCore)       (DIXTreemap)
                                  └─dix-render-reference─▶ PNG drawn by the
                                     ORIGINAL app's treemap code (the bar to meet)
```

## The bar

1. **It must look like the original Disk Inventory X.** The original cushion
   treemap (`src/TreeMap/` on `origin/master`) is the visual reference. New
   rendering is compared side by side with `dix-render-reference` on the same
   snapshot. Where cells are big enough to see, the two should be
   indistinguishable. It may differ only where the original was buggy (below).
   A redesign, a new palette, flat colors, rounded corners, gaps between
   cells, or a different shading model are all out of scope. "Modern" is not a
   goal; faithful is.
2. **Fast.** Scanning should beat `du -sk` on the same folder. Rendering a
   full Retina window should feel instant.
3. **Correct about disk space.** Hard links count once, cloud placeholders
   count as what they occupy, nothing is followed twice, and nothing is
   downloaded or modified.

## Modules and ownership

| Path | What | Owner |
|---|---|---|
| `Sources/DIXCore/Snapshot.swift` | the data model: **the contract, change only with care** | shared |
| `Sources/DIXCore/SnapshotFile.swift` | `.dixsnap` read/write | scanner agent |
| `Sources/DIXCore/SnapshotCompression.swift` | compressed `.dixsnap` (LZFSE chunks) | scanner agent |
| `Sources/DIXCore/SnapshotEditing.swift` | `removing` / `replacingSubtree` without a rescan | scanner agent |
| `Sources/DIXScan/` | the scanner | scanner agent |
| `Sources/dix-scan/` | scan CLI | scanner agent |
| `Sources/DIXTreemap/` | layout, colors, cushion rendering, hit testing | treemap agent |
| `Sources/dix-render/` | render CLI (+ side-by-side comparison) | treemap agent |
| `Sources/dix-render-reference/` | the original renderer, vendored, fed from a snapshot | treemap agent |
| `Tests/*` | per module | per owner |

`Package.swift` already declares every target. If you must change it, change
only your own targets' lines.

## Snapshot (DIXCore), already written

A flat, immutable tree in parallel arrays. Node 0 is the root. Children are
contiguous and come after their parent: `firstChild ..< firstChild +
childCount`. They are sorted by `allocatedSize` descending, ties by name
(byte-wise ascending). Directory sizes are subtree sums. Flags mark
directories, packages, symlinks, **cloud placeholders**, **hard-link
duplicates**, mount points and unreadable folders. Kinds are a small table,
indexed per node. `hardLinks` lists every hard-linked file with its (device,
inode). `validate()` checks every invariant. Read
`Sources/DIXCore/Snapshot.swift`: the doc comments are the spec.

### Edits (scanner agent)

```swift
extension Snapshot {
    func removing(_ nodes: [NodeIndex]) -> (snapshot: Snapshot, indexMap: [UInt32])
    func replacingSubtree(at node: NodeIndex, with subtree: Snapshot) -> (snapshot: Snapshot, indexMap: [UInt32])
}
```

- After Move to Trash, or after rescanning one folder, the app edits the
  snapshot instead of rescanning everything. The result passes `validate()`
  and is the tree a fresh scan would give: same entries, sizes, flags, kinds,
  child order and hard-link keepers. Tests check this against fresh scans.
- `indexMap[old]` is the node's new index, or `UInt32.max` if it is gone.
- Edited snapshots are not necessarily breadth-first. Only the documented
  rules hold: children contiguous, after their parent, and sorted.
- Hard links: when the link that carries an inode's size is removed, the
  remaining link with the smallest path takes the size over, as a scan
  would choose. One case is not handled. A new link created inside a
  rescanned folder to an outside file that had a single link at scan time
  counts twice until a full rescan, because that file's inode was never
  recorded.
- Kind indexes stay stable across edits. The kind table only grows.
- 2.87M nodes: 6 to 12 ms per edit (`dix-scan --bench-edit`).

### `.dixsnap` file (scanner agent)

API: `public extension Snapshot { init(contentsOf url: URL) throws; func write(to url: URL, compression: SnapshotFileCompression = .lzfse) throws }`.

- Binary, little-endian. Magic `DIXSNAP1`, a format version, a small header
  (root path, scan date, volume info, counts), then the arrays as sections.
  Designed so loading 1M nodes takes well under 200 ms.
- Written compressed by default (`DIXSNAPZ`): the plain file in 4 MiB
  chunks, each compressed with LZFSE on its own, so both directions use all
  cores. Files are 5 to 8x smaller and load just as fast. The reader takes
  both formats. It caps the plain size at what the header claims, at
  4096x each chunk's stored length, and at 16 GiB.
- **The loader must never crash on a malformed or hostile file.** Check every
  length and offset, cap counts by the file size, then run `validate()`.
  Throw on anything wrong. Fuzz-test it with random truncation and corruption.
  (An earlier save-scan feature in this repo crashed on deep nesting and
  overflowing sizes; don't repeat that.)

## Scanner (DIXScan)

- **Bulk directory reads:** `getattrlistbulk(2)`, one call per batch of
  entries. Ask for name, object type, flags (`ATTR_CMN_FLAGS`), file ID, link
  count, allocated size, data length, mount status, and Finder info (bundle
  bit). No `NSURL` / `FileManager` / resource-value objects per file.
- **Parallel per directory:** a work queue of directories and N workers
  (`activeProcessorCount`, measure −1 vs. not). No global lock on the hot path.
  The previous app's scan spent most of its time with workers waiting on
  LaunchServices' global lock to resolve each file's type. Avoid that.
- **Kinds:** resolve once per distinct extension (and once for "no
  extension"), with `UTType(filenameExtension:)` → `localizedDescription`.
  Packages too: a directory is a package if its bundle bit is set or its
  extension's UTType conforms to `.package`. Cache per extension, never per
  file. A small override table (`KindRegistry.overrides`) fixes extensions
  that macOS gets wrong on a developer's disk, for lowercase spellings only.
  `.ts`, `.mts`, `.cts` and `.tsx` become TypeScript, `.cjs` and `.jsx`
  JavaScript, `.bin` an unknown "BIN File" (not MacBinary), and `.pkl` a
  Python pickle. An all-capitals `CLIP.MTS` keeps its system type.
- **Cloud files** (iCloud Drive, Dropbox, OneDrive, Google Drive, any File
  Provider):
  - A *dataless* file has `SF_DATALESS` in its flags. It occupies about 0
    bytes but reports its full cloud size as its length.
  - Record allocated = what's on disk, logical = the length, and flag
    `.cloudPlaceholder`.
  - **Never trigger a download.** Call `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
    IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)` before
    scanning, and do not descend into dataless directories (flag them instead).
  - Legacy iCloud `.Name.ext.icloud` stub files are a nice-to-have: show them
    as placeholders if cheap.
- **Hard links:** a file with link count > 1 is counted once per (device,
  inode). Further links get allocated = 0 and `.hardLinkDuplicate`. **Which
  link keeps the size must be deterministic**, e.g. the lexicographically
  smallest path, resolved after the scan, not whichever thread got there first.
- **Never followed:** symlinks (recorded as small files). Mount points are
  recorded but not descended, *except* that scanning `/` must still reach the
  Data volume's contents through firmlinks exactly once (`/Users`,
  `/Applications`, ...). Check `/` totals against `df` mentally; don't scan
  all of `/` repeatedly.
- **Unreadable folders** (permissions, privacy protection): flag `.unreadable`
  and continue.
- **Progress and cancel:** live counters (items, bytes, current folder),
  readable from another thread without slowing the scan, plus cancellation.
  Also `expectedItemCount` when knowable: for a volume root, the volume's used
  inode count (`statfs` `f_files - f_ffree`; for `/`, add
  `/System/Volumes/Data`). The app will show "42% · about 20 s left" from it.
- **Output:** a `Snapshot` (BFS layout, contiguous sorted children) that
  passes `validate()`. Memory target: ≤ 64 bytes per node, including names.
- **Deterministic:** two scans of an unchanged folder produce identical
  snapshots.

## Treemap (DIXTreemap)

**Reference implementation:** `src/TreeMap/TMVItem.swift`,
`TMVCushionRenderer.swift` (cushion shader), `src/FileTypeColors.swift`
(palette + assignment), and `src/TreeMapViewController.swift`
(free/other-space colors), all on `origin/master`.

- **Keep exactly:**
  - the squarified layout: rows, `minProportion 0.4`, horizontal/vertical
    choice by aspect
  - the cushion parameters: ambient 0.15, light (−1, −1, 10), the `Ly` uses
    `lx` quirk (it *is* the original look), height factor 0.5 scaled by 0.9
    per level, `BASE_BRIGHTNESS` 1.8 and the color normalization
  - the 12-color palette, assigned to kinds in order of their total size, then
    greys
  - free space white, other space dark grey
  - the yellow 2-pt selection frame
- **Fix these bugs of the original:**
  1. **Black holes:** cells under 1 pt are skipped, so the background shows
     through.
  2. **Speckle:** folders full of tiny files become noise. Merge a folder's
     children below a minimum cell area into one cell. Prior art: commit
     `606161b` on branch `swift-overhaul-review` merges below 16 pt², colors
     the cell like its largest file, and draws it flat and dimmed. It reads
     better than speckle, but judge it against the reference and improve it if
     you can. The merged area must still look like it belongs in a Disk
     Inventory X treemap.
  3. **Pixel rounding drift:** child edges are rounded incrementally and the
     last child absorbs the error. Round from cumulative fractions instead.
     The PR #18 rewrite had this bug badly: a 20-byte file drawn 250× too big.
     Test that every cell's area matches its size within one pixel row or
     column.
  4. Assertions that crash on zero-size children, or when children don't sum
     to the parent.
  5. Retina: render at backing-pixel resolution, layout in pixels.
- **Cloud placeholders:**
  - In allocated mode they're ~0 and disappear, which is correct.
  - In logical mode they get space. Draw them so they read as "not on this
    disk" (e.g. desaturated or lighter cushion) while staying in the style.
  - Hard-link duplicates are 0 in allocated mode.
- **API needs (for the app later):**
  - layout for (snapshot, root node, pixel size, scale, size mode, options)
  - hit-test a point → node, or merged cell (with its count, size and folder)
  - rect for a node; a merged node maps to its merged cell
  - rendering into an RGBA bitmap (`CGImage` is fine)
  - kind → color, so the app's kind list can show swatches
  - incremental zoom: re-layout a subtree as the root without rescanning
- **Speed:** layout plus render at 2880×1800 for a million-node snapshot well
  under 200 ms. Parallelize shading across rows/tiles if needed. CPU is fine.

### dix-render / dix-render-reference

```
dix-render snap.dixsnap -o out.png [--size 1440x900] [--scale 2] [--root <path>]
           [--select <path>] [--mode allocated|logical] [--min-cell-area 16]
           [--compare]   # also run the reference; write a side-by-side PNG + diff stats
```

- **`dix-render-reference`** vendors the original files (`TMVItem.swift`,
  `TMVCushionRenderer.swift`, `TreeMapView.swift`,
  `NSView-BackingCoordsHelpers.swift`, `NSBitmapImageRep-CreationExtensions.swift`)
  unchanged from `origin/master`. It feeds them from a snapshot through a small
  data-source shim, using the original palette assignment.
- **Prior art:** a working harness that does exactly this, with its own folder
  walker, is
  `/private/tmp/claude-501/-Users-mla-b-disk-inventory-x/468e76bc-2cb7-4795-9e25-8006ecb4e252/scratchpad/tmrender/`.
  Its `main.swift` is the shim; `orig/` holds the original files; `final_*.png`
  are earlier before/after renders.
- **`--compare`** reports how close the new renderer is to the reference where
  the reference drew cells of at least, say, 8×8 px. Report pixel agreement or
  mean color error there, so "faithful" is a number, not a feeling.

## Phase 2 (later, not now)

An AppKit app with the original's layout: outline on the left, treemap on the
right, file-kind list with color swatches, selection list, zoom, reveal/open
with/trash, and the drives panel. It reads a `Snapshot` (scanned live, or
opened from a `.dixsnap`) and updates it after deletions instead of
rescanning.

## Ground rules for agents

- Work only in `/Users/mla/b/disk-inventory-x-next/Kit`. Don't edit
  `src/`, other worktrees, or git state: **don't commit**. The lead commits.
- Build and test with `swift build` / `swift test`, with `--scratch-path`
  under the session scratchpad, so build products stay out of the repo.
- **Don't launch GUI apps or take screenshots.** Screen capture triggers a
  macOS permission prompt. Look at your PNGs with the Read tool.
- **Scan only:** `~/b`, `/Applications`, `/usr`, `/System/Library`,
  `~/Library/Caches`, `~/Library/Application Support`, and your own fixtures.
  Other personal folders can trigger macOS privacy prompts. Scanning is
  read-only; never write outside the scratchpad and the Kit folder.
