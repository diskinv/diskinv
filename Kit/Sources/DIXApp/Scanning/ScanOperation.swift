//
//  ScanOperation.swift
//  DIXApp
//
//  Runs one scan in the background with the progress panel (LoadingPanel.nib
//  in the original): "Scanning “b” — 42% · about 20 s left", the folder being
//  read, live counts, a bar, and Cancel. Shown as its own panel for a new
//  scan, or as a sheet on the document window for Refresh.
//
//  GPL v3
//

import AppKit
import DIXCore
import DIXScan

/// The progress panel, laid out as the original's LoadingPanel.nib (408 x 153).
final class ProgressPanel: NSObject {
    let panel: NSPanel
    private let textField = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator(frame: NSRect(x: 27, y: 56, width: 363, height: 20))
    private let detail = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 408, height: 153), styleMask: [.titled],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = "Loading folder contents..."
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let content = panel.contentView!
        textField.frame = NSRect(x: 29, y: 84, width: 362, height: 49)
        textField.maximumNumberOfLines = 3
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        cancelButton.frame = NSRect(x: 303, y: 12, width: 91, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 29, y: cancelButton.frame.midY - 8, width: cancelButton.frame.minX - 29 - 8, height: 16)
        for v in [textField, bar, detail, cancelButton] as [NSView] { content.addSubview(v) }
        bar.startAnimation(nil)
    }

    func update(_ status: ScanEstimate.Status) {
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        let folderStyle = NSMutableParagraphStyle()
        folderStyle.lineBreakMode = .byTruncatingMiddle
        folderStyle.paragraphSpacingBefore = 2
        let text = NSMutableAttributedString(string: status.title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: titleStyle,
        ])
        if !status.folder.isEmpty {
            text.append(NSAttributedString(string: "\n" + status.folder, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: folderStyle,
            ]))
        }
        textField.attributedStringValue = text
        detail.stringValue = status.detail
        if let f = status.fraction {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
            bar.doubleValue = f
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    @objc private func cancel(_ sender: Any?) {
        cancelButton.isEnabled = false
        onCancel?()
    }
}

/// One scan: Scanner on a background thread, the panel updated five times a second.
final class ScanOperation {
    let url: URL
    let displayName: String
    let progressPanel = ProgressPanel()
    private let scanner: DIXScan.Scanner
    private var timer: Timer?
    private var rate = ScanEstimate.Rate()
    private let start = Date()
    private let expected: Int?
    private weak var sheetParent: NSWindow?
    private(set) var isCancelled = false
    private var keepAlive: ScanOperation?

    init(url: URL) {
        self.url = url
        let path = url.path
        displayName = path == "/" ? (FileManager.default.displayName(atPath: "/")) : FileManager.default.displayName(atPath: path)
        scanner = DIXScan.Scanner(path: path, options: DIXScan.Scanner.Options(setProcessMaterializationPolicy: true))
        expected = ScanEstimate.expectedItemCount(forFolder: ScanOperation.realPath(path))
    }

    /// Starts scanning; `completion` runs on the main thread (not called when cancelled).
    func start(sheetOn window: NSWindow? = nil, completion: @escaping (Result<ScanResult, Error>) -> Void) {
        keepAlive = self
        progressPanel.onCancel = { [weak self] in self?.cancel() }
        tick()
        if let window {
            sheetParent = window
            window.beginSheet(progressPanel.panel)
        } else {
            progressPanel.panel.center()
            progressPanel.panel.makeKeyAndOrderFront(nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .modalPanel)
        let scanner = self.scanner
        Thread.detachNewThread { [weak self] in
            let result = Result { try scanner.scan() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.finish()
                if case .failure(let e) = result, case ScanError.cancelled = e { return }
                if case .success(let r) = result { ScanCountMemory.shared.record(r.snapshot.nodeCount - 1, forFolder: r.snapshot.rootPath) }
                completion(result)
            }
        }
    }

    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    func cancel() {
        isCancelled = true
        scanner.cancel()
    }

    private func tick() {
        let p = scanner.progress
        let status = ScanEstimate.status(rootPath: url.path, displayName: displayName, items: p.items,
                                         bytes: p.allocatedBytes, currentPath: p.currentPath,
                                         expectedItems: p.expectedItemCount ?? expected,
                                         elapsed: Date().timeIntervalSince(start), rate: &rate)
        progressPanel.update(status)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if let parent = sheetParent {
            parent.endSheet(progressPanel.panel)
        }
        progressPanel.panel.orderOut(nil)
        keepAlive = nil
    }
}
