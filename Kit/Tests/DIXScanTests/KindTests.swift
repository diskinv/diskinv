//
//  KindTests.swift
//  DIXScanTests
//
//  Kind resolution: the override table for extensions macOS gets wrong on a
//  developer's disk, the all-capitals exception, and one lookup per key.
//
//  GPL v3
//

import Foundation
import Testing
import DIXCore
@testable import DIXScan

private func kind(_ registry: KindRegistry, _ fileName: String) -> FileKind {
    let bytes = Array(fileName.utf8)
    let key = bytes.withUnsafeBytes { KindKey.forExtension(of: $0, directory: false) }!
    let (slot, _) = registry.slot(for: key)
    let (table, remap) = registry.finalTable()
    return table[Int(remap[Int(slot)])]
}

@Suite struct KindTests {
    @Test func typeScriptAndFriends() {
        let r = KindRegistry()
        for name in ["index.ts", "types.d.ts", "esm.mts", "cjs.cts", "view.tsx", "Index.Ts"] {
            #expect(kind(r, name) == FileKind(identifier: "com.microsoft.typescript", name: "TypeScript"), "\(name)")
        }
        let js = kind(r, "a.js")
        #expect(js.identifier == "com.netscape.javascript-source")
        for name in ["b.mjs", "c.cjs", "d.jsx"] { #expect(kind(r, name) == js, "\(name)") }
        #expect(kind(r, "model.bin").name == "BIN File")
        #expect(kind(r, "frame.pkl").name == "Python Pickle")
    }

    @Test func allCapitalsKeepTheSystemType() {
        let r = KindRegistry()
        // camcorder and recorder files: the system's video types
        #expect(kind(r, "00001.MTS").identifier == "public.avchd-mpeg-2-transport-stream")
        #expect(kind(r, "SHOW.TS").identifier == "public.mpeg-2-transport-stream")
        // and for everything else, capitals resolve like lowercase
        #expect(kind(r, "PHOTO.JPG") == kind(r, "photo.jpg"))
        #expect(kind(r, "A.TXT").identifier == "public.plain-text")
    }

    @Test func untouchedAmbiguousExtensions() {
        let r = KindRegistry()
        #expect(kind(r, "x.m").identifier == "public.objective-c-source")
        #expect(kind(r, "x.h").identifier == "public.c-header")
        #expect(kind(r, "x.sql").identifier == "org.iso.sql")
        #expect(kind(r, "main.rs").name == "RS File")
        #expect(kind(r, "go.mod").name == "MOD File")
    }

    @Test func eachKeyIsResolvedOnce() {
        let r = KindRegistry()
        for _ in 0 ..< 3 {
            for name in ["a.ts", "b.TS", "c.Ts", "d.jpg", "e.JPG"] { _ = kind(r, name) }
        }
        // ts (lowercase and mixed case share a key), TS, jpg, JPG
        #expect(r.lookups == 4)
        // equal kinds from different keys are one entry in the final table
        let (table, _) = r.finalTable()
        #expect(table.filter { $0.identifier == "public.jpeg" }.count == 1)
    }
}
