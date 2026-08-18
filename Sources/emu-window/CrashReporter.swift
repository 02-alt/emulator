import Foundation

/// Writes a crash report when the app dies from an uncaught Objective-C exception or a fatal signal
/// (SIGSEGV/SIGABRT/… — this also covers Swift `fatalError`/`precondition`, which trap via SIGTRAP
/// on Apple Silicon). Reports land in `~/Library/Application Support/Emulator/crashes/` as timestamped
/// `.log` files with a backtrace, then the crash is re-raised so macOS still produces its own report
/// and the process terminates.
///
/// Note: signal handlers are meant to use only async-signal-safe calls; the Foundation/String/
/// backtrace calls here technically aren't. This is the pragmatic tradeoff common to lightweight
/// in-app crash loggers — the process is already dying — and it captures the vast majority of crashes.
enum CrashReporter {
    // Runs on the crashing thread (not the main actor); guards against a crash while reporting.
    nonisolated(unsafe) private static var isHandling = false

    /// Where crash logs are written.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Emulator/crashes", isDirectory: true)
    }

    /// The newest crash report the user hasn't been shown yet, or nil. Calling this marks every
    /// current report as seen, so a given crash surfaces exactly once (on the next launch).
    static func pendingReport() -> URL? {
        let key = "crash.lastSeenReport"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        guard let newest = files.filter({ $0.pathExtension == "log" }).max(by: { mtime($0) < mtime($1) })
        else { return nil }
        let stamp = mtime(newest).timeIntervalSince1970
        guard stamp > UserDefaults.standard.double(forKey: key) else { return nil }
        UserDefaults.standard.set(stamp, forKey: key)
        return newest
    }

    /// Install the handlers as early as possible (before `app.run()`).
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let body = """
            Uncaught exception: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "—")

            Call stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            CrashReporter.write(body, kind: "exception")
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { received in CrashReporter.handleSignal(received) }
        }
    }

    private static func handleSignal(_ sig: Int32) {
        let name = strsignal(sig).map { String(cString: $0) } ?? "signal \(sig)"
        let body = """
        Fatal signal: \(name) (\(sig))

        Call stack:
        \(Thread.callStackSymbols.joined(separator: "\n"))
        """
        write(body, kind: "signal")

        // Restore the default handler and re-raise so macOS produces its report and we terminate.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func write(_ body: String, kind: String) {
        guard !isHandling else { return }
        isHandling = true

        let stamp = ISO8601DateFormatter().string(from: Date())
        let report = """
        \(AppInfo.name) crash report
        Date:  \(stamp)
        Kind:  \(kind)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        PID:   \(ProcessInfo.processInfo.processIdentifier)

        \(body)

        """

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileStamp = stamp.replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("crash-\(fileStamp).log")
        try? report.data(using: .utf8)?.write(to: url)

        FileHandle.standardError.write(Data("\n[CrashReporter] wrote \(url.path)\n".utf8))
    }
}
