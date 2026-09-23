import XCTest
@testable import TokenWatchCore

@MainActor
final class LocalUsageWatcherTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testAppendDeliversOnMainActor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        var changed: XCTestExpectation? = expectation(description: "appended transcript detected")
        let delivered = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.claude: [directory.path]]) { providers in
            XCTAssertEqual(providers, [.claude])
            MainActor.preconditionIsolated()
            XCTAssertTrue(Thread.isMainThread)
            guard (try? String(contentsOf: file, encoding: .utf8)) == "{}\n{\"tokens\":1}\n" else { return }
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.start(), "starting an active watcher is idempotent")

        try append("{\"tokens\":1}\n", to: file)
        await fulfillment(of: [delivered], timeout: 5)
    }

    func testLateCreatedRootAndNestedFileRemainWatched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("missing/config/sessions", isDirectory: true)
        let nested = root.appendingPathComponent("project/nested", isDirectory: true)
        let file = nested.appendingPathComponent("new.jsonl")
        var expectedContents = "{}\n"
        var changed: XCTestExpectation? = expectation(description: "new transcript tree detected")
        let created = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.codex: [root.path]]) { providers in
            XCTAssertEqual(providers, [.codex])
            guard (try? String(contentsOf: file, encoding: .utf8)) == expectedContents else { return }
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try expectedContents.write(to: file, atomically: false, encoding: .utf8)
        await fulfillment(of: [created], timeout: 5)

        changed = expectation(description: "append beneath newly created root detected")
        let appended = try XCTUnwrap(changed)
        expectedContents += "{\"tokens\":2}\n"
        try append("{\"tokens\":2}\n", to: file)
        await fulfillment(of: [appended], timeout: 5)
    }

    func testStopPreventsDeliveryAndCanRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        let codexRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: codexRoot) }
        let codexFile = codexRoot.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: codexFile, atomically: false, encoding: .utf8)
        var changed: XCTestExpectation? = expectation(description: "watcher active")
        let initial = try XCTUnwrap(changed)
        let stopped = expectation(description: "no callbacks after stop")
        stopped.isInverted = true
        var isStopped = false
        var checkingRestart = false
        let watcher = LocalUsageWatcher(roots: [.claude: [directory.path], .codex: [codexRoot.path]]) { providers in
            if checkingRestart { XCTAssertEqual(providers, [.claude]) }
            if isStopped {
                stopped.fulfill()
            } else {
                changed?.fulfill()
                changed = nil
            }
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: file)
        await fulfillment(of: [initial], timeout: 5)

        try append("{}\n", to: codexFile)
        // Allow an event to enter its coalescing window, then stop before delivery.
        try await Task.sleep(nanoseconds: 100_000_000)
        watcher.stop()
        watcher.stop()
        isStopped = true
        try append("{}\n", to: codexFile)
        await fulfillment(of: [stopped], timeout: 1)

        isStopped = false
        checkingRestart = true
        changed = expectation(description: "restarted watcher active")
        let restarted = try XCTUnwrap(changed)
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: file)
        await fulfillment(of: [restarted], timeout: 5)
    }

    func testConfiguredSymlinkRetargetsToNewTranscriptTree() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstParent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: firstParent) }
        let secondParent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondParent) }
        let first = firstParent.appendingPathComponent("first", isDirectory: true)
        let second = secondParent.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: first)
        let file = root.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        try "{\"target\":2}\n".write(to: second.appendingPathComponent("session.jsonl"), atomically: false, encoding: .utf8)
        var expectedContents = "{}\n{}\n"
        var changed: XCTestExpectation? = expectation(description: "original symlink target watched")
        let original = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.codex: [root.path]]) { providers in
            XCTAssertEqual(providers, [.codex])
            guard (try? String(contentsOf: file, encoding: .utf8)) == expectedContents else { return }
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: file)
        await fulfillment(of: [original], timeout: 5)

        changed = expectation(description: "symlink retarget detected")
        let retargeted = try XCTUnwrap(changed)
        expectedContents = "{\"target\":2}\n"
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: second)
        await fulfillment(of: [retargeted], timeout: 5)

        changed = expectation(description: "new symlink target watched")
        let appended = try XCTUnwrap(changed)
        expectedContents += "{}\n"
        try append("{}\n", to: file)
        await fulfillment(of: [appended], timeout: 5)
    }

    func testReplacementThenDeletionUpdatesWatchedHistory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("usage.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        var expectedContents: String? = "{\"replacement\":true}\n"
        var changed: XCTestExpectation? = expectation(description: "replacement detected")
        let replaced = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.claude: [root.path]]) { providers in
            XCTAssertEqual(providers, [.claude])
            guard (try? String(contentsOf: file, encoding: .utf8)) == expectedContents else { return }
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try XCTUnwrap(expectedContents).write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [replaced], timeout: 5)

        expectedContents = nil
        changed = expectation(description: "deleted transcript detected")
        let deleted = try XCTUnwrap(changed)
        try FileManager.default.removeItem(at: file)
        await fulfillment(of: [deleted], timeout: 5)
    }

    func testRunningStreamDoesNotRetainWatcher() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let callback = expectation(description: "released watcher cannot deliver")
        callback.isInverted = true
        var watcher: LocalUsageWatcher? = LocalUsageWatcher(roots: [.claude: [directory.path]]) { _ in
            callback.fulfill()
        }
        weak let released = watcher
        XCTAssertEqual(watcher?.start(), true)
        let file = directory.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        watcher = nil
        XCTAssertNil(released)
        try append("{}\n", to: file)
        await fulfillment(of: [callback], timeout: 1)
    }

    func testSeparateRootsNotifyOnlyTheirOwningProvider() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        let codexRoot = directory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let claudeFile = claudeRoot.appendingPathComponent("session.jsonl")
        let codexFile = codexRoot.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: claudeFile, atomically: false, encoding: .utf8)
        try "{}\n".write(to: codexFile, atomically: false, encoding: .utf8)
        // FSEvents can deliver buffered directory creation after start. Drain that initial
        // reconciliation before asserting ownership of subsequent isolated writes.
        var expectedProvider: ProviderID?
        var changed: XCTestExpectation? = expectation(description: "initial tree reconciled")
        let initial = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.claude: [claudeRoot.path], .codex: [codexRoot.path]]) { providers in
            if let expectedProvider { XCTAssertEqual(providers, [expectedProvider]) }
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: claudeFile)
        try append("{}\n", to: codexFile)
        await fulfillment(of: [initial], timeout: 5)

        expectedProvider = .claude
        changed = expectation(description: "only Claude changed")
        let claudeChanged = try XCTUnwrap(changed)
        try append("{}\n", to: claudeFile)
        await fulfillment(of: [claudeChanged], timeout: 5)

        expectedProvider = .codex
        changed = expectation(description: "only Codex changed")
        let codexChanged = try XCTUnwrap(changed)
        try append("{}\n", to: codexFile)
        await fulfillment(of: [codexChanged], timeout: 5)
    }

    func testBurstUnionsProvidersInOneDelivery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let claudeRoot = directory.appendingPathComponent("claude", isDirectory: true)
        let codexRoot = directory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let claudeFile = claudeRoot.appendingPathComponent("session.jsonl")
        let codexFile = codexRoot.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: claudeFile, atomically: false, encoding: .utf8)
        try "{}\n".write(to: codexFile, atomically: false, encoding: .utf8)
        var changed: XCTestExpectation? = expectation(description: "initial tree reconciled")
        let initial = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.claude: [claudeRoot.path], .codex: [codexRoot.path]]) { providers in
            XCTAssertEqual(providers, [.claude, .codex])
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: claudeFile)
        try append("{}\n", to: codexFile)
        await fulfillment(of: [initial], timeout: 5)
        changed = expectation(description: "both providers in one callback")
        let delivered = try XCTUnwrap(changed)
        try append("{}\n", to: claudeFile)
        try await Task.sleep(nanoseconds: 100_000_000)
        try append("{}\n", to: codexFile)
        await fulfillment(of: [delivered], timeout: 5)
    }

    func testSharedRootNotifiesBothProviders() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        var changed: XCTestExpectation? = expectation(description: "shared omp-style root changed")
        let delivered = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.claude: [directory.path], .codex: [directory.path]]) { providers in
            XCTAssertEqual(providers, [.claude, .codex])
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: file)
        await fulfillment(of: [delivered], timeout: 5)
    }

    func testSharedPhysicalRootRetainsBothAliasOwners() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let physicalRoot = directory.appendingPathComponent("physical", isDirectory: true)
        let aliasRoot = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: physicalRoot)
        let file = physicalRoot.appendingPathComponent("usage.jsonl")
        try "{}\n".write(to: file, atomically: false, encoding: .utf8)
        var changed: XCTestExpectation? = expectation(description: "physical root has both providers")
        let delivered = try XCTUnwrap(changed)
        let watcher = LocalUsageWatcher(roots: [.claude: [aliasRoot.path], .codex: [physicalRoot.path]]) { providers in
            XCTAssertEqual(providers, [.claude, .codex])
            changed?.fulfill()
            changed = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: file)
        await fulfillment(of: [delivered], timeout: 5)
    }

    func testUnrelatedSiblingAndNonTranscriptFilesDoNotNotify() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("sessions", isDirectory: true)
        let sibling = directory.appendingPathComponent("sessions-other", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let unrelated = sibling.appendingPathComponent("session.jsonl")
        let nonTranscript = root.appendingPathComponent("notes.txt")
        try "{}\n".write(to: unrelated, atomically: false, encoding: .utf8)
        try "notes\n".write(to: nonTranscript, atomically: false, encoding: .utf8)
        let transcript = root.appendingPathComponent("session.jsonl")
        try "{}\n".write(to: transcript, atomically: false, encoding: .utf8)
        var ready: XCTestExpectation? = expectation(description: "initial tree reconciled")
        let initial = try XCTUnwrap(ready)
        var checkingUnrelated = false
        let changed = expectation(description: "unrelated paths ignored")
        changed.isInverted = true
        let watcher = LocalUsageWatcher(roots: [.claude: [root.path]]) { _ in
            if checkingUnrelated { changed.fulfill() }
            ready?.fulfill()
            ready = nil
        }
        defer { watcher.stop() }
        XCTAssertTrue(watcher.start())
        try append("{}\n", to: transcript)
        await fulfillment(of: [initial], timeout: 5)
        checkingUnrelated = true
        try append("{}\n", to: unrelated)
        try append("more\n", to: nonTranscript)
        await fulfillment(of: [changed], timeout: 1)
    }
}
