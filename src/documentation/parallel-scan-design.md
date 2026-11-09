# Parallel Scan — Design

Goal: parallelize the folder scan (`FSItem.loadChildrenAndSetKindStrings`) across CPU
cores without freezing the UI or changing results. Deployment target is macOS 10.13,
so **GCD only** (Swift `async/await`/`TaskGroup` need 10.15+).

## Why it's a restructure, not a one-liner

Today the scan runs **synchronously on the main thread**, and the loading panel +
Cancel button only function because the scan repeatedly re-enters the main runloop via
the `fsItemEnteringFolder:` delegate callback (which calls `runModalSession`). If we
fan the walk out but keep blocking the main thread, the panel freezes and Cancel dies.
So the walk must move to background workers while the main thread keeps pumping.

## Core principle: zero shared mutation during the parallel phase

Each worker scans a **disjoint subtree into fully-local state** and the parent only
adopts the finished subtree. No two threads ever touch the same node. Concretely:

- **Traversal:** replace the single flat `FileManager.enumerator` deep-walk with a
  recursive per-directory `contentsOfDirectory(at:includingPropertiesForKeys:)`.
  At the **root level only**, dispatch each immediate subdirectory onto a concurrent
  queue (`DispatchGroup`); **below the root, recurse serially**. This bounds threads
  (no per-node thread explosion), keeps big subtrees running concurrently, and
  guarantees each worker owns a disjoint subtree (INV-2: single-writer per parent).
- **Sizes:** each node sums its own children bottom-up *within its subtree*. No
  upward `childChanged` propagation across workers. After join, run the existing
  `recalculateSize(root)` once on the main thread to finalize `OtherSpaceItem`, which
  reads the now-final `root().sizeValue()` (INV-3).
- **Counts (`g_fileCount`/`g_folderCount`):** accumulate **locally per worker**, merge
  after join. (They're debug-only, so this is low-stakes — but no torn writes.)
- **Kind-name cache (`g_kindNameDictionary`):** replace the bare `NSMutableDictionary`
  with a **lock-protected get-or-compute** (`os_unfair_lock`/`NSLock`). Contents are a
  pure function of the UTI string, so a serialized cache is correct and cheap.
- **Per-URL resource cache:** already thread-confined — the scanner builds a fresh
  `NSURL` per entry, and disjoint subtrees never share a URL object. (Verify the
  firmlink/volume recursion doesn't hand one URL to two workers; it won't, because
  firmlink recursion happens inside a single worker's serial descent.)
- **Behavior flags** (`showPackageContents`, `ignoreCreatorCode`, `usePhysicalSize`):
  snapshot once on the main thread into an immutable `ScanParams` struct passed to
  workers. No per-folder delegate calls from workers.

## Progress + cancel (the control-flow change)

- A thread-safe `ScanProgress` (lock-guarded): `foldersScanned`, `currentPath`, plus an
  atomic `cancelled` flag and a `finished` flag.
- `FileSystemDoc.readFromFolder` dispatches the whole scan onto a background concurrent
  queue, then the **main thread runs the existing modal-session loop**: ~5 Hz, read
  `ScanProgress` to update the panel text/bar, and if Cancel was pressed set
  `cancelled = true`. Workers poll `cancelled` at each directory boundary and bail by
  throwing `FSItemError.loadingCanceled`; the coordinator joins all workers, then the
  main loop sees `finished`/error and returns. Tear-down/`do-catch` is unchanged.
- The `fsItemEnteringFolder:`/`fsItemExittingFolder:` delegate callbacks and the
  `_directoryStack` (which assume strict single-thread DFS, INV-1) are **no longer
  called from workers**; progress is by count/path, not by the stack.

## Two-phase pipeline preserved (INV-4)

Phase 1 (parallel, background): build the tree, set kind strings (lock-protected
cache), compute subtree sizes.
Phase 2 (serial, main thread, unchanged): `recalculateSize(root)` then
`refreshFileKindStatisticsThrowing()` (which clears `_fileKindStatistics`, walks the
tree, and fires `kindStatistics` KVO). Never parallelized.

## Cancellation (INV-5)

Cooperative shared atomic flag, fanned out to all workers; any worker's throw signals
the coordinator, which sets the flag for siblings and joins before tear-down.

## Verification gate (must pass before trusting it)

1. **Identical results:** scan the same folders with the serial build and the parallel
   build; assert equal total size, file count, folder count, and per-kind statistics.
2. **Thread Sanitizer:** run a scan under TSan; zero data-race reports.
3. **Cancel works:** Cancel mid-scan of a large tree returns cleanly.
4. **Benchmark:** wall-clock vs serial via the existing benchmark hook.

Keep the change isolated on the `parallel-scan` branch; revert if the gate fails.

## Verification results (gate PASSED)

Measured with a temporary probe (since removed) that dumped exact totals after each
scan, toggling `DIX_PARALLEL_SCAN`:

- **Identical results:** on the repo (7,267 files / 468 folders, incl. `.git`,
  `.app` packages, symlinks) and on `/Applications` (647,135 files / 97,859 folders /
  68 GB), serial and parallel produced byte-identical total size, file count, folder
  count, and all per-kind statistics (count + size).
- **Thread Sanitizer:** a full parallel scan under TSan reported **zero data races**.
- **Benchmark** (`/Applications`, optimized Release, warm cache, 3 runs each):
  serial median **27.5s** → parallel median **14.8s** = **~1.85× faster**. (Amdahl:
  phase-2 stats aggregation over 647K files is serial and included; scan phase alone
  is faster than 1.85×.)

A runtime fallback remains: set env `DIX_PARALLEL_SCAN=0` to use the original serial
scanner (kept byte-for-byte as `FSItem.loadChildrenSerial`).
