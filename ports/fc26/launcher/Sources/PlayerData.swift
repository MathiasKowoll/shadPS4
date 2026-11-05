import Darwin
import Foundation

struct EngineSettings: Equatable {
    var fullscreen = false
    var fsr = false
    var rcas = false
    var showFPS = true
}

struct LauncherSettings: Codable, Equatable {
    var metalHUD = false
    var diagnosticLog = false
    var shaderNoticeShown = false
    var modulesNoticeShown = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metalHUD = try container.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        diagnosticLog = try container.decodeIfPresent(Bool.self, forKey: .diagnosticLog) ?? false
        shaderNoticeShown =
            try container.decodeIfPresent(Bool.self, forKey: .shaderNoticeShown) ?? false
        modulesNoticeShown =
            try container.decodeIfPresent(Bool.self, forKey: .modulesNoticeShown) ?? false
    }
}

enum PlayerDataError: LocalizedError {
    case unavailable(URL)
    case notWritable(URL)
    case unreadableConfig(URL, String)
    case notAModule(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let url):
            "The player data folder is not available: \(url.path). Connect the drive that holds it, "
                + "or choose another folder."
        case .notWritable(let url):
            "The player data folder cannot be written: \(url.path). Choose a folder you can write "
                + "to. \(GameDumpInspector.accessHint)"
        case .unreadableConfig(let url, let reason):
            "The engine settings file cannot be read (\(reason)): \(url.path). Use Reset Engine "
                + "Settings to replace it with the port defaults; the old file is kept next to it."
        case .notAModule(let name):
            "\(name) is not a PS4 system module. Choose the .sprx files dumped from your PS4."
        }
    }
}

struct PlayerData {
    static let recommendedModules = ["libSceJson.sprx", "libSceJson2.sprx", "libSceAudiodec.sprx"]
    static let diagnosticLogFilter = "*:warning Render.Vulkan:info"

    let root: URL
    let titleID: String

    var user: URL { root.appendingPathComponent("user", isDirectory: true) }
    var systemModules: URL { user.appendingPathComponent("sys_modules", isDirectory: true) }
    var engineConfig: URL { user.appendingPathComponent("config.json") }
    var engineLogs: URL { user.appendingPathComponent("log", isDirectory: true) }
    var saves: URL {
        user.appendingPathComponent("home/1000/savedata/\(titleID)", isDirectory: true)
    }
    var shaderCache: URL { user.appendingPathComponent("cache/\(titleID).zip") }
    var shaderBackups: URL { root.appendingPathComponent("shader-cache", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var consoleLog: URL { logs.appendingPathComponent("last-run.console.log") }
    var previousConsoleLog: URL { logs.appendingPathComponent("previous-run.console.log") }
    var metrics: URL { root.appendingPathComponent("metrics", isDirectory: true) }
    var metricsFile: URL { metrics.appendingPathComponent("last-run.csv") }
    var launcherSettingsFile: URL { root.appendingPathComponent("launcher.json") }
    var lockFile: URL { root.appendingPathComponent(".launcher.lock") }

    static func defaultPlayersFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FC26 Port/Players", isDirectory: true)
    }

    var isOnMissingVolume: Bool {
        let components = root.standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return false }
        return !GameDumpInspector.isDirectory(URL(fileURLWithPath: "/Volumes/\(components[2])"))
    }

    func prepare(seedConfig: URL) throws {
        let manager = FileManager.default
        guard !isOnMissingVolume else {
            throw PlayerDataError.unavailable(root)
        }
        do {
            for folder in [systemModules, logs, metrics, shaderBackups] {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            if !manager.fileExists(atPath: engineConfig.path) {
                try manager.copyItem(at: seedConfig, to: engineConfig)
            }
        } catch {
            throw PlayerDataError.notWritable(root)
        }
        guard manager.isWritableFile(atPath: root.path) else {
            throw PlayerDataError.notWritable(root)
        }
    }

    func loadLauncherSettings() -> LauncherSettings {
        guard let data = try? Data(contentsOf: launcherSettingsFile),
            let settings = try? JSONDecoder().decode(LauncherSettings.self, from: data)
        else {
            return LauncherSettings()
        }
        return settings
    }

    func saveLauncherSettings(_ settings: LauncherSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: launcherSettingsFile, options: .atomic)
    }

    func loadEngineConfig() throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: engineConfig)
        } catch {
            throw PlayerDataError.unreadableConfig(engineConfig, error.localizedDescription)
        }
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlayerDataError.unreadableConfig(engineConfig, "it is not valid JSON")
        }
        return config
    }

    func readEngineSettings() throws -> EngineSettings {
        let config = try loadEngineConfig()
        let gpu = config["GPU"] as? [String: Any] ?? [:]
        let general = config["General"] as? [String: Any] ?? [:]
        var settings = EngineSettings()
        settings.fullscreen = gpu["full_screen"] as? Bool ?? settings.fullscreen
        settings.fsr = gpu["fsr_enabled"] as? Bool ?? settings.fsr
        settings.rcas = gpu["rcas_enabled"] as? Bool ?? settings.rcas
        settings.showFPS = general["show_fps_counter"] as? Bool ?? settings.showFPS
        return settings
    }

    func saveEngineSettings(_ settings: EngineSettings) throws {
        var config = try loadEngineConfig()
        merge(
            &config, "GPU",
            [
                "full_screen": settings.fullscreen,
                "fsr_enabled": settings.fsr,
                "rcas_enabled": settings.rcas,
            ])
        merge(&config, "General", ["show_fps_counter": settings.showFPS])
        try writeEngineConfig(config)
    }

    func applyRunProfile(_ settings: EngineSettings, diagnosticLog: Bool) throws {
        try saveEngineSettings(settings)
        var config = try loadEngineConfig()
        merge(&config, "GPU", ["vblank_frequency": 60])
        if diagnosticLog {
            merge(
                &config, "Log", ["enable": true, "filter": Self.diagnosticLogFilter, "sync": false])
        } else {
            merge(&config, "Log", ["enable": false, "sync": false])
        }
        try writeEngineConfig(config)
    }

    func resetEngineConfig(seedConfig: URL) throws -> URL? {
        let manager = FileManager.default
        var kept: URL?
        if manager.fileExists(atPath: engineConfig.path) {
            let stamp = ISO8601DateFormatter.string(
                from: Date(), timeZone: .current,
                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime]
            )
            .replacingOccurrences(of: ":", with: "")
            let destination = engineConfig.deletingLastPathComponent()
                .appendingPathComponent("config.json.replaced-\(stamp).json")
            try manager.moveItem(at: engineConfig, to: destination)
            kept = destination
        }
        try manager.copyItem(at: seedConfig, to: engineConfig)
        return kept
    }

    func missingModules() -> [String] {
        Self.recommendedModules.filter {
            !FileManager.default.fileExists(atPath: systemModules.appendingPathComponent($0).path)
        }
    }

    func installModules(_ sources: [URL]) throws -> [String] {
        let manager = FileManager.default
        try manager.createDirectory(at: systemModules, withIntermediateDirectories: true)
        for source in sources where !Self.isModule(source) {
            throw PlayerDataError.notAModule(source.lastPathComponent)
        }
        var installed: [String] = []
        for source in sources {
            let destination = systemModules.appendingPathComponent(source.lastPathComponent)
            let staging = systemModules.appendingPathComponent(
                ".\(source.lastPathComponent).partial")
            try? manager.removeItem(at: staging)
            try manager.copyItem(at: source, to: staging)
            guard rename(staging.path, destination.path) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
            }
            installed.append(source.lastPathComponent)
        }
        return installed
    }

    static func isModule(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "sprx",
            let handle = try? FileHandle(forReadingFrom: url),
            let magic = try? handle.read(upToCount: 4)
        else {
            return false
        }
        try? handle.close()
        let bytes = [UInt8](magic)
        let elf: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]
        let signedElf: [UInt8] = [0x4F, 0x15, 0x3D, 0x1D]
        return bytes == elf || bytes == signedElf
    }

    private func merge(_ config: inout [String: Any], _ section: String, _ values: [String: Any]) {
        var current = config[section] as? [String: Any] ?? [:]
        current.merge(values) { _, new in new }
        config[section] = current
    }

    private func writeEngineConfig(_ config: [String: Any]) throws {
        var data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: engineConfig, options: .atomic)
    }
}

enum PlayerLock {
    case acquired(PlayerDataLock?)
    case inUse
}

final class PlayerDataLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(_ data: PlayerData) -> PlayerLock {
        let descriptor = open(data.lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .acquired(nil) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            return failure == EWOULDBLOCK ? .inUse : .acquired(nil)
        }
        return .acquired(PlayerDataLock(descriptor: descriptor))
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
