import Foundation
import CoreServices

/// Watches local transcript trees only; remote quota refreshes remain independently scheduled.
@MainActor
public final class LocalUsageWatcher {
    private let requestedRoots: [ProviderID: [String]]
    private let onChange: (Set<ProviderID>) -> Void
    private var plan = WatchPlan()
    private var stream: Stream?
    private var pendingDelivery: Task<Void, Never>?
    private var pendingProviders = Set<ProviderID>()
    private var needsReconfiguration = false
    private var mustReplaceStream = false

    public init(roots: [ProviderID: [String]]? = nil, onChange: @escaping (Set<ProviderID>) -> Void) {
        let providerRoots = roots ?? Self.defaultRoots()
        requestedRoots = providerRoots.mapValues { paths in
            paths.filter { !$0.isEmpty }.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
            }
        }
        self.onChange = onChange
    }

    static func defaultRoots(homeDirectory: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [ProviderID: [String]] {
        let harnessRoots = HarnessUsageLog.roots(homeDirectory: homeDirectory, environment: environment)
        // Shared harness logs may bill any provider, including an unrecognized source.
        var roots = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, harnessRoots) })
        // Account discovery lists existing directories only. Also retain configured/default
        // roots so a first-ever session created after launch is observed immediately.
        let configuredClaude = (environment["CLAUDE_CONFIG_DIR"] ?? "").split(separator: ",")
            .map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
        roots[.claude, default: []] += ([homeDirectory + "/.claude", homeDirectory + "/.config/claude"] + configuredClaude)
            .map { $0 + "/projects" }
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory + "/.codex"
        roots[.codex, default: []] += [codexHome + "/sessions", codexHome + "/archived_sessions"]
        roots[.claude, default: []] += ClaudeAccountDiscovery.historyRoots(homeDirectory: homeDirectory, environment: environment)
        roots[.codex, default: []] += CodexAccountDiscovery.historyRoots(homeDirectory: homeDirectory, environment: environment)
        return roots
    }

    /// A failed start leaves periodic scans as the fallback. Calling start twice is harmless.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        let nextPlan = makePlan()
        guard let nextStream = makeStream(paths: nextPlan.directories) else { return false }
        plan = nextPlan
        stream = nextStream
        return true
    }

    public func stop() {
        pendingDelivery?.cancel()
        pendingDelivery = nil
        pendingProviders.removeAll()
        needsReconfiguration = false
        mustReplaceStream = false
        stream = nil
        plan = WatchPlan()
    }

    deinit {
        pendingDelivery?.cancel()
        // Stream owns the C resource and tears it down even if the owner is released off-actor.
    }

    private func receive(context: CallbackContext, count: Int, paths: UnsafeMutableRawPointer,
                         flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard stream?.context === context else { return }
        let eventPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let lostEvents = FSEventStreamEventFlags(
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
        )
        let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let structural = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        let kinds = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir
                | kFSEventStreamEventFlagItemIsSymlink
        )

        for index in 0..<count {
            let event = flags[index]
            // Lost-event paths can be "/" and cannot safely be filtered by transcript root.
            if event & (lostEvents | rootChanged) != 0 {
                needsReconfiguration = true
                mustReplaceStream = mustReplaceStream || event & rootChanged != 0
                scheduleDelivery(for: plan.providers)
                continue
            }
            if event & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            // Do not standardize event paths: Foundation strips "/private" only while the
            // item exists, giving deletion events a different spelling from earlier writes.
            let path = String(cString: eventPaths[index])
            var affectedProviders = Set<ProviderID>()
            var belowRoot = false
            var aboveRoot = false
            var affectsLink = false
            for (root, providers) in plan.roots {
                let below = Self.contains(path, in: root)
                let above = Self.contains(root, in: path)
                if below || above {
                    affectedProviders.formUnion(providers)
                    belowRoot = belowRoot || below
                    aboveRoot = aboveRoot || above
                }
            }
            for (link, providers) in plan.links where Self.contains(link, in: path) {
                affectsLink = true
                affectedProviders.formUnion(providers)
            }
            guard !affectedProviders.isEmpty else { continue }

            if event & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                needsReconfiguration = true
                scheduleDelivery(for: affectedProviders)
                continue
            }
            if event & structural != 0 && (aboveRoot || affectsLink) {
                needsReconfiguration = true
                scheduleDelivery(for: affectedProviders)
            } else if belowRoot && (
                (path as NSString).pathExtension == "jsonl"
                    || event & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                    || event & kinds == 0
            ) {
                scheduleDelivery(for: affectedProviders)
            }
        }
    }

    private func scheduleDelivery(for providers: Set<ProviderID>) {
        guard !providers.isEmpty else { return }
        pendingProviders.formUnion(providers)
        // A fixed window from the first event, not trailing-edge debounce: constant appends
        // still publish regularly instead of postponing updates until a session becomes idle.
        guard pendingDelivery == nil else { return }
        pendingDelivery = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.stream != nil else { return }
            self.pendingDelivery = nil
            let providers = self.pendingProviders
            self.pendingProviders.removeAll(keepingCapacity: true)
            if self.needsReconfiguration {
                self.reconfigure()
            }
            self.onChange(providers)
        }
    }

    private func reconfigure() {
        needsReconfiguration = false
        let nextPlan = makePlan()
        if nextPlan.directories != plan.directories || mustReplaceStream {
            // Start the replacement before releasing the old stream. The ensuing full scan
            // also covers changes while a new root or symlink target was being discovered.
            if let replacement = makeStream(paths: nextPlan.directories) {
                stream = replacement
                mustReplaceStream = false
            } else {
                // Keep the old coverage, and retry on its next relevant event. Periodic scans
                // remain the fallback if the filesystem event service is unavailable.
                needsReconfiguration = true
                return
            }
        }
        plan = nextPlan
    }

    private func makePlan() -> WatchPlan {
        var roots: [String: Set<ProviderID>] = [:]
        var links: [String: Set<ProviderID>] = [:]
        var directories = Set<String>()
        var providers = Set<ProviderID>()
        for (provider, paths) in requestedRoots {
            for root in paths {
                providers.insert(provider)
                let url = URL(fileURLWithPath: root)
                let resolved = Self.physicalPath(of: url)
                roots[root, default: []].insert(provider)
                roots[resolved, default: []].insert(provider)
                // Watching the parent also catches deletion/replacement of an existing root.
                directories.insert(Self.existingAncestor(of: url.deletingLastPathComponent()))
                directories.insert(Self.existingAncestor(of: URL(fileURLWithPath: resolved).deletingLastPathComponent()))

                // FSEvents watches physical paths, not symlink targets recursively. Watch each
                // link's parent as well, so retargeting a configured root rebuilds target coverage.
                var component = url
                while component.path != "/" {
                    if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                        let parent = component.deletingLastPathComponent()
                        // Filesystem-root aliases are stable OS infrastructure. Watching "/" just
                        // to detect their retargeting would subscribe to every file on the volume.
                        if parent.path != "/" {
                            let physicalParent = Self.physicalPath(of: parent)
                            let link = (physicalParent as NSString).appendingPathComponent(component.lastPathComponent)
                            links[link, default: []].insert(provider)
                            directories.insert(Self.existingAncestor(of: parent))
                        }
                    }
                    component.deleteLastPathComponent()
                }
            }
        }
        // An ancestor stream already recursively covers its descendant watch paths.
        let minimalDirectories = directories.filter { directory in
            !directories.contains { $0 != directory && Self.contains(directory, in: $0) }
        }.sorted()
        return WatchPlan(roots: roots, links: links, directories: minimalDirectories, providers: providers)
    }

    private static func existingAncestor(of url: URL) -> String {
        var candidate = url
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return physicalPath(of: candidate)
            }
            candidate.deleteLastPathComponent()
        }
        return "/"
    }

    /// Resolve existing ancestors with realpath, retaining missing suffixes. Unlike Foundation's
    /// URL normalization this keeps the physical "/private/var" spelling FSEvents delivers,
    /// including when the requested transcript directory has not been created yet.
    private static func physicalPath(of url: URL) -> String {
        var candidate = url
        var suffix: [String] = []
        while true {
            if let resolved = realpath(candidate.path, nil) {
                defer { free(resolved) }
                return suffix.reversed().reduce(String(cString: resolved)) {
                    ($0 as NSString).appendingPathComponent($1)
                }
            }
            guard candidate.path != "/" else { return url.path }
            suffix.append(candidate.lastPathComponent)
            candidate.deleteLastPathComponent()
        }
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || root == "/" || path.hasPrefix(root + "/")
    }

    private func makeStream(paths: [String]) -> Stream? {
        guard !paths.isEmpty else { return nil }
        let callbackContext = CallbackContext(owner: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackContext).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<CallbackContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<CallbackContext>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let options = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let reference = FSEventStreamCreate(
            nil,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
                // The stream is explicitly scheduled on the main dispatch queue.
                MainActor.assumeIsolated {
                    context.owner?.receive(context: context, count: count, paths: paths, flags: flags)
                }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            options
        ) else { return nil }
        FSEventStreamSetDispatchQueue(reference, DispatchQueue.main)
        guard FSEventStreamStart(reference) else {
            FSEventStreamInvalidate(reference)
            FSEventStreamRelease(reference)
            return nil
        }
        return Stream(reference: reference, context: callbackContext)
    }

    private struct WatchPlan {
        var roots: [String: Set<ProviderID>] = [:]
        var links: [String: Set<ProviderID>] = [:]
        var directories: [String] = []
        var providers = Set<ProviderID>()
    }

    private final class CallbackContext {
        weak var owner: LocalUsageWatcher?

        init(owner: LocalUsageWatcher) {
            self.owner = owner
        }
    }

    private final class Stream {
        let reference: FSEventStreamRef
        let context: CallbackContext

        init(reference: FSEventStreamRef, context: CallbackContext) {
            self.reference = reference
            self.context = context
        }

        deinit {
            FSEventStreamStop(reference)
            FSEventStreamInvalidate(reference)
            FSEventStreamRelease(reference)
        }
    }
}
