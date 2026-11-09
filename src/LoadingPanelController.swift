//
//  LoadingPanelController.swift
//  Disk Inventory Xs
//
//  Swift port of LoadingPanelController.{h,m}. Owns LoadingPanel.nib and drives
//  the scan progress panel (either modal or as a sheet), throttling event-loop
//  pumping to ~5 Hz so it doesn't dominate scan time. Nib owner, so the class
//  name, IBOutlets, and the cancel: action are pinned with @objc.
//
//  GPL v3
//

import Cocoa

@objc(LoadingPanelController)
class LoadingPanelController: NSObject {

    @IBOutlet private var _loadingTextField: NSTextField!
    @IBOutlet private var _loadingPanel: NSPanel!
    @IBOutlet private var _loadingProgressIndicator: NSProgressIndicator!
    @IBOutlet private var _loadingCancelButton: NSButton!

    private var _loadingPanelModalSession: NSApplication.ModalSession?
    private var _lastEventLoopRun: UInt64 = 0
    private var _cancelPressed = false
    private var _message: String?
    private var _nibTopLevelObjects: [Any]?

    // live scan status (see setStatus); applied on the next runEventLoop
    private var _detailTextField: NSTextField?
    private var _pendingStatus: (title: String, folder: String, detail: String, fraction: Double?)?

    // starts a modal session immediately
    @objc override init() {
        super.init()
        loadPanelNib()

        // the nib has "release when closed = YES"; turn it off so the panel's
        // lifetime is governed by _nibTopLevelObjects only. Otherwise closing it
        // frees the panel while the array still holds a stale pointer, producing
        // a zombie crash when the controller is later released.
        _loadingPanel.isReleasedWhenClosed = false

        _loadingProgressIndicator.usesThreadedAnimation = false
        _loadingProgressIndicator.startAnimation(self)
        _loadingPanel.display()

        _loadingPanelModalSession = NSApplication.shared.beginModalSession(for: _loadingPanel)
        _lastEventLoopRun = 0
        _cancelPressed = false
    }

    // starts the panel as a sheet immediately
    @objc(initAsSheetForWindow:) init(asSheetFor window: NSWindow) {
        super.init()
        loadPanelNib()

        _loadingPanel.isReleasedWhenClosed = false  // see init() for the reason

        window.beginSheet(_loadingPanel, completionHandler: nil)
        _loadingPanel.worksWhenModal = true

        _loadingProgressIndicator.usesThreadedAnimation = false
        _loadingProgressIndicator.startAnimation(self)

        // no modal session when shown as a sheet
        _loadingPanelModalSession = nil
        _lastEventLoopRun = 0
        _cancelPressed = false
    }

    private func loadPanelNib() {
        var topLevelObjects: NSArray?
        if !Bundle.main.loadNibNamed("LoadingPanel", owner: self, topLevelObjects: &topLevelObjects) {
            assertionFailure("couldn't load LoadingPanel.nib")
        }
        _nibTopLevelObjects = topLevelObjects as? [Any]
        addDetailTextField()
    }

    // A small secondary line left of the Cancel button for live counts
    // ("184,203 items · 6.1 GB · 0:07"). Added in code so the localized nibs
    // don't all need editing.
    private func addDetailTextField() {
        guard let contentView = _loadingPanel?.contentView, let cancelButton = _loadingCancelButton,
              let progressIndicator = _loadingProgressIndicator else { return }
        let left = progressIndicator.frame.minX + 2
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.frame = NSRect(x: left, y: cancelButton.frame.midY - 8,
                             width: cancelButton.frame.minX - left - 8, height: 16)
        field.autoresizingMask = [.width]
        contentView.addSubview(field)
        _detailTextField = field
    }

    // Shows the scan status: a title line ("Scanning “b” — 42% · about 6 s left"),
    // the folder being scanned, a detail line with live counts, and the bar,
    // determinate when `fraction` is known, otherwise animated. Applied on the
    // next runEventLoop (throttled) or by applyStatusNow.
    @objc(setStatusTitle:folder:detail:fraction:)
    func setStatus(title: String, folder: String, detail: String, fraction: NSNumber?) {
        _pendingStatus = (title, folder, detail, fraction?.doubleValue)
    }

    // applies a pending status immediately and redraws (for use right before
    // the main thread blocks, e.g. while collecting statistics)
    @objc func applyStatusNow() {
        // keep an indeterminate bar moving while the main thread is busy
        _loadingProgressIndicator?.usesThreadedAnimation = true
        applyPendingStatus()
        _loadingPanel?.displayIfNeeded()
    }

    private func applyPendingStatus() {
        guard let status = _pendingStatus else { return }
        _pendingStatus = nil

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        let folderStyle = NSMutableParagraphStyle()
        folderStyle.lineBreakMode = .byTruncatingMiddle
        folderStyle.paragraphSpacingBefore = 2
        let text = NSMutableAttributedString(string: status.title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titleStyle
        ])
        if !status.folder.isEmpty {
            text.append(NSAttributedString(string: "\n" + status.folder, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: folderStyle
            ]))
        }
        _loadingTextField?.attributedStringValue = text
        _detailTextField?.stringValue = status.detail

        if let indicator = _loadingProgressIndicator {
            if let fraction = status.fraction {
                if indicator.isIndeterminate {
                    indicator.stopAnimation(nil)
                    indicator.isIndeterminate = false
                    indicator.minValue = 0
                    indicator.maxValue = 1
                }
                indicator.doubleValue = fraction
            } else if !indicator.isIndeterminate {
                indicator.isIndeterminate = true
                indicator.startAnimation(nil)
            }
        }
    }

    deinit {
        if _loadingPanel != nil {
            close()
        }
    }

    @objc func close() {
        if _loadingPanel.isSheet {
            _loadingPanel.sheetParent?.endSheet(_loadingPanel)
            _loadingPanel.close()  // just hides; ownership stays with _nibTopLevelObjects
        } else {
            if let session = _loadingPanelModalSession {
                NSApplication.shared.endModalSession(session)
            }
            _loadingPanelModalSession = nil
            closeNoModalEnd()
            return
        }
        _loadingPanel = nil
        _loadingProgressIndicator = nil
        _loadingTextField = nil
        _loadingCancelButton = nil
    }

    @objc func closeNoModalEnd() {
        // the sender asked us not to end the modal session (e.g. it hit an exception)
        _loadingPanelModalSession = nil
        _loadingPanel?.close()
        _loadingPanel = nil
        _loadingProgressIndicator = nil
        _loadingTextField = nil
        _loadingCancelButton = nil
    }

    @objc(enableCancelButton:) func enableCancelButton(_ enable: Bool) {
        _loadingCancelButton.isEnabled = enable
    }

    @objc func cancelPressed() -> Bool { _cancelPressed }

    @objc func startAnimation() { _loadingProgressIndicator.startAnimation(nil) }
    @objc func stopAnimation() { _loadingProgressIndicator.stopAnimation(nil) }

    // message will be shown next time runEventLoop is called
    @objc(setMessageText:) func setMessageText(_ msg: String?) { _message = msg }

    @objc func runEventLoop() {
        // only refresh the UI every 0.2s; pumping the event loop more often eats
        // over half the total scan time
        let currentTime = getTime()
        let pumpEventLoop = _lastEventLoopRun == 0 || subtractTime(currentTime, _lastEventLoopRun) > 0.2

        if let message = _message {
            _loadingTextField.stringValue = message
            setMessageText(nil)  // so it isn't reapplied next time
            if !pumpEventLoop {
                _loadingTextField.displayIfNeeded()
            }
        }

        if pumpEventLoop {
            applyPendingStatus()
            _lastEventLoopRun = currentTime
            if let session = _loadingPanelModalSession {
                if NSApplication.shared.runModalSession(session) != .continue {
                    assertionFailure("run loop stopped by unknown party")
                }
            } else {
                RunLoop.current.run(until: Date())
            }
        }
    }

    @IBAction func cancel(_ sender: Any?) {
        _cancelPressed = true
        _loadingCancelButton.isEnabled = false
    }
}
