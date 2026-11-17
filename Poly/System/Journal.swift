import AppKit
import SystemConfiguration

/// Poly's own log file, kept so a handoff can be diagnosed after the fact, on any Mac.
///
/// The unified log alone is not enough: it ages out, and it can only be read on the Mac it
/// happened on. So every log line is also appended to `~/Library/Logs/Poly/Poly.log` (2 MB, then
/// it moves to `Poly.previous.log`), which Console shows under Log Reports. A minute after Poly
/// writes, the end of the file (about the last few days of activity, compressed to at most 48 KB)
/// is copied to the person's iCloud key-value storage under `diagnostics.<random id>`, so their
/// other Macs can read it: `scripts/diagnostics.sh` (Poly's `--export-diagnostics`) writes every
/// Mac's copy to a folder. The copy stays in the person's own iCloud account; Poly sends nothing
/// anywhere else, and a Mac without iCloud simply keeps its file.
nonisolated final class Journal: @unchecked Sendable {
    static let shared = Journal()

    static let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Poly", isDirectory: true)
    static let file = directory.appendingPathComponent("Poly.log")
    static let previousFile = directory.appendingPathComponent("Poly.previous.log")
    static let cloudPrefix = "diagnostics."

    private static let maxFileSize = 2_000_000
    /// The compressed copy in iCloud, per Mac. Key-value storage holds 1 MB per app in all, shared
    /// with monitor names, so a handful of Macs fit with room to spare.
    private static let maxCloudSize = 48_000
    /// Copies of Macs not heard from in this long are removed, to stay well inside that 1 MB.
    private static let cloudLifetime: TimeInterval = 30 * 24 * 3600

    // Touched only on `queue`.
    private let queue = DispatchQueue(label: "work.lau.poly.journal", qos: .utility)
    private var handle: FileHandle?
    private var size = 0
    private var mirroring = false
    private var uploadScheduled = false
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()

    func write(_ category: String, _ message: String) {
        let date = Date.now
        queue.async { [self] in
            let line = "\(formatter.string(from: date)) [\(category)] \(message)\n"
            append(Data(line.utf8))
            scheduleUpload(after: 60)
        }
    }

    /// Starts mirroring to iCloud and records what is running. Called once, at launch.
    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        Log.app.info(
            "Poly \(version) (\(build)) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.model)"
        )
        queue.async { [self] in
            mirroring = true
            scheduleUpload(after: 10)
        }
        Task { @MainActor in Self.pruneCloud() }
    }

    // MARK: The file

    private func append(_ data: Data) {
        if handle == nil { open() }
        guard let handle else { return }
        _ = try? handle.seekToEnd()
        guard (try? handle.write(contentsOf: data)) != nil else { return }
        size += data.count
        if size > Self.maxFileSize { rotate() }
    }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: Self.file.path) { manager.createFile(atPath: Self.file.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: Self.file)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: Self.previousFile)
        try? manager.moveItem(at: Self.file, to: Self.previousFile)
    }

    /// The end of the journal, the previous file first, at most `limit` bytes, from a line start.
    private static func tail(_ limit: Int) -> Data {
        var data = (try? Data(contentsOf: file)) ?? Data()
        if data.count < limit, let previous = try? Data(contentsOf: previousFile) {
            data = previous + data
        }
        guard data.count > limit else { return data }
        var tail = data.suffix(limit)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[(newline + 1)...] }
        return Data(tail)
    }

    // MARK: iCloud

    private func scheduleUpload(after seconds: Double) {
        guard mirroring, !uploadScheduled else { return }
        uploadScheduled = true
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            uploadScheduled = false
            guard let compressed = Self.compressedTail() else { return }
            Task { @MainActor in Self.upload(compressed) }
        }
    }

    /// As much of the end of the journal as compresses into the iCloud budget.
    private static func compressedTail() -> Data? {
        var limit = 1_000_000
        while limit >= 4_000 {
            let tail = tail(limit)
            guard let compressed = try? (tail as NSData).compressed(using: .zlib) as Data else { return nil }
            if compressed.count <= maxCloudSize { return compressed }
            limit /= 2
        }
        return nil
    }

    @MainActor private static func upload(_ compressed: Data) {
        let info = Bundle.main.infoDictionary ?? [:]
        let entry: [String: Any] = [
            "computer": computerName,
            "model": model,
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "version": "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "updated": Date.now,
            "log": compressed,
        ]
        NSUbiquitousKeyValueStore.default.set(entry, forKey: cloudPrefix + macID)
    }

    @MainActor private static func pruneCloud() {
        let cloud = NSUbiquitousKeyValueStore.default
        for (key, value) in cloud.dictionaryRepresentation where key.hasPrefix(cloudPrefix) {
            let updated = (value as? [String: Any])?["updated"] as? Date ?? .distantPast
            if Date.now.timeIntervalSince(updated) > cloudLifetime { cloud.removeObject(forKey: key) }
        }
    }

    // MARK: Reading it back

    /// Writes this Mac's journal and every Mac's iCloud copy to `directory`, one file per Mac.
    /// Runs instead of the app (`--export-diagnostics`), touching neither Bluetooth nor displays.
    @MainActor static func export(to directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = ((try? Data(contentsOf: previousFile)) ?? Data()) + ((try? Data(contentsOf: file)) ?? Data())
        try? local.write(to: directory.appendingPathComponent(fileName("\(computerName) (this Mac)")))

        // Key-value storage fetches from iCloud in the background; give it a few seconds.
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        RunLoop.main.run(until: .now.addingTimeInterval(6))

        for (key, value) in cloud.dictionaryRepresentation where key.hasPrefix(cloudPrefix) && key != cloudPrefix + macID {
            guard let entry = value as? [String: Any], let compressed = entry["log"] as? Data,
                let log = try? (compressed as NSData).decompressed(using: .zlib) as Data
            else { continue }
            let computer = entry["computer"] as? String ?? "Mac"
            let id = key.dropFirst(cloudPrefix.count).prefix(6)
            let header = """
                # \(computer), \(entry["model"] as? String ?? "?"), \(entry["system"] as? String ?? "?")
                # Poly \(entry["version"] as? String ?? "?"), copied to iCloud \(entry["updated"] as? Date ?? .distantPast)

                """
            try? (Data(header.utf8) + log).write(to: directory.appendingPathComponent(fileName("\(computer) \(id)")))
        }
    }

    private static func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".log"
    }

    // MARK: This Mac

    /// A random identifier for this Mac's copy; it says nothing about the Mac.
    private static let macID: String = {
        let key = "diagnosticsID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// The name in Sharing settings, so the person can tell their Macs apart.
    private static var computerName: String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
    }

    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }()
}
