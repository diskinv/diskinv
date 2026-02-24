# Disk Inventory X Modernization Report

## Technology Gap Assessment

### Language & Memory Management
| Aspect | Current | Modern Standard |
|--------|---------|-----------------|
| Language | Objective-C (2003) | Swift (2014+) |
| Memory | Manual retain/release | ARC (since 2011) |
| Nullability | Implicit | Explicit `NS_ASSUME_NONNULL` |

The code uses explicit `retain`/`release`/`autorelease` throughout (see FSItem.m:80, 91, 148-157). ARC has been standard for 13+ years.

### Deprecated APIs & Patterns
- **Carbon framework** - Imported in prefix header (line 7), deprecated since 2012
- **NSDrawer** - Used for kind statistics/selection list panels, deprecated since macOS 10.13
- **UTTypeCopyDescription** - Uses old UTType C APIs (FSItem.m:577), modern apps use `UTType` Swift class
- **NIB files** - Uses legacy Interface Builder format instead of Storyboards or SwiftUI
- **NSFilenamesPboardType** etc. - Deprecated pasteboard types (FSItem.m:722-734)

### Architecture Limitations
- **Intel-only** - No Apple Silicon native support (runs via Rosetta 2)
- **Deployment target 10.11** - Though release notes say 10.13 minimum, project still targets 10.11
- **No Swift interop** - Pure Objective-C, no bridging
- **No Combine/async-await** - Uses delegate callbacks and notifications instead of modern reactive patterns

### Missing Modern Features
| Feature | Status |
|---------|--------|
| SwiftUI | Not used |
| Combine | Not used |
| async/await | Not used |
| Apple Silicon native | No |
| App Sandbox | Entitlements file empty |
| Mac Catalyst | No |
| WidgetKit | No |

## Optimization Opportunities

### Performance
1. **Concurrent file scanning** - `loadChildrenAndSetKindStrings:` (FSItem.m:906) is synchronous. Could use `DispatchQueue.concurrentPerform` or Swift concurrency for parallel directory enumeration.

2. **Memory pressure** - Manual memory management with potential for leaks. Recent commit (76304d9) fixed FSItem memory leaks, suggesting ongoing issues.

3. **NSURL caching** - The code does cache URL resource values (see NSURL-Extensions), but modern `URLResourceValues` would be cleaner.

### Code Quality
1. **ARC migration** - Would eliminate entire classes of memory bugs and reduce code volume by ~20%

2. **Swift rewrite** - Would provide:
   - Type safety and optionals
   - Modern concurrency (async/await for file operations)
   - Better error handling with `Result` types
   - SwiftUI for declarative UI

3. **Replace NSDrawer** - With modern sheet presentations or sidebar navigation

### Realistic Modernization Path

A full SwiftUI rewrite would be substantial. A pragmatic approach:

1. **Enable ARC** - Low-risk, high-value first step
2. **Add Apple Silicon slice** - Build as Universal Binary 2
3. **Replace deprecated APIs** - UTType, pasteboard types, Carbon calls
4. **Replace NSDrawer** - With NSSplitViewController sidebar
5. **Incremental Swift** - Start with new features in Swift with bridging headers

The codebase is functional but architecturally ~10-15 years behind current practices. It works, but accumulating technical debt makes each change increasingly difficult.

---

## Omni Framework Dependency Analysis

The project depends on external Omni Group frameworks (built 2018, Intel-only):

### OmniFoundation (Utility Extensions)

**NSString-OFExtensions:**
- `+[NSString isEmptyString:]` - checks if string is nil or empty (used ~10 places)

**NSMutableArray-OFExtensions:**
- `insertObject:inArraySortedUsingSelector:` - binary search insert (used in FSItem.m:352)

**NSDictionary/NSArray-OFExtensions:**
- Minor convenience methods in Preferences.m and FileSystemDoc.m

**Replacement effort:** ~20 lines of code. These are trivial utility methods.

### OmniAppKit (UI Infrastructure)

**OAToolbarWindowController:**
- Loads toolbar configuration from `.toolbar` plist files
- Provides `toolbarInfoForItem:` and `toolbarConfigurationName`
- Auto-creates toolbar items from plist definitions

**OAPreferenceController / OAPreferenceClient:**
- Multi-pane preferences window system
- Auto-registers preference panes from Info.plist
- Handles "restore defaults" functionality

**OASplitView:**
- Enhanced NSSplitView (used in MainWindowController.h:13)

**OAController:**
- App controller base class (but AppController.m is essentially empty)

**OAToolbarItem:**
- Enhanced toolbar item with delegate support

**Replacement effort:** This is the bulk of the work. The toolbar and preferences systems would need reimplementation.

### OmniBase

- Imported in prefix header but actual usage is minimal
- Provides base macros/utilities

### Summary: Effort to Remove Omni Dependency

| Component | Effort | Standard Replacement |
|-----------|--------|---------------------|
| `isEmptyString:` | 5 min | `string.length == 0` |
| `insertObject:inArraySortedUsingSelector:` | 10 min | Binary search + insert |
| `OASplitView` | 30 min | `NSSplitView` or `NSSplitViewController` |
| `OAController` | 0 min | Already empty, use `NSObject` |
| `OAToolbarWindowController` | 2-4 hrs | `NSWindowController` + manual toolbar setup |
| `OAPreferenceController` | 3-5 hrs | Custom preferences window or SwiftUI Settings |

**Total to remove Omni dependency: ~1 day of work**

---

## Detailed Modernization Implementation Plan

### Phase 1: Apple Silicon Support (Priority: HIGH)

**Goal:** Build Universal Binary 2 (arm64 + x86_64) to run natively on Apple Silicon.

#### 1.1 Update External Frameworks

**TreeMapView.framework:**
```
Location: ../../../../TreeMapView/vdev/make/src/build/Release/TreeMapView.framework
Status: Custom framework, source availability unknown
```

Action items:
1. Locate TreeMapView source code
2. Open TreeMapView.xcodeproj
3. Set Build Settings:
   - `ARCHS = $(ARCHS_STANDARD)` → resolves to `arm64 x86_64`
   - `BUILD_ACTIVE_ARCHITECTURE_ONLY = NO`
   - Remove any `VALID_ARCHS` user-defined setting (deprecated)
4. Build for Release
5. Verify with: `lipo -info TreeMapView.framework/TreeMapView`
   - Expected output: `Architectures in the fat file: ... are: x86_64 arm64`

**Omni Frameworks:**
```
Location: ../../../../OmniFrameworks_2018-09-22/Build/Release/
Frameworks: OmniFoundation, OmniAppKit, OmniBase
Status: Intel-only (2018 build)
```

Option A - Update Omni (if continuing to use):
1. Clone https://github.com/omnigroup/OmniGroup
2. Build frameworks for arm64 + x86_64
3. Replace old frameworks in project

Option B - Remove Omni dependency (recommended):
- See Phase 2 below

#### 1.2 Update Disk Inventory X Project Settings

File: `Disk Inventory X.xcodeproj/project.pbxproj`

Changes required:
```
// In Build Settings for target "Disk Inventory X":

ARCHS = "$(ARCHS_STANDARD)";                    // Was: implicit x86_64 only
BUILD_ACTIVE_ARCHITECTURE_ONLY = NO;            // For Release builds
MACOSX_DEPLOYMENT_TARGET = 11.0;                // Update from 10.11, required for arm64
VALID_ARCHS = ;                                 // Delete if present (deprecated)

// Remove any architecture exclusions:
EXCLUDED_ARCHS = ;                              // Should be empty
EXCLUDED_ARCHS[sdk=macosx*] = ;                 // Should be empty
```

#### 1.3 Fix Architecture-Specific Code

Search for potential issues:
```bash
grep -r "x86_64\|i386\|__x86_64__\|TARGET_CPU" *.m *.h *.c
```

Known areas to check:
- `Timing.c` - May use architecture-specific timing
- Any inline assembly (unlikely but check)
- Any 32-bit assumptions in pointer arithmetic

#### 1.4 Build and Test

```bash
# Build Universal Binary
xcodebuild -project "Disk Inventory X.xcodeproj" \
           -configuration Release \
           -arch arm64 -arch x86_64

# Verify architectures
lipo -info "build/Release/Disk Inventory X.app/Contents/MacOS/Disk Inventory X"

# Test on Apple Silicon (native)
arch -arm64 open "build/Release/Disk Inventory X.app"

# Test on Intel (or Rosetta)
arch -x86_64 open "build/Release/Disk Inventory X.app"
```

---

### Phase 2: Remove Omni Framework Dependency

**Goal:** Replace Omni frameworks with standard AppKit/Foundation equivalents.

#### 2.1 Replace OmniFoundation Utilities

**File: `NSString+DIXExtensions.h` (new)**
```objc
#import <Foundation/Foundation.h>

@interface NSString (DIXExtensions)
+ (BOOL)isEmptyString:(NSString *)string;
@end
```

**File: `NSString+DIXExtensions.m` (new)**
```objc
#import "NSString+DIXExtensions.h"

@implementation NSString (DIXExtensions)
+ (BOOL)isEmptyString:(NSString *)string {
    return string == nil || string.length == 0;
}
@end
```

**File: `NSMutableArray+DIXExtensions.h` (new)**
```objc
#import <Foundation/Foundation.h>

@interface NSMutableArray (DIXExtensions)
- (void)insertObject:(id)object inArraySortedUsingSelector:(SEL)selector;
@end
```

**File: `NSMutableArray+DIXExtensions.m` (new)**
```objc
#import "NSMutableArray+DIXExtensions.h"

@implementation NSMutableArray (DIXExtensions)
- (void)insertObject:(id)object inArraySortedUsingSelector:(SEL)selector {
    NSUInteger low = 0;
    NSUInteger high = self.count;

    while (low < high) {
        NSUInteger mid = (low + high) / 2;
        id midObject = self[mid];
        NSComparisonResult result = ((NSComparisonResult (*)(id, SEL, id))
            [object methodForSelector:selector])(object, selector, midObject);

        if (result == NSOrderedDescending) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    [self insertObject:object atIndex:low];
}
@end
```

**Files to update:**
| File | Change |
|------|--------|
| `FSItem.m:19` | Replace `#import <OmniFoundation/NSMutableArray-OFExtensions.h>` with `#import "NSMutableArray+DIXExtensions.h"` |
| `OAToolbarWindowControllerEx.m:17` | Replace with `#import "NSString+DIXExtensions.h"` |
| `FSItemIndex.m:17` | Replace with `#import "NSString+DIXExtensions.h"` |
| `MainWindowController.m:24` | Replace with `#import "NSString+DIXExtensions.h"` |
| `SelectionListController.m:19` | Replace with `#import "NSString+DIXExtensions.h"` |
| `FileSystemDoc.m:25` | Remove import (check if actually used) |
| `AppsForItem.m:16` | Replace with `#import "NSMutableArray+DIXExtensions.h"` |
| `Preferences.m:11-12` | Remove imports (check if actually used) |

#### 2.2 Replace OAToolbarWindowController

**Current hierarchy:**
```
MainWindowController : OAToolbarWindowControllerEx : OAToolbarWindowController : NSWindowController
```

**Target hierarchy:**
```
MainWindowController : DIXToolbarWindowController : NSWindowController
```

**File: `DIXToolbarWindowController.h` (new)**
```objc
#import <Cocoa/Cocoa.h>

@interface DIXToolbarWindowController : NSWindowController <NSToolbarDelegate>

@property (nonatomic, readonly) NSString *toolbarConfigurationName;
@property (nonatomic, readonly) NSDictionary *toolbarConfiguration;

- (NSDictionary *)toolbarInfoForItem:(NSString *)identifier;

@end
```

**File: `DIXToolbarWindowController.m` (new)**
```objc
#import "DIXToolbarWindowController.h"

@implementation DIXToolbarWindowController {
    NSDictionary *_toolbarConfiguration;
}

- (NSString *)toolbarConfigurationName {
    // Override in subclass or return class-based name
    return NSStringFromClass([self class]);
}

- (NSDictionary *)toolbarConfiguration {
    if (!_toolbarConfiguration) {
        NSString *name = [self toolbarConfigurationName];
        NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"toolbar"];
        if (path) {
            _toolbarConfiguration = [NSDictionary dictionaryWithContentsOfFile:path];
        }
    }
    return _toolbarConfiguration;
}

- (NSDictionary *)toolbarInfoForItem:(NSString *)identifier {
    return self.toolbarConfiguration[@"items"][identifier];
}

#pragma mark - NSToolbarDelegate

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return self.toolbarConfiguration[@"defaultItems"] ?: @[];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return self.toolbarConfiguration[@"allowedItems"] ?: @[];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {

    NSDictionary *info = [self toolbarInfoForItem:itemIdentifier];
    if (!info) return nil;

    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];

    // Set label from info or localized string
    NSString *label = info[@"label"];
    if (label) {
        item.label = NSLocalizedString(label, nil);
        item.paletteLabel = item.label;
    }

    // Set tooltip
    NSString *toolTip = info[@"toolTip"];
    if (toolTip) {
        item.toolTip = NSLocalizedString(toolTip, nil);
    }

    // Set image
    NSString *imageName = info[@"imageName"];
    if (imageName) {
        item.image = [NSImage imageNamed:imageName];
    }

    // Set action
    NSString *actionString = info[@"action"];
    if (actionString) {
        if (![actionString hasSuffix:@":"]) {
            actionString = [actionString stringByAppendingString:@":"];
        }
        item.action = NSSelectorFromString(actionString);
    }

    // Set target
    NSString *targetPath = info[@"target"];
    if (targetPath) {
        item.target = [self valueForKeyPath:targetPath];
    }

    // Modern bordered style (macOS 10.15+)
    if (@available(macOS 10.15, *)) {
        item.bordered = YES;
    }

    return item;
}

@end
```

**Update `OAToolbarWindowControllerEx.h`:**
```objc
// Change:
#import <OmniAppKit/OAToolbarWindowController.h>
// To:
#import "DIXToolbarWindowController.h"

// Change:
@interface OAToolbarWindowControllerEx : OAToolbarWindowController
// To:
@interface OAToolbarWindowControllerEx : DIXToolbarWindowController
```

**Update `OAToolbarWindowControllerEx.m`:**
- Remove `#import <OmniFoundation/NSString-OFExtensions.h>`
- Remove `#import <OmniAppKit/OAToolbarItem.h>`
- Replace `[NSString isEmptyString:]` with `string.length == 0`
- Remove `OAToolbarItem` delegate calls (use standard validation)

#### 2.3 Replace OAPreferenceController

**Current hierarchy:**
```
PrefsPanelController : OAPreferenceController
PrefsPageBase : OAPreferenceClient
```

**Option A: Minimal AppKit replacement**

**File: `DIXPreferencesWindowController.h` (new)**
```objc
#import <Cocoa/Cocoa.h>

@interface DIXPreferencesWindowController : NSWindowController

+ (instancetype)sharedController;
- (void)showPreferencesPanel:(id)sender;

@end
```

**File: `DIXPreferencesWindowController.m` (new)**
```objc
#import "DIXPreferencesWindowController.h"

@interface DIXPreferencesWindowController () <NSToolbarDelegate>
@property (nonatomic, strong) NSTabView *tabView;
@property (nonatomic, strong) NSArray *preferencesPanes;
@end

@implementation DIXPreferencesWindowController

+ (instancetype)sharedController {
    static DIXPreferencesWindowController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 500, 400)
                  styleMask:NSWindowStyleMaskTitled |
                           NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    window.title = NSLocalizedString(@"Preferences", nil);

    self = [super initWithWindow:window];
    if (self) {
        [self setupTabView];
        [self loadPreferencesPanes];
    }
    return self;
}

- (void)setupTabView {
    self.tabView = [[NSTabView alloc] initWithFrame:self.window.contentView.bounds];
    self.tabView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:self.tabView];
}

- (void)loadPreferencesPanes {
    // Load GeneralPrefPage
    NSViewController *generalVC = [[NSViewController alloc]
        initWithNibName:@"GeneralPreferencesPage" bundle:nil];
    NSTabViewItem *generalTab = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
    generalTab.label = NSLocalizedString(@"General", nil);
    generalTab.view = generalVC.view;
    [self.tabView addTabViewItem:generalTab];

    // Load TreeMapPrefPage
    NSViewController *treemapVC = [[NSViewController alloc]
        initWithNibName:@"TreeMapPreferencesPage" bundle:nil];
    NSTabViewItem *treemapTab = [[NSTabViewItem alloc] initWithIdentifier:@"treemap"];
    treemapTab.label = NSLocalizedString(@"TreeMap", nil);
    treemapTab.view = treemapVC.view;
    [self.tabView addTabViewItem:treemapTab];
}

- (void)showPreferencesPanel:(id)sender {
    [self.window center];
    [self showWindow:sender];
}

@end
```

**Option B: SwiftUI Settings (macOS 13+, requires Swift bridging)**

```swift
// File: SettingsView.swift (new)
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            TreeMapSettingsView()
                .tabItem {
                    Label("TreeMap", systemImage: "square.grid.2x2")
                }
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("ShowPhysicalSize") private var showPhysicalSize = false
    @AppStorage("ShowPackageContents") private var showPackageContents = false
    @AppStorage("IgnoreCreatorCode") private var ignoreCreatorCode = true

    var body: some View {
        Form {
            Toggle("Show physical file size", isOn: $showPhysicalSize)
            Toggle("Show package contents", isOn: $showPackageContents)
            Toggle("Ignore creator codes", isOn: $ignoreCreatorCode)
        }
        .padding()
    }
}
```

#### 2.4 Replace OASplitView

**File: `MainWindowController.h`**
```objc
// Change:
#import <OmniAppKit/OASplitView.h>
// To:
// (remove import, use NSSplitView directly)

// Change:
IBOutlet OASplitView *_splitter;
// To:
IBOutlet NSSplitView *_splitter;
```

If using `NSSplitViewController` (recommended for new sidebar):
```objc
// MainWindowController becomes child of NSSplitViewController
// Each pane (file list, treemap, drawers) becomes a child view controller
```

#### 2.5 Replace OAController (AppController base class)

**File: `AppController.h`**
```objc
// Change:
#import <OmniAppKit/OAController.h>
@interface AppController : OAController
// To:
#import <Cocoa/Cocoa.h>
@interface AppController : NSObject <NSApplicationDelegate>
```

#### 2.6 Update Prefix Header

**File: `Disk Inventory X_Prefix.pch`**
```objc
// Remove:
#import <OmniBase/OmniBase.h>

// Keep:
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>  // Remove in Phase 3
```

#### 2.7 Update Framework Search Paths

**File: `project.pbxproj`**
```
// Remove these lines:
FRAMEWORK_SEARCH_PATHS_OMNI = "...OmniFrameworks...";

// Remove framework references:
OmniFoundation.framework
OmniAppKit.framework
OmniBase.framework
```

---

### Phase 3: Enable ARC (Automatic Reference Counting)

**Goal:** Eliminate manual memory management, reduce code, prevent leaks.

#### 3.1 Pre-Migration Cleanup

Fix patterns that won't auto-convert:

**Assigned objects in structs (if any):**
```objc
// Before: Not ARC compatible
typedef struct {
    NSString *name;  // Object in struct
} MyStruct;

// After: Use __unsafe_unretained or refactor to class
typedef struct {
    __unsafe_unretained NSString *name;
} MyStruct;
```

**Property attributes:**
```objc
// Before
@property (retain) NSString *name;
@property (assign) id delegate;

// After
@property (strong) NSString *name;
@property (weak) id delegate;
```

#### 3.2 Run Xcode Migration Tool

1. **Edit → Refactor → Convert to Objective-C ARC...**
2. Select target "Disk Inventory X"
3. Select all `.m` files (excluding third-party if any)
4. Click "Check" - fix any reported issues
5. Review changes in preview
6. Apply changes

#### 3.3 Manual Fixes Post-Migration

**Dealloc methods:**
```objc
// Before (MRC)
- (void)dealloc {
    [_name release];
    [_children release];
    [super dealloc];  // Remove this line
}

// After (ARC)
- (void)dealloc {
    // Only cleanup non-object resources (observers, etc.)
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
```

**Autorelease pools:**
```objc
// Before (MRC)
NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
// ... code ...
[pool drain];

// After (ARC)
@autoreleasepool {
    // ... code ...
}
```

**Toll-free bridging (Core Foundation):**
```objc
// Before
CFStringRef cfStr = (CFStringRef)nsString;

// After - explicit bridge
CFStringRef cfStr = (__bridge CFStringRef)nsString;           // No ownership transfer
CFStringRef cfStr = (__bridge_retained CFStringRef)nsString;  // ARC releases ownership
NSString *nsStr = (__bridge_transfer NSString *)cfStr;        // ARC takes ownership
```

#### 3.4 Files Requiring Special Attention

| File | Issue | Fix |
|------|-------|-----|
| `FSItem.m:143-158` | Complex dealloc with child notification | Review parent/child ownership |
| `FSItem.m:80` | `autorelease` in init | Will auto-convert |
| `FSItem.m:91` | `retain` for _fileURL | Will become strong |
| `NTFilePasteboardSource.m` | Third-party code | May need `-fno-objc-arc` flag |

#### 3.5 Build Settings Update

```
CLANG_ENABLE_OBJC_ARC = YES
```

For files that can't be converted (third-party):
1. Build Phases → Compile Sources
2. Double-click file
3. Add `-fno-objc-arc` flag

---

### Phase 4: Replace Deprecated APIs

#### 4.1 Replace Carbon Framework Usage

**File: `Disk Inventory X_Prefix.pch`**
```objc
// Remove:
#import <Carbon/Carbon.h>
```

**Search for Carbon usage:**
```bash
grep -r "Carbon\|FSRef\|FSSpec\|AE" *.m *.h
```

Common replacements:
| Carbon | Modern Equivalent |
|--------|-------------------|
| `FSRef` | `NSURL` |
| `FSSpec` | `NSURL` |
| `LSCopyKindStringForTypeInfo` | `UTType.localizedDescription` |
| `UTTypeCreatePreferredIdentifierForTag` | `UTType(filenameExtension:)` |

#### 4.2 Replace UTType C APIs

**File: `FSItem.m:568-597`**

```objc
// Before (C API)
#import <CoreServices/CoreServices.h>

_kindName = (NSString*)UTTypeCopyDescription((CFStringRef)uti);

// After (Modern - requires macOS 11+)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

if (@available(macOS 11.0, *)) {
    UTType *type = [UTType typeWithIdentifier:uti];
    _kindName = [type.localizedDescription copy];
} else {
    // Fallback for older macOS
    _kindName = (NSString *)CFBridgingRelease(
        UTTypeCopyDescription((__bridge CFStringRef)uti)
    );
}
```

**For Swift (cleaner):**
```swift
import UniformTypeIdentifiers

let type = UTType(identifier)
let description = type?.localizedDescription ?? "Unknown"
```

#### 4.3 Replace Deprecated Pasteboard Types

**File: `FSItem.m:720-758`**

```objc
// Before (deprecated)
NSFilenamesPboardType
NSStringPboardType
NSFileContentsPboardType
NSTIFFPboardType
NSRTFPboardType
NSPDFPboardType

// After (modern UTType-based)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// In supportedPasteboardTypes:
- (NSArray<NSPasteboardType> *)supportedPasteboardTypes {
    NSMutableArray *types = [NSMutableArray array];

    // File URLs (replaces NSFilenamesPboardType)
    [types addObject:NSPasteboardTypeFileURL];

    // String
    [types addObject:NSPasteboardTypeString];

    // Check UTI for specific types
    if (@available(macOS 11.0, *)) {
        UTType *type = [UTType typeWithIdentifier:[[self fileURL] cachedUTI]];

        if ([type conformsToType:UTTypeImage]) {
            [types addObject:NSPasteboardTypeTIFF];
        }
        if ([type conformsToType:UTTypePDF]) {
            [types addObject:NSPasteboardTypePDF];
        }
        if ([type conformsToType:UTTypeRTF]) {
            [types addObject:NSPasteboardTypeRTF];
        }
    }

    return types;
}

// Writing to pasteboard:
- (void)writeToPasteboard:(NSPasteboard *)pboard {
    [pboard clearContents];

    // Use writeObjects with URL
    NSURL *url = [self fileURL];
    if (url) {
        [pboard writeObjects:@[url]];
    }
}

// Reading from pasteboard:
NSArray *urls = [pboard readObjectsForClasses:@[[NSURL class]]
                                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
```

#### 4.4 Replace NSDrawer with NSSplitViewController Sidebar

**Current architecture:**
```
MainWindow
├── NSSplitView (files | treemap)
├── NSDrawer (kind statistics)  ← Deprecated
└── NSDrawer (selection list)   ← Deprecated
```

**Target architecture:**
```
NSSplitViewController
├── Sidebar (kind statistics + selection list)
│   └── NSTabView or segmented sections
├── File list panel
└── TreeMap panel
```

**Implementation steps:**

1. **Create new window controller structure:**
```objc
// File: MainSplitViewController.h (new)
#import <Cocoa/Cocoa.h>

@interface MainSplitViewController : NSSplitViewController
@property (nonatomic, strong) NSViewController *sidebarViewController;
@property (nonatomic, strong) NSViewController *fileListViewController;
@property (nonatomic, strong) NSViewController *treeMapViewController;
@end
```

2. **Configure split view items:**
```objc
// File: MainSplitViewController.m (new)
- (void)viewDidLoad {
    [super viewDidLoad];

    // Sidebar (collapsible)
    NSSplitViewItem *sidebarItem = [NSSplitViewItem
        sidebarWithViewController:self.sidebarViewController];
    sidebarItem.canCollapse = YES;
    sidebarItem.minimumThickness = 200;
    sidebarItem.maximumThickness = 300;

    // File list
    NSSplitViewItem *fileListItem = [NSSplitViewItem
        splitViewItemWithViewController:self.fileListViewController];
    fileListItem.minimumThickness = 200;

    // TreeMap
    NSSplitViewItem *treeMapItem = [NSSplitViewItem
        splitViewItemWithViewController:self.treeMapViewController];
    treeMapItem.minimumThickness = 300;

    self.splitViewItems = @[sidebarItem, fileListItem, treeMapItem];
}

// Toggle sidebar (replaces drawer toggle)
- (IBAction)toggleSidebar:(id)sender {
    NSSplitViewItem *sidebar = self.splitViewItems.firstObject;
    sidebar.animator.collapsed = !sidebar.isCollapsed;
}
```

3. **Update NIB files:**
- Remove NSDrawer objects from `MainMenu.nib` / `TreeMap.nib`
- Create new sidebar view NIB
- Wire up new split view controller

4. **Migrate drawer content:**
```objc
// SidebarViewController contains both:
// - FileKindsTableController content (kind statistics)
// - SelectionListController content (selection list)
// Use NSTabView or NSStackView to organize
```

---

### Phase 5: Update Deployment Target and Build Settings

#### 5.1 Update Minimum macOS Version

**File: `project.pbxproj`**
```
MACOSX_DEPLOYMENT_TARGET = 11.0;  // Was 10.11
```

Rationale:
- macOS 11 (Big Sur) required for arm64 support
- macOS 11 provides modern UTType Swift API
- macOS 11 dropped support for 32-bit apps (already 64-bit only)

#### 5.2 Update Info.plist

```xml
<key>LSMinimumSystemVersion</key>
<string>11.0</string>

<key>LSArchitecturePriority</key>
<array>
    <string>arm64</string>
    <string>x86_64</string>
</array>
```

#### 5.3 Enable Hardened Runtime

```xml
<!-- In .entitlements file -->
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<false/>
<key>com.apple.security.cs.disable-library-validation</key>
<false/>
```

Build Settings:
```
ENABLE_HARDENED_RUNTIME = YES
CODE_SIGN_IDENTITY = "Apple Development"  // Or "Developer ID Application" for distribution
```

---

### Phase 6: Optional Swift Migration (Future)

#### 6.1 Add Swift Bridging Header

**File: `Disk Inventory X-Bridging-Header.h` (new)**
```objc
#import "FSItem.h"
#import "FileSystemDoc.h"
#import "Preferences.h"
// ... other headers Swift needs to access
```

Build Settings:
```
SWIFT_OBJC_BRIDGING_HEADER = "Disk Inventory X-Bridging-Header.h"
```

#### 6.2 Incremental Swift Adoption

Recommended order:
1. **New utility classes** - Write new helpers in Swift
2. **Model layer** - Rewrite FSItem in Swift with better memory safety
3. **View controllers** - Migrate one at a time
4. **SwiftUI views** - Add new features in SwiftUI

#### 6.3 FSItem in Swift (Example)

```swift
// File: FSItem.swift (new, eventually replaces FSItem.m)
import Foundation
import UniformTypeIdentifiers

@objc enum FSItemType: Int {
    case fileFolderItem
    case otherSpaceItem
    case freeSpaceItem
}

@objc class FSItem: NSObject {
    @objc let fileURL: URL
    @objc weak var parent: FSItem?
    @objc private(set) var children: [FSItem] = []
    @objc private(set) var sizeValue: UInt64 = 0

    private var _kindName: String?

    @objc var kindName: String {
        if _kindName == nil {
            if let uti = try? fileURL.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
               let type = UTType(uti) {
                _kindName = type.localizedDescription ?? "Unknown"
            }
        }
        return _kindName ?? ""
    }

    @objc init(url: URL) {
        self.fileURL = url
        super.init()
    }

    @objc func loadChildren() async throws {
        guard fileURL.hasDirectoryPath else { return }

        let resourceKeys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isPackageKey,
            .fileSizeKey, .totalFileAllocatedSizeKey,
            .typeIdentifierKey
        ]

        let enumerator = FileManager.default.enumerator(
            at: fileURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        // Use TaskGroup for parallel processing
        await withTaskGroup(of: FSItem?.self) { group in
            while let url = enumerator?.nextObject() as? URL {
                group.addTask {
                    return FSItem(url: url)
                }
            }

            for await item in group {
                if let item = item {
                    self.insertChild(item)
                }
            }
        }
    }
}
```

---

## Implementation Checklist

### Phase 1: Apple Silicon (Required for modern Macs)
- [ ] Locate and rebuild TreeMapView.framework for arm64
- [ ] Update or remove Omni frameworks
- [ ] Set `ARCHS = $(ARCHS_STANDARD)` in project
- [ ] Set `MACOSX_DEPLOYMENT_TARGET = 11.0`
- [ ] Build and verify Universal Binary with `lipo -info`
- [ ] Test on Apple Silicon Mac
- [ ] Test on Intel Mac (or Rosetta)

### Phase 2: Remove Omni Dependency
- [ ] Create `NSString+DIXExtensions` category
- [ ] Create `NSMutableArray+DIXExtensions` category
- [ ] Create `DIXToolbarWindowController` class
- [ ] Create `DIXPreferencesWindowController` class
- [ ] Update `OAToolbarWindowControllerEx` to inherit from DIX class
- [ ] Update `AppController` to inherit from NSObject
- [ ] Update `MainWindowController.h` to use NSSplitView
- [ ] Remove Omni framework imports from all files
- [ ] Remove Omni framework references from project
- [ ] Build and test

### Phase 3: Enable ARC
- [ ] Fix struct-with-objects issues (if any)
- [ ] Update property attributes (retain→strong, assign→weak)
- [ ] Run Edit → Refactor → Convert to Objective-C ARC
- [ ] Fix bridge casts for Core Foundation types
- [ ] Clean up dealloc methods
- [ ] Mark incompatible files with `-fno-objc-arc`
- [ ] Build and test for memory leaks with Instruments

### Phase 4: Replace Deprecated APIs
- [ ] Remove Carbon framework import
- [ ] Replace `UTTypeCopyDescription` with UTType API
- [ ] Replace deprecated pasteboard types
- [ ] Replace NSDrawer with NSSplitViewController sidebar
- [ ] Update NIB files for new UI structure
- [ ] Build and test all UI flows

### Phase 5: Finalize Build Settings
- [ ] Update LSMinimumSystemVersion to 11.0
- [ ] Enable Hardened Runtime
- [ ] Configure code signing
- [ ] Test notarization

### Phase 6: Optional Swift (Future)
- [ ] Add bridging header
- [ ] Create Swift package/module structure
- [ ] Migrate utilities to Swift
- [ ] Consider SwiftUI for new features

---

## Alternative Approach: Fresh SwiftUI Rewrite

For some projects, incremental modernization creates more complexity than starting fresh. This section outlines a ground-up rewrite approach that may be preferable depending on goals.

### When to Consider a Rewrite

**Rewrite makes sense when:**
- The goal is a modern, maintainable codebase (not just "make it work")
- You want SwiftUI and modern async/await patterns throughout
- The UI needs significant changes anyway (NSDrawer replacement)
- Long-term maintenance matters more than short-term shipping
- You want App Store distribution with full sandboxing

**Incremental modernization makes sense when:**
- You need Apple Silicon support quickly with minimal risk
- The existing UI/UX is acceptable
- Resources are limited
- The app just needs to keep working, not be "modern"

### Rewrite Architecture

```
DiskInventoryX/
├── App/
│   ├── DiskInventoryXApp.swift          # @main App struct
│   └── AppState.swift                   # ObservableObject for global state
├── Models/
│   ├── FSItem.swift                     # File system item (struct, not class)
│   ├── FileKindStatistic.swift          # Statistics per file type
│   ├── ScanSession.swift                # Encapsulates a scan operation
│   └── TreeMapNode.swift                # Node for treemap rendering
├── Services/
│   ├── FileScanner.swift                # async file enumeration
│   ├── SizeCalculator.swift             # Size computation with actors
│   └── IconProvider.swift               # Icon caching
├── Views/
│   ├── ContentView.swift                # Main NavigationSplitView
│   ├── Sidebar/
│   │   ├── SidebarView.swift
│   │   ├── FileKindsListView.swift
│   │   └── SelectionListView.swift
│   ├── FileList/
│   │   ├── FileListView.swift           # OutlineGroup-based
│   │   └── FileRowView.swift
│   ├── TreeMap/
│   │   ├── TreeMapView.swift            # Canvas-based rendering
│   │   ├── TreeMapRenderer.swift        # Layout algorithm
│   │   └── TreeMapInteraction.swift     # Click/hover handling
│   └── Settings/
│       └── SettingsView.swift           # Settings scene
└── Utilities/
    ├── FileSizeFormatter.swift
    └── UTTypeExtensions.swift
```

### Core Model in Swift

```swift
// Models/FSItem.swift
import Foundation
import UniformTypeIdentifiers

struct FSItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: UInt64
    let utType: UTType?

    var children: [FSItem]?

    var kindName: String {
        utType?.localizedDescription ?? "Unknown"
    }

    // Hashable by URL for stable identity
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FSItem, rhs: FSItem) -> Bool {
        lhs.url == rhs.url
    }
}
```

### Async File Scanner

```swift
// Services/FileScanner.swift
import Foundation

actor FileScanner {
    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    func scan(
        url: URL,
        progress: @escaping (String, Int) -> Void
    ) async throws -> FSItem {
        let resourceKeys: Set<URLResourceKey> = [
            .nameKey, .isDirectoryKey, .isPackageKey,
            .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentTypeKey
        ]

        var root = try createItem(from: url, resourceKeys: resourceKeys)

        if root.isDirectory {
            root.children = try await scanDirectory(
                url: url,
                resourceKeys: resourceKeys,
                progress: progress
            )
        }

        return root
    }

    private func scanDirectory(
        url: URL,
        resourceKeys: Set<URLResourceKey>,
        progress: @escaping (String, Int) -> Void
    ) async throws -> [FSItem] {
        guard !isCancelled else {
            throw CancellationError()
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        // Process in parallel with TaskGroup
        return try await withThrowingTaskGroup(of: FSItem.self) { group in
            for itemURL in contents {
                group.addTask {
                    var item = try self.createItem(from: itemURL, resourceKeys: resourceKeys)

                    if item.isDirectory && !item.isPackage {
                        item.children = try await self.scanDirectory(
                            url: itemURL,
                            resourceKeys: resourceKeys,
                            progress: progress
                        )
                    }

                    await MainActor.run {
                        progress(item.name, 1)
                    }

                    return item
                }
            }

            var results: [FSItem] = []
            for try await item in group {
                results.append(item)
            }
            return results.sorted { $0.size > $1.size }
        }
    }

    private func createItem(from url: URL, resourceKeys: Set<URLResourceKey>) throws -> FSItem {
        let values = try url.resourceValues(forKeys: resourceKeys)

        return FSItem(
            id: UUID(),
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            size: UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
            utType: values.contentType
        )
    }
}
```

### SwiftUI Main View

```swift
// Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var selectedItem: FSItem?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar
            SidebarView(
                statistics: appState.kindStatistics,
                selectedKind: $appState.selectedKind
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } content: {
            // File list
            if let root = appState.rootItem {
                FileListView(
                    root: root,
                    selection: $selectedItem
                )
            } else {
                ContentUnavailableView(
                    "No Folder Selected",
                    systemImage: "folder",
                    description: Text("Open a folder to analyze disk usage")
                )
            }
        } detail: {
            // TreeMap
            if let root = appState.zoomedItem ?? appState.rootItem {
                TreeMapView(
                    root: root,
                    selectedItem: $selectedItem,
                    colorProvider: appState.colorForKind
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: openFolder) {
                    Label("Open", systemImage: "folder")
                }

                Button(action: zoomIn) {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .disabled(selectedItem == nil || !selectedItem!.isDirectory)

                Button(action: zoomOut) {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .disabled(appState.zoomStack.isEmpty)
            }
        }
        .onOpenURL { url in
            Task {
                await appState.scan(url: url)
            }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.scan(url: url)
            }
        }
    }

    private func zoomIn() {
        guard let item = selectedItem, item.isDirectory else { return }
        appState.zoomInto(item)
    }

    private func zoomOut() {
        appState.zoomOut()
    }
}
```

### TreeMap in SwiftUI Canvas

```swift
// Views/TreeMap/TreeMapView.swift
import SwiftUI

struct TreeMapView: View {
    let root: FSItem
    @Binding var selectedItem: FSItem?
    let colorProvider: (String) -> Color

    @State private var hoveredItem: FSItem?
    @State private var layout: [FSItem: CGRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Calculate layout
                let rects = TreeMapLayout.squarified(
                    item: root,
                    rect: CGRect(origin: .zero, size: size)
                )

                // Draw rectangles
                for (item, rect) in rects {
                    let color = colorProvider(item.kindName)
                    let isSelected = item == selectedItem
                    let isHovered = item == hoveredItem

                    // Fill
                    context.fill(
                        Path(rect.insetBy(dx: 1, dy: 1)),
                        with: .color(color.opacity(isHovered ? 0.8 : 1.0))
                    )

                    // Selection border
                    if isSelected {
                        context.stroke(
                            Path(rect),
                            with: .color(.accentColor),
                            lineWidth: 3
                        )
                    }

                    // Label (if rect is large enough)
                    if rect.width > 60 && rect.height > 20 {
                        context.draw(
                            Text(item.name).font(.caption),
                            at: CGPoint(x: rect.midX, y: rect.midY)
                        )
                    }
                }

                // Store layout for hit testing
                DispatchQueue.main.async {
                    self.layout = rects
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        selectedItem = itemAt(point: value.location)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredItem = itemAt(point: location)
                case .ended:
                    hoveredItem = nil
                }
            }
        }
    }

    private func itemAt(point: CGPoint) -> FSItem? {
        for (item, rect) in layout {
            if rect.contains(point) {
                return item
            }
        }
        return nil
    }
}

// TreeMap layout algorithm
enum TreeMapLayout {
    static func squarified(item: FSItem, rect: CGRect) -> [FSItem: CGRect] {
        var result: [FSItem: CGRect] = [:]

        guard let children = item.children, !children.isEmpty else {
            result[item] = rect
            return result
        }

        let totalSize = Double(children.reduce(0) { $0 + $1.size })
        guard totalSize > 0 else { return result }

        var remaining = children
        var currentRect = rect

        while !remaining.isEmpty {
            let isWide = currentRect.width >= currentRect.height
            let side = isWide ? currentRect.height : currentRect.width

            // Find optimal row
            var row: [FSItem] = []
            var rowSize: Double = 0
            var worstRatio = Double.infinity

            for item in remaining {
                let itemSize = Double(item.size) / totalSize * Double(currentRect.width * currentRect.height)
                let newRowSize = rowSize + itemSize
                let newRatio = Self.worstRatio(row + [item], rowSize: newRowSize, side: side)

                if newRatio <= worstRatio {
                    row.append(item)
                    rowSize = newRowSize
                    worstRatio = newRatio
                } else {
                    break
                }
            }

            // Layout row
            let rowFraction = rowSize / Double(currentRect.width * currentRect.height)
            let rowThickness = (isWide ? currentRect.width : currentRect.height) * rowFraction

            var offset: CGFloat = 0
            for item in row {
                let itemFraction = Double(item.size) / totalSize * Double(currentRect.width * currentRect.height) / rowSize
                let itemLength = side * itemFraction

                let itemRect: CGRect
                if isWide {
                    itemRect = CGRect(
                        x: currentRect.minX,
                        y: currentRect.minY + offset,
                        width: rowThickness,
                        height: itemLength
                    )
                } else {
                    itemRect = CGRect(
                        x: currentRect.minX + offset,
                        y: currentRect.minY,
                        width: itemLength,
                        height: rowThickness
                    )
                }

                if item.children != nil && itemRect.width > 10 && itemRect.height > 10 {
                    let childRects = squarified(item: item, rect: itemRect.insetBy(dx: 2, dy: 2))
                    result.merge(childRects) { $1 }
                } else {
                    result[item] = itemRect
                }

                offset += itemLength
            }

            // Update remaining rect
            if isWide {
                currentRect = CGRect(
                    x: currentRect.minX + rowThickness,
                    y: currentRect.minY,
                    width: currentRect.width - rowThickness,
                    height: currentRect.height
                )
            } else {
                currentRect = CGRect(
                    x: currentRect.minX,
                    y: currentRect.minY + rowThickness,
                    width: currentRect.width,
                    height: currentRect.height - rowThickness
                )
            }

            remaining.removeFirst(row.count)
        }

        return result
    }

    private static func worstRatio(_ items: [FSItem], rowSize: Double, side: Double) -> Double {
        guard !items.isEmpty, rowSize > 0, side > 0 else { return .infinity }

        let sideSquared = side * side
        var worst: Double = 0

        for item in items {
            let area = Double(item.size)
            let ratio = max(
                (sideSquared * area) / (rowSize * rowSize),
                (rowSize * rowSize) / (sideSquared * area)
            )
            worst = max(worst, ratio)
        }

        return worst
    }
}
```

### Settings Scene

```swift
// Views/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            TreeMapSettingsTab()
                .tabItem {
                    Label("TreeMap", systemImage: "square.grid.2x2")
                }
        }
        .frame(width: 450, height: 250)
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("showPhysicalSize") private var showPhysicalSize = false
    @AppStorage("showPackageContents") private var showPackageContents = false
    @AppStorage("ignoreCreatorCode") private var ignoreCreatorCode = true
    @AppStorage("showFreeSpace") private var showFreeSpace = true
    @AppStorage("showOtherSpace") private var showOtherSpace = true

    var body: some View {
        Form {
            Section("File Sizes") {
                Toggle("Show physical file size (blocks used)", isOn: $showPhysicalSize)
            }

            Section("Packages") {
                Toggle("Show package contents", isOn: $showPackageContents)
                Toggle("Ignore creator codes", isOn: $ignoreCreatorCode)
            }

            Section("Volume Display") {
                Toggle("Show free space", isOn: $showFreeSpace)
                Toggle("Show other space", isOn: $showOtherSpace)
            }
        }
        .padding()
    }
}

struct TreeMapSettingsTab: View {
    @AppStorage("cushionShading") private var cushionShading = true
    @AppStorage("showGrid") private var showGrid = true

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Cushion shading", isOn: $cushionShading)
                Toggle("Show grid lines", isOn: $showGrid)
            }
        }
        .padding()
    }
}
```

### App Entry Point

```swift
// App/DiskInventoryXApp.swift
import SwiftUI

@main
struct DiskInventoryXApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    NotificationCenter.default.post(name: .openFolder, object: nil)
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let openFolder = Notification.Name("openFolder")
}
```

### Rewrite Implementation Phases

**Week 1: Core Infrastructure**
- [ ] Create new Xcode project (SwiftUI App, macOS 13+)
- [ ] Implement FSItem model
- [ ] Implement FileScanner actor with async/await
- [ ] Basic ContentView with NavigationSplitView shell
- [ ] Open folder and display file list

**Week 2: TreeMap**
- [ ] Implement squarified treemap algorithm
- [ ] TreeMapView with Canvas rendering
- [ ] Click selection and hover states
- [ ] Color assignment by file type
- [ ] Zoom in/out functionality

**Week 3: Polish & Features**
- [ ] Sidebar with file kind statistics
- [ ] Selection list view
- [ ] Settings scene with @AppStorage
- [ ] Toolbar actions
- [ ] Drag and drop support
- [ ] Move to Trash functionality

**Week 4: Testing & Release**
- [ ] Performance testing with large directories
- [ ] Memory profiling
- [ ] Accessibility audit
- [ ] Notarization and distribution

### Comparison: Incremental vs Rewrite

| Aspect | Incremental Modernization | Fresh SwiftUI Rewrite |
|--------|--------------------------|----------------------|
| **Time to Apple Silicon** | 1-3 days | 2-4 weeks |
| **Final code quality** | Mixed Obj-C/Swift | Pure Swift |
| **Risk** | Lower (known codebase) | Higher (new bugs) |
| **Maintenance burden** | Ongoing technical debt | Clean slate |
| **Learning curve** | Gradual | Steep but rewarding |
| **TreeMapView dependency** | Must port or wrap | Reimplement in Swift |
| **UI modernization** | Piecemeal | Complete |

### Recommendation

**For "just make it work on Apple Silicon":** Use incremental approach (Phases 1-2)

**For "build a maintainable, modern app":** Consider the rewrite, especially if:
- TreeMapView source is unavailable or complex
- You want to learn modern Swift/SwiftUI patterns
- The app will be actively developed for years

A hybrid approach is also viable: get Apple Silicon working incrementally first, then rewrite in parallel while the old version remains usable.

---

## Implementation Notes & Lessons Learned (January 2026)

This section documents practical lessons from completing Phases 1-2 of the modernization.

### Phase 2 Completion Summary

**Files Created (Omni Replacements):**
```
src/NSString+DIXExtensions.h/.m      - isEmptyString: replacement
src/NSMutableArray+DIXExtensions.h/.m - insertObject:inArraySortedUsingSelector:
src/NSDictionary+DIXExtensions.h/.m  - boolForKey:, setBoolValue:forKey:, etc.
src/NSString+DIXUnicode.h/.m         - horizontalEllipsisString
src/DIXToolbarWindowController.h/.m  - OAToolbarWindowController replacement
src/DIXPreferenceClient.h/.m         - OAPreferenceClient replacement
src/DIXPreferenceController.h/.m     - OAPreferenceController replacement
```

**Files Modified:**
- `Info.plist` - Changed NSPrincipalClass from OAApplication to NSApplication
- `Disk Inventory X_Prefix.pch` - Removed OmniBase import, added OBPRECONDITION macro
- `AppController.h` - Changed base class from OAController to NSObject<NSApplicationDelegate>
- `MainWindowController.h` - Changed OASplitView to NSSplitView
- `OAToolbarWindowControllerEx.h/.m` - Changed base class to DIXToolbarWindowController
- `PrefsPageBase.h/.m` - Changed base class to DIXPreferenceClient
- `PrefsPanelController.h/.m` - Changed base class to DIXPreferenceController
- All source files with Omni imports updated to DIX extensions

### Key Gotchas Discovered

1. **NSPrincipalClass in Info.plist**
   - The app crashes at launch with "Unable to find class: OAApplication" if Info.plist still references the Omni application class
   - Must change `<key>NSPrincipalClass</key><string>OAApplication</string>` to `NSApplication`

2. **OBPRECONDITION Macro**
   - OmniBase defines assertion macros used throughout the codebase
   - Simple replacement: `#define OBPRECONDITION(condition) NSCParameterAssert(condition)`
   - Also need OBASSERT and OBASSERT_NOT_REACHED

3. **OAPasteboardHelper**
   - Used in NTFilePasteboardSource.m for lazy pasteboard data
   - Direct replacement: `[pboard declareTypes:types owner:self]` (standard NSPasteboard API)

4. **Toolbar Configuration Files**
   - The app uses .toolbar plist files for toolbar configuration
   - DIXToolbarWindowController reads these and creates NSToolbarItems
   - Format: `{ items: { identifier: { label, toolTip, imageName, action, target } }, defaultItems: [], allowedItems: [] }`

5. **Preferences System Complexity**
   - OAPreferenceController/OAPreferenceClient is deeply integrated
   - The existing implementation had most complex code commented out with `#pragma warning "code disabled"`
   - Simplified stubs work because preferences are bound directly via NSUserDefaults

6. **Framework Search Paths**
   - Must remove FRAMEWORK_SEARCH_PATHS_OMNI from both Debug and Release configurations
   - Also remove from framework group, build phases, and copy files phase

### Architecture for Swift Migration

Based on implementation experience, here's a practical Swift architecture:

```swift
// MARK: - File System Model (replaces FSItem)

@Observable
class FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    var size: UInt64 = 0
    var physicalSize: UInt64 = 0
    var children: [FileNode] = []
    weak var parent: FileNode?

    // Computed from UTType
    var kindName: String { UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "Unknown" }
    var uniformTypeIdentifier: String { UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data" }
}

// MARK: - Scanner Actor (thread-safe scanning)

actor FileScanner {
    private var isCancelled = false

    func scan(url: URL, progress: @escaping (Int, Int) -> Void) async throws -> FileNode {
        let root = FileNode(url: url)
        try await scanDirectory(root, progress: progress)
        return root
    }

    func cancel() { isCancelled = true }

    private func scanDirectory(_ node: FileNode, progress: @escaping (Int, Int) -> Void) async throws {
        guard !isCancelled else { throw CancellationError() }

        let contents = try FileManager.default.contentsOfDirectory(
            at: node.url,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )

        for childURL in contents {
            let resourceValues = try childURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey, .isPackageKey])

            let child = FileNode(url: childURL)
            child.size = UInt64(resourceValues.fileSize ?? 0)
            child.physicalSize = UInt64(resourceValues.totalFileAllocatedSize ?? 0)
            child.isDirectory = resourceValues.isDirectory ?? false
            child.isPackage = resourceValues.isPackage ?? false
            child.parent = node

            node.children.append(child)

            if child.isDirectory && !child.isPackage {
                try await scanDirectory(child, progress: progress)
            }

            node.size += child.size
        }
    }
}

// MARK: - TreeMap Algorithm (Squarified)

struct TreeMapRect: Identifiable {
    let id = UUID()
    let node: FileNode
    var rect: CGRect
    var color: Color
}

func squarify(nodes: [FileNode], in rect: CGRect, colorProvider: (FileNode) -> Color) -> [TreeMapRect] {
    guard !nodes.isEmpty else { return [] }

    let sorted = nodes.sorted { $0.size > $1.size }
    let totalSize = sorted.reduce(0) { $0 + $1.size }

    return layoutRow(
        items: sorted,
        totalSize: Double(totalSize),
        bounds: rect,
        colorProvider: colorProvider
    )
}

// Squarified treemap layout algorithm
private func layoutRow(items: [FileNode], totalSize: Double, bounds: CGRect, colorProvider: (FileNode) -> Color) -> [TreeMapRect] {
    // Implementation of Bruls, Huizing, van Wijk squarified treemap algorithm
    // https://www.win.tue.nl/~vanwijk/stm.pdf
    var results: [TreeMapRect] = []
    var remaining = items
    var currentBounds = bounds

    while !remaining.isEmpty {
        let isWide = currentBounds.width >= currentBounds.height
        let side = isWide ? currentBounds.height : currentBounds.width

        var row: [FileNode] = []
        var rowSize: Double = 0
        var worstRatio = Double.infinity

        for item in remaining {
            let testRow = row + [item]
            let testSize = rowSize + Double(item.size)
            let ratio = worst(row: testRow, rowSize: testSize, side: side, totalSize: totalSize, fullSide: isWide ? currentBounds.width : currentBounds.height)

            if ratio <= worstRatio {
                row = testRow
                rowSize = testSize
                worstRatio = ratio
            } else {
                break
            }
        }

        // Layout the row
        let rowFraction = rowSize / totalSize
        let rowExtent = (isWide ? currentBounds.width : currentBounds.height) * rowFraction

        var offset: CGFloat = 0
        for item in row {
            let itemFraction = Double(item.size) / rowSize
            let itemExtent = side * itemFraction

            let itemRect: CGRect
            if isWide {
                itemRect = CGRect(x: currentBounds.minX, y: currentBounds.minY + offset, width: rowExtent, height: itemExtent)
            } else {
                itemRect = CGRect(x: currentBounds.minX + offset, y: currentBounds.minY, width: itemExtent, height: rowExtent)
            }

            results.append(TreeMapRect(node: item, rect: itemRect, color: colorProvider(item)))
            offset += itemExtent
        }

        // Update bounds for remaining items
        if isWide {
            currentBounds = CGRect(x: currentBounds.minX + rowExtent, y: currentBounds.minY,
                                   width: currentBounds.width - rowExtent, height: currentBounds.height)
        } else {
            currentBounds = CGRect(x: currentBounds.minX, y: currentBounds.minY + rowExtent,
                                   width: currentBounds.width, height: currentBounds.height - rowExtent)
        }

        remaining = Array(remaining.dropFirst(row.count))
    }

    return results
}

private func worst(row: [FileNode], rowSize: Double, side: Double, totalSize: Double, fullSide: Double) -> Double {
    guard !row.isEmpty, rowSize > 0 else { return .infinity }
    let rowWidth = (rowSize / totalSize) * fullSide
    return row.map { node in
        let h = (Double(node.size) / rowSize) * side
        let w = rowWidth
        return max(w/h, h/w)
    }.max() ?? .infinity
}
```

### SwiftUI Views Structure

```swift
// Main window with NavigationSplitView
struct ContentView: View {
    @State private var document: DiskDocument?
    @State private var selectedNode: FileNode?
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: File kind statistics
            if let doc = document {
                FileKindsSidebar(document: doc, selection: $selectedNode)
            }
        } content: {
            // File list outline view
            if let doc = document {
                FileOutlineView(root: doc.rootItem, selection: $selectedNode)
            }
        } detail: {
            // TreeMap view
            if let doc = document {
                TreeMapView(root: doc.zoomedItem ?? doc.rootItem, selection: $selectedNode)
            }
        }
        .toolbar { /* toolbar items */ }
    }
}

// TreeMap rendered with Canvas for performance
struct TreeMapView: View {
    let root: FileNode
    @Binding var selection: FileNode?
    @State private var hoveredNode: FileNode?

    var body: some View {
        GeometryReader { geometry in
            let rects = squarify(nodes: root.children, in: CGRect(origin: .zero, size: geometry.size), colorProvider: colorForNode)

            Canvas { context, size in
                for rect in rects {
                    let path = Path(roundedRect: rect.rect.insetBy(dx: 1, dy: 1), cornerRadius: 2)
                    context.fill(path, with: .color(rect.color))

                    if rect.node === selection {
                        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    }
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        selection = rects.first { $0.rect.contains(value.location) }?.node
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredNode = rects.first { $0.rect.contains(location) }?.node
                case .ended:
                    hoveredNode = nil
                }
            }
        }
    }
}
```

### File Kind Colors (Port from Existing)

```swift
// Port FileTypeColors.m color assignments
struct FileKindColors {
    static let shared = FileKindColors()

    private var assignedColors: [String: Color] = [:]
    private var nextColorIndex = 0

    // Predefined palette similar to original
    private let palette: [Color] = [
        Color(red: 0.4, green: 0.6, blue: 1.0),   // Blue
        Color(red: 1.0, green: 0.6, blue: 0.4),   // Orange
        Color(red: 0.6, green: 0.8, blue: 0.4),   // Green
        Color(red: 0.9, green: 0.5, blue: 0.7),   // Pink
        Color(red: 0.7, green: 0.5, blue: 0.9),   // Purple
        Color(red: 0.9, green: 0.8, blue: 0.4),   // Yellow
        Color(red: 0.5, green: 0.8, blue: 0.8),   // Cyan
        Color(red: 0.8, green: 0.6, blue: 0.5),   // Brown
        // ... more colors
    ]

    mutating func color(for kindName: String) -> Color {
        if let existing = assignedColors[kindName] {
            return existing
        }
        let color = palette[nextColorIndex % palette.count]
        assignedColors[kindName] = color
        nextColorIndex += 1
        return color
    }
}
```

### Migration Checklist

**Completed (Phase 1-2):**
- [x] TreeMapView framework modernized (ARC + Universal Binary)
- [x] OmniFrameworks dependency removed
- [x] App builds and runs on Apple Silicon
- [x] NSPrincipalClass fixed in Info.plist

**Remaining for Full Modernization:**
- [ ] Enable ARC for main app (Phase 3)
- [ ] Replace deprecated APIs (Phase 4) - many NSBeginAlertSheet, loadNibNamed, etc.
- [ ] Update deployment target to macOS 11.0+
- [ ] Replace Carbon APIs (FSPathMakeRef, FSGetCatalogInfo)

**For Swift Rewrite:**
- [ ] Create Swift Package for core model (FileNode, FileScanner)
- [ ] Implement squarified treemap algorithm in Swift
- [ ] Create SwiftUI views (NavigationSplitView structure)
- [ ] Port file kind color assignment
- [ ] Implement Settings with @AppStorage
- [ ] Handle Full Disk Access permission

### Performance Considerations

1. **Scanning**: Use async/await with Task for cancelation support
2. **TreeMap Rendering**: Use Canvas for hardware-accelerated drawing
3. **Large Directories**: Consider lazy loading children, pagination in outline view
4. **Memory**: FileNode should use weak parent reference to avoid retain cycles

---

## References

- [UTType Documentation](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct)
- [Uniform Type Identifiers Tech Talk](https://developer.apple.com/videos/play/tech-talks/10696/)
- [Building a Universal macOS Binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
- [TN3117: Resolving Architecture Build Errors](https://developer.apple.com/documentation/technotes/tn3117-resolving-build-errors-for-apple-silicon)
- [Transitioning to ARC Release Notes](https://developer.apple.com/library/archive/releasenotes/ObjectiveC/RN-TransitioningToARC/Introduction/Introduction.html)
- [NSToolbar Documentation](https://developer.apple.com/documentation/appkit/nstoolbar)
- [NSSplitViewController Documentation](https://developer.apple.com/documentation/appkit/nssplitviewcontroller)
- [NSPasteboard readObjects Documentation](https://developer.apple.com/documentation/appkit/nspasteboard/1524454-readobjects)
- [SwiftUI Settings Scene](https://nilcoalescing.com/blog/ScenesTypesInASwiftUIMacApp/)
- [sindresorhus/Settings Library](https://github.com/sindresorhus/Settings)
- [marioaguzman/toolbar Example](https://github.com/marioaguzman/toolbar)
- [NSDrawer Alternatives Discussion](https://developer.apple.com/forums/thread/121585)
