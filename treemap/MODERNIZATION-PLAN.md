# TreeMapView Framework Modernization Plan

## Status: Options 1 & 2 COMPLETE ✅

**Completed:** January 2025

### Summary of Changes Made

| Change | Status |
|--------|--------|
| Universal Binary (arm64 + x86_64) | ✅ Complete |
| macOS 11.0+ deployment target | ✅ Complete |
| ARC enabled | ✅ Complete |
| Removed all retain/release/autorelease | ✅ Complete |
| Removed dead PowerPC code | ✅ Complete |
| Fixed deprecated APIs (NSCalibratedRGBColorSpace → sRGBColorSpace) | ✅ Complete |
| Fixed deprecated APIs (NSCompositeCopy → NSCompositingOperationCopy) | ✅ Complete |
| Fixed ARC init patterns | ✅ Complete |

### Files Modified
- `project.pbxproj` - ARCHS, MACOSX_DEPLOYMENT_TARGET, CLANG_ENABLE_OBJC_ARC
- `Info.plist` - LSMinimumSystemVersion, CFBundleVersion
- `TMVCushionRenderer.m` - ARC, deprecated color space APIs, init pattern
- `TMVItem.m` - ARC, NSCompositeCopy
- `TreeMapView.m` - ARC, init pattern, NSCompositeCopy
- `ZoomInfo.m` - ARC, NSCompositeCopy
- `NSBitmapImageRep-CreationExtensions.m` - ARC, NSDeviceRGBColorSpace

### Build Verification
```bash
$ lipo -info TreeMapView.framework/Versions/A/TreeMapView
Architectures in the fat file: x86_64 arm64
```

---

## Original Analysis (for reference)

## Current State Analysis

### Overview
TreeMapView is a ~1,200 line Objective-C framework providing treemap visualization with cushion shading. It's well-architected with clean separation of concerns.

### Architecture
```
TreeMapView.framework/
├── TreeMapView      # Main NSView - user interaction, caching, hit testing
├── TMVItem          # Cell renderer - layout algorithm, hierarchical structure
├── TMVCushionRenderer # Cushion shading - 3D lighting math, pixel rendering
├── ZoomInfo         # Zoom animation controller
├── NSView-BackingCoordsHelpers      # Retina/coordinate conversion
└── NSBitmapImageRep-CreationExtensions  # Bitmap creation utilities
```

### Technical Debt (RESOLVED)
| Issue | Before | After | Status |
|-------|--------|-------|--------|
| Memory management | Manual retain/release | ARC | ✅ Fixed |
| Deployment target | macOS 10.7 | macOS 11.0 | ✅ Fixed |
| Architecture | Intel x86_64 only | Universal (arm64 + x86_64) | ✅ Fixed |
| Language | Objective-C | Objective-C (Swift available) | — |
| PowerPC code | Dead code in TMVCushionRenderer | Removed | ✅ Fixed |
| Deprecated APIs | NSCalibratedRGBColorSpace, NSCompositeCopy | Modern equivalents | ✅ Fixed |

### Dependencies
**None** - Pure Cocoa (AppKit + Foundation). This makes modernization straightforward.

### Public API Surface
```objc
// Data Source Protocol (Required)
- (id)treeMapView:(TreeMapView*)view child:(NSUInteger)index ofItem:(id)item;
- (BOOL)treeMapView:(TreeMapView*)view isNode:(id)item;
- (unsigned)treeMapView:(TreeMapView*)view numberOfChildrenOfItem:(id)item;
- (unsigned long long)treeMapView:(TreeMapView*)view weightByItem:(id)item;

// Delegate Protocol (Optional)
- (NSString*)treeMapView:(TreeMapView*)view getToolTipByItem:(id)item;
- (void)treeMapView:(TreeMapView*)view willDisplayItem:(id)item withRenderer:(TMVItem*)renderer;
- (BOOL)treeMapView:(TreeMapView*)view shouldSelectItem:(id)item;
- (void)treeMapView:(TreeMapView*)view willShowMenuForEvent:(NSEvent*)event;

// Notifications
TreeMapViewItemTouchedNotification
TreeMapViewSelectionDidChangedNotification
```

---

## Modernization Options

### Option 1: Minimal - Apple Silicon Only
**Effort:** 1-2 hours
**Risk:** Very Low
**Result:** Framework runs native on M-series Macs

#### Changes Required

**1. Update project.pbxproj build settings:**
```
ARCHS = "$(ARCHS_STANDARD)";           // arm64 x86_64
MACOSX_DEPLOYMENT_TARGET = 11.0;       // Required for arm64
BUILD_ACTIVE_ARCHITECTURE_ONLY = NO;   // For Release
VALID_ARCHS = ;                        // Remove if present (deprecated)
```

**2. Update Info.plist:**
```xml
<key>LSMinimumSystemVersion</key>
<string>11.0</string>
```

**3. Remove dead PowerPC code in TMVCushionRenderer.m:**
- Delete `renderCushionInBitmapPPC603:` method
- Delete `renderCushionInBitmapPPC603Single:` method
- Remove `#if defined(__ppc__)` conditionals

**4. Build and verify:**
```bash
xcodebuild -project TreeMapView.xcodeproj -configuration Release
lipo -info build/Release/TreeMapView.framework/TreeMapView
# Expected: arm64 x86_64
```

#### Pros
- Fastest path to Apple Silicon
- No API changes - drop-in replacement
- Minimal testing required

#### Cons
- Still uses manual memory management
- No modern Swift interop improvements
- Technical debt remains

---

### Option 2: ARC Migration + Apple Silicon
**Effort:** 4-6 hours
**Risk:** Low
**Result:** Modern Objective-C with ARC, Universal Binary

#### Changes Required

**1. All changes from Option 1, plus:**

**2. Enable ARC in build settings:**
```
CLANG_ENABLE_OBJC_ARC = YES
```

**3. Run Xcode ARC migration:**
- Edit → Refactor → Convert to Objective-C ARC
- Select all .m files
- Review and apply changes

**4. Manual fixes required:**

**TMVItem.m - dealloc:**
```objc
// Before
- (void) dealloc {
    [_cushionRenderer release];
    [_childs release];
    [super dealloc];
}

// After (ARC)
- (void) dealloc {
    // ARC handles release automatically
    // Only needed for non-ObjC cleanup (none here)
}
```

**TMVCushionRenderer.m - dealloc:**
```objc
// Before
- (void) dealloc {
    [_color release];
    [super dealloc];
}

// After (ARC)
// Remove entire method - not needed
```

**TreeMapView.m - dealloc and throughout:**
```objc
// Before
- (void) dealloc {
    [_rootItemRenderer release];
    [_cachedContent release];
    [_zoomer release];
    [super dealloc];
}

// After (ARC)
- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
```

**Property declarations - update attributes:**
```objc
// Before
@property (retain) NSColor *color;
@property (assign) id delegate;

// After
@property (strong) NSColor *color;
@property (weak) id delegate;
```

**5. Fix autorelease patterns:**
```objc
// Before
return [[[NSBitmapImageRep alloc] init...] autorelease];

// After (ARC)
return [[NSBitmapImageRep alloc] init...];
```

**6. Update NSBitmapImageRep-CreationExtensions.m:**
```objc
// Before
- (NSImage*) suitableImageForView: (NSView*) view {
    NSImage *image = [[[NSImage alloc] init] autorelease];
    ...
}

// After
- (NSImage*) suitableImageForView: (NSView*) view {
    NSImage *image = [[NSImage alloc] init];
    ...
}
```

#### Files Requiring Changes
| File | retain/release | autorelease | dealloc |
|------|---------------|-------------|---------|
| TreeMapView.m | ~15 | ~5 | Yes |
| TMVItem.m | ~20 | ~3 | Yes |
| TMVCushionRenderer.m | ~5 | ~2 | Yes |
| ZoomInfo.m | ~8 | ~2 | Yes |
| NSBitmapImageRep-CreationExtensions.m | ~3 | ~2 | No |
| NSView-BackingCoordsHelpers.m | 0 | 0 | No |

#### Pros
- Eliminates memory management bugs
- Reduces code by ~100 lines
- Better Swift interoperability
- Still drop-in compatible with existing code

#### Cons
- Requires testing all code paths
- Still Objective-C (no Swift benefits)

---

### Option 3: Swift Wrapper
**Effort:** 1-2 days
**Risk:** Low-Medium
**Result:** Swift-friendly API while preserving ObjC core

#### Approach
Keep the Objective-C implementation but create a Swift overlay that provides:
- Type-safe protocols
- Modern Swift API conventions
- Combine publishers for notifications
- SwiftUI compatibility via NSViewRepresentable

#### New Files

**TreeMapView+Swift.swift:**
```swift
import AppKit
import Combine

// MARK: - Swift Protocols

public protocol TreeMapViewDataSource: AnyObject {
    func treeMapView(_ view: TreeMapView, childAt index: Int, of item: Any?) -> Any
    func treeMapView(_ view: TreeMapView, isNode item: Any) -> Bool
    func treeMapView(_ view: TreeMapView, numberOfChildrenOf item: Any?) -> Int
    func treeMapView(_ view: TreeMapView, weightOf item: Any) -> UInt64
}

public protocol TreeMapViewDelegate: AnyObject {
    func treeMapView(_ view: TreeMapView, toolTipFor item: Any) -> String?
    func treeMapView(_ view: TreeMapView, willDisplay item: Any, with renderer: TMVItem)
    func treeMapView(_ view: TreeMapView, shouldSelect item: Any) -> Bool
    func treeMapView(_ view: TreeMapView, willShowMenuFor event: NSEvent)
}

// Default implementations
public extension TreeMapViewDelegate {
    func treeMapView(_ view: TreeMapView, toolTipFor item: Any) -> String? { nil }
    func treeMapView(_ view: TreeMapView, willDisplay item: Any, with renderer: TMVItem) {}
    func treeMapView(_ view: TreeMapView, shouldSelect item: Any) -> Bool { true }
    func treeMapView(_ view: TreeMapView, willShowMenuFor event: NSEvent) {}
}

// MARK: - Combine Publishers

public extension TreeMapView {
    var selectionPublisher: AnyPublisher<Any?, Never> {
        NotificationCenter.default
            .publisher(for: NSNotification.Name("TreeMapViewSelectionDidChangedNotification"), object: self)
            .map { [weak self] _ in self?.selectedItem }
            .eraseToAnyPublisher()
    }

    var touchedItemPublisher: AnyPublisher<Any?, Never> {
        NotificationCenter.default
            .publisher(for: NSNotification.Name("TreeMapViewItemTouchedNotification"), object: self)
            .map { $0.userInfo?["TMVTouchedItem"] }
            .eraseToAnyPublisher()
    }
}

// MARK: - SwiftUI Wrapper

@available(macOS 10.15, *)
public struct TreeMapViewRepresentable<Item: Hashable>: NSViewRepresentable {
    public typealias NSViewType = TreeMapView

    let rootItem: Item?
    let children: (Item?) -> [Item]
    let weight: (Item) -> UInt64
    let isNode: (Item) -> Bool
    let color: (Item) -> NSColor

    @Binding var selection: Item?

    public func makeNSView(context: Context) -> TreeMapView {
        let view = TreeMapView(frame: .zero)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ nsView: TreeMapView, context: Context) {
        context.coordinator.parent = self
        nsView.reloadData()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public class Coordinator: NSObject {
        var parent: TreeMapViewRepresentable
        private var items: [ObjectIdentifier: Item] = [:]

        init(_ parent: TreeMapViewRepresentable) {
            self.parent = parent
        }
    }
}
```

**Package.swift (for SPM support):**
```swift
// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "TreeMapView",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "TreeMapView", targets: ["TreeMapView"])
    ],
    targets: [
        .target(
            name: "TreeMapView",
            path: "Classes",
            sources: [
                "TreeMapView.m",
                "TMVItem.m",
                "TMVCushionRenderer.m",
                "ZoomInfo.m",
                "NSView-BackingCoordsHelpers.m",
                "NSBitmapImageRep-CreationExtensions.m",
                "TreeMapView+Swift.swift"
            ],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ]
        )
    ]
)
```

#### Pros
- Best of both worlds - proven ObjC core + modern Swift API
- SwiftUI support without rewrite
- Incremental adoption possible
- Preserves all existing functionality

#### Cons
- Two APIs to maintain
- Some impedance mismatch between ObjC and Swift patterns
- Coordinator complexity for SwiftUI

---

### Option 4: Complete Swift Rewrite
**Effort:** 1-2 weeks
**Risk:** Medium-High
**Result:** Pure Swift framework, modern architecture

#### New Architecture
```
TreeMapKit/
├── Sources/
│   ├── TreeMapKit/
│   │   ├── TreeMapView.swift           # NSView/SwiftUI dual support
│   │   ├── TreeMapLayout.swift         # Layout algorithm (squarified)
│   │   ├── TreeMapRenderer.swift       # Canvas/CoreGraphics rendering
│   │   ├── CushionShader.swift         # Cushion lighting algorithm
│   │   ├── TreeMapNode.swift           # Internal node representation
│   │   └── TreeMapConfiguration.swift  # Settings/appearance
│   └── TreeMapKitSwiftUI/
│       └── TreeMapViewRepresentable.swift
├── Tests/
│   └── TreeMapKitTests/
│       ├── LayoutTests.swift
│       ├── RenderingTests.swift
│       └── PerformanceTests.swift
└── Package.swift
```

#### Core Implementation

**TreeMapNode.swift:**
```swift
import Foundation

public struct TreeMapNode<Item: Hashable>: Identifiable {
    public let id: Item
    public let weight: UInt64
    public let isLeaf: Bool
    public var rect: CGRect = .zero
    public var children: [TreeMapNode<Item>]?

    // Rendering state
    var cushionSurface: CushionSurface = .flat
    var color: CGColor = .black
}

struct CushionSurface {
    var coefficients: (x2: CGFloat, y2: CGFloat, x: CGFloat, y: CGFloat)

    static let flat = CushionSurface(coefficients: (0, 0, 0, 0))

    mutating func addRidge(in rect: CGRect, heightFactor: CGFloat) {
        let h = heightFactor
        let width = rect.width
        let height = rect.height

        coefficients.x += 4 * h * (rect.maxX + rect.minX) / width
        coefficients.x2 -= 4 * h / width
        coefficients.y += 4 * h * (rect.maxY + rect.minY) / height
        coefficients.y2 -= 4 * h / height
    }
}
```

**TreeMapLayout.swift:**
```swift
import Foundation

public enum TreeMapLayout {

    /// Squarified treemap algorithm
    /// Reference: Bruls, Huizing, van Wijk (2000)
    public static func squarified<Item>(
        root: TreeMapNode<Item>,
        in rect: CGRect
    ) -> [TreeMapNode<Item>: CGRect] {
        var result: [TreeMapNode<Item>: CGRect] = [:]
        layoutNode(root, in: rect, result: &result)
        return result
    }

    private static func layoutNode<Item>(
        _ node: TreeMapNode<Item>,
        in rect: CGRect,
        result: inout [TreeMapNode<Item>: CGRect]
    ) {
        guard let children = node.children, !children.isEmpty else {
            result[node] = rect
            return
        }

        let totalWeight = children.reduce(0) { $0 + Double($1.weight) }
        guard totalWeight > 0 else { return }

        var remaining = children.sorted { $0.weight > $1.weight }
        var currentRect = rect

        while !remaining.isEmpty {
            let row = selectRow(from: remaining, in: currentRect, totalWeight: totalWeight)
            let rowWeight = row.reduce(0) { $0 + Double($1.weight) }

            let isWide = currentRect.width >= currentRect.height
            let rowFraction = rowWeight / totalWeight
            let rowThickness = (isWide ? currentRect.width : currentRect.height) * rowFraction

            var offset: CGFloat = 0
            for child in row {
                let childFraction = Double(child.weight) / rowWeight
                let childLength = (isWide ? currentRect.height : currentRect.width) * childFraction

                let childRect: CGRect
                if isWide {
                    childRect = CGRect(
                        x: currentRect.minX,
                        y: currentRect.minY + offset,
                        width: rowThickness,
                        height: childLength
                    )
                } else {
                    childRect = CGRect(
                        x: currentRect.minX + offset,
                        y: currentRect.minY,
                        width: childLength,
                        height: rowThickness
                    )
                }

                layoutNode(child, in: childRect.insetBy(dx: 1, dy: 1), result: &result)
                offset += childLength
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
    }

    private static func selectRow<Item>(
        from items: [TreeMapNode<Item>],
        in rect: CGRect,
        totalWeight: Double
    ) -> [TreeMapNode<Item>] {
        var row: [TreeMapNode<Item>] = []
        var rowWeight: Double = 0
        var worstRatio = Double.infinity

        let side = min(rect.width, rect.height)

        for item in items {
            let itemWeight = Double(item.weight)
            let newRowWeight = rowWeight + itemWeight
            let newRatio = Self.worstAspectRatio(
                weights: (row + [item]).map { Double($0.weight) },
                totalRowWeight: newRowWeight,
                side: side,
                totalWeight: totalWeight,
                totalArea: Double(rect.width * rect.height)
            )

            if newRatio <= worstRatio {
                row.append(item)
                rowWeight = newRowWeight
                worstRatio = newRatio
            } else {
                break
            }
        }

        return row.isEmpty ? [items[0]] : row
    }

    private static func worstAspectRatio(
        weights: [Double],
        totalRowWeight: Double,
        side: CGFloat,
        totalWeight: Double,
        totalArea: Double
    ) -> Double {
        guard !weights.isEmpty, totalRowWeight > 0, side > 0 else {
            return .infinity
        }

        let rowArea = totalArea * (totalRowWeight / totalWeight)
        let rowWidth = rowArea / Double(side)

        var worst: Double = 0
        for weight in weights {
            let itemArea = totalArea * (weight / totalWeight)
            let itemHeight = itemArea / rowWidth
            let ratio = max(rowWidth / itemHeight, itemHeight / rowWidth)
            worst = max(worst, ratio)
        }

        return worst
    }
}
```

**CushionShader.swift:**
```swift
import Foundation
import CoreGraphics
import simd

public struct CushionShader {
    // Lighting parameters
    public var ambientLight: Float = 0.15
    public var diffuseLight: Float = 0.85
    public var lightDirection: SIMD3<Float> = normalize(SIMD3(-1, -1, 10))

    public init() {}

    public func render(
        surface: CushionSurface,
        color: SIMD3<Float>,
        in rect: CGRect,
        to buffer: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int
    ) {
        let width = Int(rect.width)
        let height = Int(rect.height)

        for y in 0..<height {
            let py = Float(y) + Float(rect.minY)
            let rowPtr = buffer.advanced(by: y * bytesPerRow)

            for x in 0..<width {
                let px = Float(x) + Float(rect.minX)

                // Calculate surface normal from partial derivatives
                let nx = 2 * Float(surface.coefficients.x2) * px + Float(surface.coefficients.x)
                let ny = 2 * Float(surface.coefficients.y2) * py + Float(surface.coefficients.y)
                let nz: Float = 1.0

                let normal = normalize(SIMD3(nx, ny, nz))

                // Diffuse lighting (Lambertian)
                let diffuse = max(0, dot(normal, lightDirection))
                let brightness = ambientLight + diffuseLight * diffuse

                // Apply lighting to color
                let r = UInt8(clamping: Int(color.x * brightness * 255))
                let g = UInt8(clamping: Int(color.y * brightness * 255))
                let b = UInt8(clamping: Int(color.z * brightness * 255))

                // Write RGB (assuming 24-bit RGB format)
                let pixelPtr = rowPtr.advanced(by: x * 3)
                pixelPtr[0] = r
                pixelPtr[1] = g
                pixelPtr[2] = b
            }
        }
    }
}
```

**TreeMapView.swift (AppKit):**
```swift
import AppKit
import Combine

@MainActor
public final class TreeMapView<Item: Hashable>: NSView {

    // MARK: - Configuration

    public var configuration = TreeMapConfiguration()

    // MARK: - Data

    public var rootNode: TreeMapNode<Item>? {
        didSet { setNeedsLayout() }
    }

    public var colorProvider: ((Item) -> NSColor)?

    // MARK: - Selection

    @Published public var selectedItem: Item?
    @Published public var hoveredItem: Item?

    // MARK: - Private State

    private var layout: [TreeMapNode<Item>: CGRect] = [:]
    private var cachedImage: NSBitmapImageRep?
    private let shader = CushionShader()

    // MARK: - NSView

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        recalculateLayout()
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let image = cachedImage else { return }

        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: bounds)

        // Draw selection highlight
        if let selected = selectedItem,
           let node = findNode(for: selected),
           let rect = layout[node] {
            NSColor.selectedControlColor.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 3
            path.stroke()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = item(at: point) {
            selectedItem = item
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredItem = item(at: point)
    }

    // MARK: - Public API

    public func reloadData() {
        recalculateLayout()
        renderToCache()
        needsDisplay = true
    }

    public func item(at point: CGPoint) -> Item? {
        for (node, rect) in layout {
            if rect.contains(point) && node.isLeaf {
                return node.id
            }
        }
        return nil
    }

    // MARK: - Private

    private func recalculateLayout() {
        guard let root = rootNode else {
            layout = [:]
            return
        }
        layout = TreeMapLayout.squarified(root: root, in: bounds)
    }

    private func renderToCache() {
        guard !bounds.isEmpty else { return }

        let width = Int(bounds.width)
        let height = Int(bounds.height)

        cachedImage = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 3,
            bitsPerPixel: 24
        )

        guard let bitmap = cachedImage,
              let buffer = bitmap.bitmapData else { return }

        for (node, rect) in layout where node.isLeaf {
            let color = colorProvider?(node.id) ?? .gray
            var rgb = SIMD3<Float>(
                Float(color.redComponent),
                Float(color.greenComponent),
                Float(color.blueComponent)
            )
            // Normalize for consistent brightness
            let sum = rgb.x + rgb.y + rgb.z
            if sum > 0 {
                rgb *= 1.8 / sum
            }

            shader.render(
                surface: node.cushionSurface,
                color: rgb,
                in: rect,
                to: buffer,
                bytesPerRow: bitmap.bytesPerRow
            )
        }
    }

    private func findNode(for item: Item) -> TreeMapNode<Item>? {
        layout.keys.first { $0.id == item }
    }
}
```

**Package.swift:**
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TreeMapKit",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "TreeMapKit", targets: ["TreeMapKit"])
    ],
    targets: [
        .target(
            name: "TreeMapKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "TreeMapKitTests",
            dependencies: ["TreeMapKit"]
        )
    ]
)
```

#### Pros
- Clean, modern Swift codebase
- Full SwiftUI support native
- Type-safe generics throughout
- Combine integration built-in
- SIMD for rendering performance
- Testable architecture
- Swift Package Manager support

#### Cons
- Significant development effort
- Must validate rendering matches original
- Breaking change for existing users
- Risk of subtle algorithm differences

---

## Comparison Matrix

| Aspect | Option 1: Minimal | Option 2: ARC | Option 3: Swift Wrapper | Option 4: Full Rewrite |
|--------|-------------------|---------------|------------------------|------------------------|
| **Effort** | 1-2 hours | 4-6 hours | 1-2 days | 1-2 weeks |
| **Risk** | Very Low | Low | Low-Medium | Medium-High |
| **Apple Silicon** | ✅ | ✅ | ✅ | ✅ |
| **ARC** | ❌ | ✅ | ✅ (ObjC core) | ✅ (Swift) |
| **Swift API** | ❌ | ❌ | ✅ | ✅ |
| **SwiftUI** | ❌ | ❌ | ✅ | ✅ Native |
| **SPM Support** | ❌ | ❌ | ✅ | ✅ |
| **Combine** | ❌ | ❌ | ✅ | ✅ Native |
| **API Compatibility** | 100% | 100% | 100% + new | Breaking |
| **Maintenance** | Same | Easier | Medium | Easiest |

---

## Recommendation

### For Disk Inventory X Modernization
**Options 1 & 2 are COMPLETE** ✅

### Next Steps (Optional)
1. **Option 3 (Swift Wrapper):** Add Swift-friendly API and SwiftUI support without rewriting core
2. **Option 4 (Full Rewrite):** Consider only if maintaining Objective-C becomes burdensome

### Quick Start - Option 2

```bash
# 1. Open project
cd /Users/mla/b/disk-inventory-x/treemap
open TreeMapView.xcodeproj

# 2. In Xcode:
#    - Select TreeMapView target
#    - Build Settings → Architectures → Standard Architectures
#    - Build Settings → macOS Deployment Target → 11.0
#    - Build Settings → Objective-C Automatic Reference Counting → Yes

# 3. Edit → Refactor → Convert to Objective-C ARC
#    - Select all .m files
#    - Preview and apply

# 4. Remove dead PPC code from TMVCushionRenderer.m

# 5. Build
xcodebuild -configuration Release

# 6. Verify
lipo -info build/Release/TreeMapView.framework/TreeMapView
```

---

## Files to Modify (Option 2)

| File | Changes |
|------|---------|
| `project.pbxproj` | ARCHS, deployment target, ARC setting |
| `Info.plist` | LSMinimumSystemVersion |
| `TreeMapView.m` | Remove retain/release/autorelease, update dealloc |
| `TMVItem.m` | Remove retain/release/autorelease, update dealloc |
| `TMVCushionRenderer.m` | Remove retain/release, delete PPC code |
| `ZoomInfo.m` | Remove retain/release/autorelease, update dealloc |
| `NSBitmapImageRep-CreationExtensions.m` | Remove autorelease calls |
| `TreeMapView_Prefix.pch` | No changes needed |

Total: ~7 files, ~200 lines of deletions/modifications
