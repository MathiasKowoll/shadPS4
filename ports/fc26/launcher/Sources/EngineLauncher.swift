import Darwin
import Foundation

struct BuildInfo: Decodable {
    let launcherVersion: String
    let launcherRevision: String?
    let engineRevision: String
    let kosmicKrispRevision: String

    private enum CodingKeys: String, CodingKey {
        case launcherVersion = "launcher_version"
        case launcherRevision = "launcher_revision"
        case engineRevision = "engine_revision"
        case kosmicKrispRevision = "kosmickrisp_revision"
    }

    static func load() -> BuildInfo? {
        guard let url = Bundle.main.url(forResource: "build-info", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(BuildInfo.self, from: data)
    }
}

struct EngineBundle {
    static let requiredFiles = [
        "shadps4", "libvulkan.dylib", "libvulkan_kosmickrisp.dylib", "kosmickrisp_mesa_icd.json",
    ]

    let directory: URL

    static var embedded: EngineBundle {
        EngineBundle(
            directory: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/MacOS", isDirectory: true))
    }

    var executable: URL { directory.appendingPathComponent("shadps4") }
    var icd: URL { directory.appendingPathComponent("kosmickrisp_mesa_icd.json") }

    func missingFiles() -> [String] {
        Self.requiredFiles.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}

enum HostCheck {
    static let rosettaCommand = "softwareupdate --install-rosetta --agree-to-license"

    static func rosettaInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
            || run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]).status == 0
    }

    static func runningEngines() -> [Int32] {
        run("/usr/bin/pgrep", ["-ix", "shadps4(\\..+)?"]).output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (
        status: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct EngineRun {
    let engine: EngineBundle
    let game: GameDump
    let data: PlayerData
    let settings: EngineSettings
    let launcherSettings: LauncherSettings
    let buildInfo: BuildInfo?

    var arguments: [String] {
        var arguments: [String] = []
        if settings.showFPS {
            arguments.append("--show-fps")
        }
        arguments += ["--fullscreen", settings.fullscreen ? "true" : "false", game.baseFolder.path]
        return arguments
    }

    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["VK_DRIVER_FILES"] = engine.icd.path
        environment["DYLD_LIBRARY_PATH"] =
            environment["DYLD_LIBRARY_PATH"].map { "\(engine.directory.path):\($0)" }
            ?? engine.directory.path
        environment["SHADPS4_FRAME_METRICS_PATH"] = data.metricsFile.path
        environment["SHADPS4_PRELOAD_PROGRESS_PATH"] = data.preloadFile.path
        if launcherSettings.menusAt60 {
            environment["SHADPS4_VIDEOOUT_FLIP_RATE_OVERRIDE"] = "0"
        } else {
            environment.removeValue(forKey: "SHADPS4_VIDEOOUT_FLIP_RATE_OVERRIDE")
        }
        for key in [
            "SHADPS4_DEFER_UPLOADS", "SHADPS4_ASYNC_IMAGE_READBACK", "SHADPS4_FAULT_EXPAND",
        ]
        where environment[key] == nil {
            environment[key] = "1"
        }
        environment.removeValue(forKey: "SHADPS4_TRACE_IMPORTS")
        if launcherSettings.metalHUD {
            environment["MTL_HUD_ENABLED"] = "1"
        } else {
            environment.removeValue(forKey: "MTL_HUD_ENABLED")
        }
        return environment
    }

    func start(onExit: @escaping @Sendable (Int32, Process.TerminationReason) -> Void) throws
        -> Process
    {
        let manager = FileManager.default
        try manager.createDirectory(at: data.logs, withIntermediateDirectories: true)
        try manager.createDirectory(at: data.metrics, withIntermediateDirectories: true)
        Self.rotate(data.consoleLog, to: data.previousConsoleLog)
        Self.rotate(data.metricsFile, to: data.metrics.appendingPathComponent("previous-run.csv"))
        Self.rotate(
            data.preloadFile, to: data.metrics.appendingPathComponent("previous-run-preload.csv"))
        guard manager.createFile(atPath: data.consoleLog.path, contents: Data(header.utf8)) else {
            throw CocoaError(
                .fileWriteUnknown, userInfo: [NSFilePathErrorKey: data.consoleLog.path])
        }
        let log = try FileHandle(forWritingTo: data.consoleLog)
        try log.seekToEnd()

        let process = Process()
        process.executableURL = engine.executable
        process.arguments = arguments
        process.currentDirectoryURL = data.root
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { finished in
            try? log.close()
            onExit(finished.terminationStatus, finished.terminationReason)
        }
        do {
            try process.run()
        } catch {
            try? log.close()
            throw error
        }
        return process
    }

    private var header: String {
        let enabled = { (value: Bool) in value ? "on" : "off" }
        var lines = [
            "FC26 Port launcher \(buildInfo?.launcherVersion ?? "development build") "
                + "(\(buildInfo?.launcherRevision ?? "unknown revision"))",
            "Engine: \(buildInfo?.engineRevision ?? "unknown"), KosmicKrisp: "
                + "\(buildInfo?.kosmicKrispRevision ?? "unknown")",
            "Game: \(game.titleID) \(game.appVersion) in \(Self.display(game.baseFolder))",
        ]
        if let update = game.updateFolder {
            lines.append("Update folder: \(Self.display(update))")
        }
        lines += [
            "Player data: \(Self.display(data.root))",
            "Settings: fullscreen \(enabled(settings.fullscreen)), upscaling "
                + "\(settings.upscaler.title), RCAS \(enabled(settings.rcas)), PS4 Pro mode "
                + "\(enabled(settings.ps4Pro)), 60 FPS menus \(enabled(launcherSettings.menusAt60)), "
                + "frame rate \(enabled(settings.showFPS)), Metal HUD "
                + "\(enabled(launcherSettings.metalHUD)), detailed log "
                + "\(enabled(launcherSettings.diagnosticLog))",
            "Missing system modules: \(data.missingModules().joined(separator: ", ").nonEmpty ?? "none")",
            "Started: \(ISO8601DateFormatter().string(from: Date()))",
            "",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func rotate(_ current: URL, to previous: URL) {
        guard FileManager.default.fileExists(atPath: current.path) else { return }
        rename(current.path, previous.path)
    }
}

struct ShaderPreload: Equatable {
    let elapsed: Double
    let pipelines: Int
    let total: Int
    let finished: Bool

    var summary: String {
        total > 0
            ? "Preparing shaders: \(pipelines.formatted()) of \(total.formatted()) pipelines."
            : "Preparing shaders…"
    }

    static func read(_ file: URL) -> ShaderPreload? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
            (try? handle.seek(toOffset: size > 256 ? size - 256 : 0)) != nil,
            let data = try? handle.readToEnd()
        else {
            return nil
        }
        let lines = String(decoding: data, as: UTF8.self).split(
            separator: "\n", omittingEmptySubsequences: false)
        for line in lines.dropLast().reversed() {
            let fields = line.split(separator: ",")
            if fields.count == 4, let elapsed = Double(fields[0]), let pipelines = Int(fields[1]),
                let total = Int(fields[2]), let finished = Int(fields[3])
            {
                return ShaderPreload(
                    elapsed: elapsed, pipelines: pipelines, total: total, finished: finished == 1)
            }
        }
        return nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
