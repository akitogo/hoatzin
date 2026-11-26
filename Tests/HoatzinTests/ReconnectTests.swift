import XCTest
@testable import Hoatzin
@testable import HoatzinCore

final class SSHExitTests: XCTestCase {
    func testCleanLogout() {
        XCTAssertEqual(SSHExit.classify(exitCode: 0, lastLines: "logout\nConnection to 10.20.30.20 closed."), .clean)
    }

    func testDroppedConnections() {
        let reboot = "root@web01:~# reboot\nConnection to 10.20.30.20 closed by remote host.\nConnection to 10.20.30.20 closed."
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: reboot), .connectionLost)
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "client_loop: send disconnect: Broken pipe"), .connectionLost)
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "Timeout, server 10.20.30.20 not responding."), .connectionLost)
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "Read from remote host web01: Operation timed out"), .connectionLost)
    }

    func testNeverConnected() {
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "ssh: connect to host 10.20.30.20 port 22: Connection refused"), .sshError)
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "kex_exchange_identification: read: Connection reset by peer"), .sshError)
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "ssh: Could not resolve hostname web01: nodename nor servname provided"), .sshError)
    }

    func testRefused() {
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "root@10.20.30.20: Permission denied (publickey,password)."), .refused)
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: "Offending key in ~/.ssh/known_hosts:3\nHost key verification failed."), .refused)
    }

    func testOnlyTheLastLinesCount() {
        // Text the user printed earlier isn't ssh's message.
        let output = "cat: write error: Broken pipe\nroot@web01:~# exit\nlogout\nsomething else"
        XCTAssertEqual(SSHExit.classify(exitCode: 255, lastLines: output), .sshError)
        XCTAssertEqual(SSHExit.classify(exitCode: 1, lastLines: "Connection to web01 closed by remote host."), .remoteExit)
        XCTAssertEqual(SSHExit.classify(exitCode: nil, lastLines: ""), .remoteExit)
    }
}

final class ReconnectPlanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testCleanExitClosesTheTabOnlyWhenWanted() {
        var plan = ReconnectPlan()
        XCTAssertEqual(plan.next(after: .clean, ranFor: 600, closeOnClean: true, autoReconnect: true), .closeTab)
        XCTAssertEqual(plan.next(after: .clean, ranFor: 600, closeOnClean: false, autoReconnect: true), .stay)
    }

    func testRetriesUntilTheServerIsBack() {
        var plan = ReconnectPlan()
        XCTAssertEqual(plan.next(after: .connectionLost, ranFor: 3600, now: start, closeOnClean: true, autoReconnect: true),
                       .retry(attempt: 1, delay: 2))
        XCTAssertTrue(plan.isActive)
        // The server is still restarting: refused connections and timeouts are tried again.
        XCTAssertEqual(plan.next(after: .sshError, ranFor: 0.1, now: start + 3, closeOnClean: true, autoReconnect: true),
                       .retry(attempt: 2, delay: 5))
        XCTAssertEqual(plan.next(after: .sshError, ranFor: 10, now: start + 20, closeOnClean: true, autoReconnect: true),
                       .retry(attempt: 3, delay: 10))
        // An attempt that got in and dropped much later starts a new round.
        XCTAssertEqual(plan.next(after: .connectionLost, ranFor: 900, now: start + 1000, closeOnClean: true, autoReconnect: true),
                       .retry(attempt: 1, delay: 2))
    }

    func testGivesUpAfterTheWindow() {
        var plan = ReconnectPlan()
        _ = plan.next(after: .connectionLost, ranFor: 3600, now: start, closeOnClean: true, autoReconnect: true)
        XCTAssertEqual(plan.next(after: .sshError, ranFor: 10, now: start + ReconnectPlan.window + 1,
                                 closeOnClean: true, autoReconnect: true), .gaveUp)
        XCTAssertFalse(plan.isActive)
    }

    func testStopsWhenTheLoginIsRefused() {
        var plan = ReconnectPlan()
        _ = plan.next(after: .connectionLost, ranFor: 3600, now: start, closeOnClean: true, autoReconnect: true)
        XCTAssertEqual(plan.next(after: .refused, ranFor: 2, now: start + 5, closeOnClean: true, autoReconnect: true), .stay)
        XCTAssertFalse(plan.isActive)
    }

    func testNoRoundWithoutADrop() {
        var plan = ReconnectPlan()
        // A host that couldn't be reached in the first place isn't retried.
        XCTAssertEqual(plan.next(after: .sshError, ranFor: 75, now: start, closeOnClean: true, autoReconnect: true), .stay)
        XCTAssertEqual(plan.next(after: .remoteExit, ranFor: 60, now: start, closeOnClean: true, autoReconnect: true), .stay)
        // Switched off in Settings.
        XCTAssertEqual(plan.next(after: .connectionLost, ranFor: 3600, now: start, closeOnClean: true, autoReconnect: false), .stay)
        XCTAssertFalse(plan.isActive)
    }
}
