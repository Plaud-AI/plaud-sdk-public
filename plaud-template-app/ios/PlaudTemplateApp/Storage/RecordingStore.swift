import Foundation

/// Local data persistence: recording file metadata (JSON file) + user settings (UserDefaults)
final class RecordingStore {

    static let shared = RecordingStore()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let lastConnectedDeviceSN = "lastConnectedDeviceSN" // legacy compatibility
        static let pairedDeviceSNs = "pairedDeviceSNs"
        static let activeDeviceSN = "activeDeviceSN"
        static let pairedDeviceNames = "pairedDeviceNames" // [SN: name] mapping
        static let userId = "userId"
        static let autoSyncEnabled = "autoSyncEnabled"
    }

    // MARK: - Multi-Device Management

    /// List of paired device serial numbers
    var pairedDeviceSNs: [String] {
        get {
            let sns = UserDefaults.standard.stringArray(forKey: Keys.pairedDeviceSNs) ?? []
            // Legacy migration: migrate lastConnectedDeviceSN
            if sns.isEmpty, let old = UserDefaults.standard.string(forKey: Keys.lastConnectedDeviceSN) {
                UserDefaults.standard.set([old], forKey: Keys.pairedDeviceSNs)
                UserDefaults.standard.set(old, forKey: Keys.activeDeviceSN)
                return [old]
            }
            return sns
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pairedDeviceSNs) }
    }

    /// Currently active device SN
    var activeDeviceSN: String? {
        get { UserDefaults.standard.string(forKey: Keys.activeDeviceSN) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.activeDeviceSN) }
    }

    /// Paired device name cache [SN: name]
    private var pairedDeviceNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.pairedDeviceNames) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pairedDeviceNames) }
    }

    /// Add a paired device
    func addPairedDevice(sn: String, name: String) {
        var sns = pairedDeviceSNs
        if !sns.contains(sn) { sns.append(sn) }
        pairedDeviceSNs = sns
        var names = pairedDeviceNames
        names[sn] = name
        pairedDeviceNames = names
        activeDeviceSN = sn
    }

    /// Remove a paired device
    func removePairedDevice(sn: String) {
        var sns = pairedDeviceSNs
        sns.removeAll { $0 == sn }
        pairedDeviceSNs = sns
        var names = pairedDeviceNames
        names.removeValue(forKey: sn)
        pairedDeviceNames = names
        // If removing the active device, switch to the next one
        if activeDeviceSN == sn {
            activeDeviceSN = sns.first
        }
    }

    /// Get device name by SN
    func deviceName(for sn: String) -> String {
        pairedDeviceNames[sn] ?? sn
    }

    /// [Legacy compatibility] Equivalent to activeDeviceSN
    var lastConnectedDeviceSN: String? {
        get { activeDeviceSN }
        set {
            activeDeviceSN = newValue
            if let sn = newValue, !pairedDeviceSNs.contains(sn) {
                addPairedDevice(sn: sn, name: sn)
            }
        }
    }

    var userId: String? {
        get { UserDefaults.standard.string(forKey: Keys.userId) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.userId) }
    }

    var isAutoSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.autoSyncEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoSyncEnabled) }
    }

    // MARK: - File List

    private var cache: [RecordingFile] = []
    private let storeURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = docs.appendingPathComponent("recordings.json")
        cache = loadFromDisk()
    }

    var allFiles: [RecordingFile] {
        cache.sorted { $0.createdAt > $1.createdAt }
    }

    func addFiles(_ files: [RecordingFile]) {
        // Deduplicate: skip if sessionId already exists
        let existingIds = Set(cache.map { $0.sessionId })
        let newFiles = files.filter { !existingIds.contains($0.sessionId) }
        cache.append(contentsOf: newFiles)
        saveToDisk()
    }

    func deleteFile(id: String) {
        cache.removeAll { $0.id == id }
        saveToDisk()
    }

    func renameFile(id: String, name: String) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].name = name
        saveToDisk()
    }

    func updateTranscript(id: String, transcript: String) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].transcriptJSON = transcript
        saveToDisk()
    }

    func updateSummary(id: String, summary: String) {
        guard let idx = cache.firstIndex(where: { $0.id == id }) else { return }
        cache[idx].summaryText = summary
        saveToDisk()
    }

    func replaceAllFiles(_ files: [RecordingFile]) {
        cache = files
        saveToDisk()
    }

    func markAsSynced(sessionId: Int, localPath: String, duration: TimeInterval = 0) {
        guard let idx = cache.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        cache[idx].syncedAt = Date()
        cache[idx].localPath = (localPath as NSString).lastPathComponent
        if duration > 0 { cache[idx].duration = duration }
        saveToDisk()
    }

    // MARK: - Path Utilities

    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Resolve stored relative filename to absolute path within current sandbox
    /// Resolve WAV path for playback
    func resolveAbsolutePath(for file: RecordingFile) -> String? {
        guard let name = file.localPath, !name.isEmpty else { return nil }
        let path = docsDir.appendingPathComponent(name).path
        if FileManager.default.fileExists(atPath: path) { return path }
        if name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) { return name }
        return nil
    }


    func audioFilePath(sessionId: Int) -> String {
        docsDir.appendingPathComponent("\(sessionId).ogg").path
    }

    func audioDir() -> String {
        docsDir.path
    }

    /// Audio export directory
    var exportDir: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("exports")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }

    func clearAll() {
        cache.removeAll()
        pairedDeviceSNs = []
        activeDeviceSN = nil
        pairedDeviceNames = [:]
        userId = nil
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() -> [RecordingFile] {
        guard let data = try? Data(contentsOf: storeURL),
              let files = try? JSONDecoder().decode([RecordingFile].self, from: data) else { return [] }
        return files
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
