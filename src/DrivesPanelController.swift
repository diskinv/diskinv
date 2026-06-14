//
//  DrivesPanelController.swift
//  Disk Inventory Xs
//
//  Swift port of DrivesPanelController.{h,m}. Shared singleton that owns
//  VolumesPanel.nib and lists the mounted volumes (icon, name, capacity, free,
//  and a per-row usage bar). Nib owner, so the class name, IBOutlets, the
//  openVolume: action, the `volumes` KVO key, and the table delegate methods
//  are pinned with @objc.
//
//  GPL v3
//

import Cocoa

@objc(DrivesPanelController)
class DrivesPanelController: NSObject {

    @IBOutlet private var _volumesTableView: NSTableView!
    @IBOutlet private var _volumesPanel: NSWindow!
    @IBOutlet private var _openVolumeButton: NSButton!
    @IBOutlet private var _volumesController: NSArrayController!

    private var _volumes: [NSMutableDictionary] = []
    private var _progressIndicators: [NSProgressIndicator] = []
    private var _maxVolumeSize: UInt64 = 0
    private var _nibTopLevelObjects: [Any]?

    @objc(sharedController)
    static let sharedController = DrivesPanelController()

    private static let volumeProperties: [URLResourceKey] = [
        .localizedNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeSupportsVolumeSizesKey,
        .volumeLocalizedFormatDescriptionKey,
    ]

    @objc override init() {
        super.init()

        // register the volume transformers used by the table (before the nib loads!)
        ValueTransformer.setValueTransformer(VolumeNameTransformer.transformer(), forName: NSValueTransformerName("volumeNameTransformer"))
        ValueTransformer.setValueTransformer(VolumeUsageTransformer.transformer(), forName: NSValueTransformerName("volumeUsageTransformer"))

        let wsNotiCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            wsNotiCenter.addObserver(self, selector: #selector(onVolumesChanged(_:)), name: name, object: nil)
        }

        rebuildVolumesArray()

        var topLevelObjects: NSArray?
        if !Bundle.main.loadNibNamed("VolumesPanel", owner: self, topLevelObjects: &topLevelObjects) {
            assertionFailure("couldn't load VolumesPanel.nib")
        } else {
            _nibTopLevelObjects = topLevelObjects as? [Any]

            // the nib has "release when closed = YES"; turn it off so the panel's
            // lifetime is governed by _nibTopLevelObjects only (otherwise closing
            // it frees the panel while the array holds a stale pointer → zombie).
            _volumesPanel.isReleasedWhenClosed = false

            // open the volume on double-click (can't be set in IB)
            _volumesTableView.doubleAction = #selector(openVolume(_:))

            let sizeFormatter = FileSizeFormatter()
            (_volumesTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("totalSize"))?.dataCell as? NSCell)?.formatter = sizeFormatter
            (_volumesTableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("freeBytes"))?.dataCell as? NSCell)?.formatter = sizeFormatter
        }

        _volumesPanel?.makeFirstResponder(_volumesTableView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func volumes() -> [Any] { _volumes }

    @IBAction func openVolume(_ sender: Any?) {
        let selectedIndexes = _volumesTableView.selectedRowIndexes
        for index in selectedIndexes {
            guard let volume = _volumes[index]["volume"] as? NSURL, volume.stillExists() else { continue }
            guard let path = volume.path else { continue }

            // defer to the next loop cycle (otherwise the "Open Volume" button
            // stays visually pressed during the loading)
            DispatchQueue.main.async {
                (NSDocumentController.shared as? MyDocumentController)?.openDocument(withContentsOfFile: path)
            }
        }
    }

    @objc func panelIsVisible() -> Bool { panel().isVisible }

    @objc func showPanel() { panel().orderFront(nil) }

    @objc func panel() -> NSWindow { _volumesPanel }

    // MARK: - private

    // fill _volumes with the mounted volumes and their icons
    private func rebuildVolumesArray() {
        _maxVolumeSize = 0

        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.volumeProperties,
                                                         options: .skipHiddenVolumes) ?? []

        willChangeValue(forKey: "volumes")

        _volumes = []
        for volumeURL in vols {
            let nsURL = volumeURL as NSURL
            nsURL.cacheResources(in: Self.volumeProperties)

            let entry = NSMutableDictionary()
            entry["volume"] = nsURL

            let volImage = nsURL.icon()
            volImage?.size = NSSize(width: 32, height: 32)
            entry["image"] = volImage ?? NSNull()

            _volumes.append(entry)

            let capacity = nsURL.volumeTotalCapacity()?.uint64Value ?? 0
            if capacity > _maxVolumeSize {
                _maxVolumeSize = capacity
            }
        }

        rebuildProgressIndicatorArray()

        didChangeValue(forKey: "volumes")
    }

    // keep the per-row usage progress indicators in sync with _volumes
    private func rebuildProgressIndicatorArray() {
        for i in 0..<_volumes.count {
            let progrInd: NSProgressIndicator
            if i >= _progressIndicators.count {
                progrInd = NSProgressIndicator()
                progrInd.style = .bar
                progrInd.isIndeterminate = false
                _progressIndicators.append(progrInd)
            } else {
                progrInd = _progressIndicators[i]
            }

            let vol = _volumes[i]["volume"] as! NSURL
            if vol.getCachedBoolValue(URLResourceKey.volumeSupportsVolumeSizesKey.rawValue) {
                let totalBytes = vol.volumeTotalCapacity()?.doubleValue ?? 0
                let freeBytes = vol.volumeAvailableCapacity()?.doubleValue ?? 0
                progrInd.minValue = 0
                progrInd.maxValue = totalBytes
                progrInd.doubleValue = totalBytes - freeBytes
            } else {
                progrInd.minValue = 0
                progrInd.maxValue = 0
                progrInd.doubleValue = 0
            }
        }

        while _progressIndicators.count > _volumes.count {
            _progressIndicators.last?.removeFromSuperviewWithoutNeedingDisplay()
            _progressIndicators.removeLast()
        }
    }

    @objc private func onVolumesChanged(_ notification: Notification) {
        rebuildVolumesArray()
    }

    // MARK: - NSTableView delegate

    @objc(tableViewSelectionDidChange:)
    func tableViewSelectionDidChange(_ notification: Notification) {
    }

    @objc(tableView:willDisplayCell:forTableColumn:row:)
    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any,
                   for tableColumn: NSTableColumn?, row: Int) {
        guard tableColumn?.identifier.rawValue == "usagePercent" else { return }

        let progrInd = _progressIndicators[row]

        // add the progress indicator as a subview of the table view
        if progrInd.superview != tableView {
            tableView.addSubview(progrInd)
        }

        let colIndex = tableView.column(withIdentifier: tableColumn!.identifier)
        var cellRect = tableView.frameOfCell(atColumn: colIndex, row: row)

        let progrIndThickness: CGFloat = 18  // NSProgressIndicatorPreferredLargeThickness (unavailable in Swift)
        let extraSpace: CGFloat = 16  // space before and after the indicator within the cell

        // center it vertically in the cell
        cellRect.origin.y += (cellRect.height - progrIndThickness) / 2
        cellRect.size.height = progrIndThickness

        cellRect.origin.x += extraSpace
        cellRect.size.width -= 2 * extraSpace

        let volURL = _volumes[row]["volume"] as! NSURL
        if volURL.getCachedBoolValue(URLResourceKey.volumeSupportsVolumeSizesKey.rawValue) {
            let fraction = (volURL.cachedVolumeTotalCapacity()?.doubleValue ?? 0) / Double(_maxVolumeSize)
            // show each volume as at least 20% of the width, else it's too narrow to see
            cellRect.size.width *= CGFloat(fmax(fraction, 0.2))
        } else {
            cellRect.size.width = 0  // no size info: hide the indicator
        }

        progrInd.frame = cellRect
        progrInd.stopAnimation(nil)
    }
}
