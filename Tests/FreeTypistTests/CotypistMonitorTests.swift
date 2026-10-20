import XCTest
@testable import FreeTypist

final class CotypistMonitorTests: XCTestCase {
    @MainActor
    func testInstalledDoesNotMeanRunningAndDetectionRefreshes() {
        var processes: [pid_t] = []
        let monitor = CotypistMonitor(runningProcessIDs: { processes },
            locateApp: { URL(fileURLWithPath: "/Applications/Cotypist.app") })
        XCTAssertTrue(monitor.isInstalled)
        XCTAssertFalse(monitor.isRunning)
        processes = [100, 200]
        monitor.refresh()
        XCTAssertEqual(monitor.runningProcessCount, 2)
        processes = []
        monitor.refresh()
        XCTAssertFalse(monitor.isRunning)
    }

    @MainActor
    func testQuitRequestsEveryDetectedInstanceAndUpdatesStatus() {
        var processes: [pid_t] = [100, 200]
        var requests: [pid_t] = []
        let monitor = CotypistMonitor(runningProcessIDs: { processes }, requestTermination: { pid in
            requests.append(pid)
            processes.removeAll { $0 == pid }
            return true
        }, locateApp: { nil })
        monitor.quitCotypist()
        XCTAssertEqual(requests, [100, 200])
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(monitor.isQuitting)
        XCTAssertNil(monitor.actionError)
    }

    @MainActor
    func testARefusedQuitStillRequestsTheOtherInstanceAndReportsFailure() {
        var requests: [pid_t] = []
        let monitor = CotypistMonitor(runningProcessIDs: { [100, 200] }, requestTermination: { pid in
            requests.append(pid)
            return false
        }, locateApp: { nil })
        monitor.quitCotypist()
        XCTAssertEqual(requests, [100, 200])
        XCTAssertTrue(monitor.isRunning)
        XCTAssertFalse(monitor.isQuitting)
        XCTAssertNotNil(monitor.actionError)
    }

    @MainActor
    func testAQuitThatDoesNotFinishTimesOutAndCanBeRetried() async throws {
        var processes: [pid_t] = [100]
        let monitor = CotypistMonitor(runningProcessIDs: { processes }, requestTermination: { _ in true },
            locateApp: { nil }, quitTimeoutNanoseconds: 10_000_000)
        monitor.quitCotypist()
        XCTAssertTrue(monitor.isQuitting)
        for _ in 0..<50 {
            if !monitor.isQuitting { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(monitor.isQuitting)
        XCTAssertNotNil(monitor.actionError)
        processes = []
        monitor.refresh()
        XCTAssertNil(monitor.actionError)
    }

    @MainActor
    func testSuccessfulTerminationCancelsAStaleQuitWarning() async throws {
        var processes: [pid_t] = [100]
        let monitor = CotypistMonitor(runningProcessIDs: { processes }, requestTermination: { _ in true },
            locateApp: { nil }, quitTimeoutNanoseconds: 20_000_000)
        monitor.quitCotypist()
        processes = []
        monitor.refresh()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(monitor.isQuitting)
        XCTAssertNil(monitor.actionError)
    }

    @MainActor
    func testTheDefaultQuitOperationRefusesAnUnrelatedProcess() {
        let monitor = CotypistMonitor(runningProcessIDs: { [ProcessInfo.processInfo.processIdentifier] }, locateApp: { nil })
        monitor.quitCotypist()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertFalse(monitor.isQuitting)
        XCTAssertNotNil(monitor.actionError)
    }
}
