//
//  Timing.swift
//  Disk Inventory Xs
//
//  Swift port of Timing.{h,c}. A monotonic stopwatch used to throttle the scan
//  progress panel and to time the render/layout benchmarks. Swift-only callers,
//  so these are plain global functions.
//
//  Implemented on top of DispatchTime's monotonic uptime clock (available since
//  10.10), which reads the same mach timebase under the hood but already returns
//  nanoseconds — so no manual mach_timebase_info conversion is needed. (The
//  deployment target is 10.13, so the newer ContinuousClock/Duration API isn't
//  available here.)
//
//  GPL v3
//

import Foundation

// Nanoseconds per second, used to convert the UInt64 token to elapsed seconds.
private let nanosecondsPerSecond: Double = 1e9

func getTime() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func subtractTime(_ endTime: UInt64, _ startTime: UInt64) -> Double {
    Double(endTime - startTime) / nanosecondsPerSecond
}
