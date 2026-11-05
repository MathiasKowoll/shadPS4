import Foundation

struct ShaderCacheSummary: Equatable {
    let shaders: Int
    let pipelines: Int
    let bytes: Int64
}

enum ShaderCacheState: Equatable {
    case empty
    case valid(ShaderCacheSummary)
    case damaged
    case restored(ShaderCacheSummary)
    case discarded
}

private struct ShaderCacheBackup: Codable {
    let sourceSize: Int64
    let sourceModified: Double
    let sha256: String
    let shaders: Int
    let pipelines: Int
    let savedAt: String
    let engine: String
}

enum ShaderCacheGuard {
    static func inspect(_ data: PlayerData) -> ShaderCacheState {
        guard FileManager.default.fileExists(atPath: data.shaderCache.path) else { return .empty }
        guard let summary = summary(of: data.shaderCache) else { return .damaged }
        return .valid(summary)
    }

    static func protect(_ data: PlayerData, engineRevision: String) -> ShaderCacheState {
        let active = data.shaderCache
        guard FileManager.default.fileExists(atPath: active.path) else { return .empty }
        if let summary = summary(of: active) {
            refreshBackup(data, summary: summary, engineRevision: engineRevision)
            return .valid(summary)
        }
        preservePartial(data)
        for candidate in restoreCandidates(data) {
            guard let summary = summary(of: candidate) else { continue }
            if (try? atomicCopy(candidate, to: active)) != nil {
                return .restored(summary)
            }
        }
        return .discarded
    }

    static func summary(of archive: URL) -> ShaderCacheSummary? {
        guard run("/usr/bin/unzip", ["-tqq", archive.path]).status == 0 else { return nil }
        let listing = run("/usr/bin/zipinfo", ["-1", archive.path])
        guard listing.status == 0 else { return nil }
        var shaders = 0
        var pipelines = 0
        for name in listing.output.split(separator: "\n") {
            if name.hasSuffix(".spv") {
                shaders += 1
            } else if name.hasSuffix(".key") {
                pipelines += 1
            }
        }
        return ShaderCacheSummary(
            shaders: shaders, pipelines: pipelines,
            bytes: GameDumpInspector.fileSize(archive) ?? 0)
    }

    private static func backupArchive(_ data: PlayerData) -> URL {
        data.shaderBackups.appendingPathComponent("backup.zip")
    }

    private static func backupManifest(_ data: PlayerData) -> URL {
        data.shaderBackups.appendingPathComponent("backup.json")
    }

    private static func refreshBackup(
        _ data: PlayerData, summary: ShaderCacheSummary, engineRevision: String
    ) {
        let manager = FileManager.default
        let attributes = try? manager.attributesOfItem(atPath: data.shaderCache.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let manifestData = try? Data(contentsOf: backupManifest(data)),
            let manifest = try? JSONDecoder().decode(ShaderCacheBackup.self, from: manifestData),
            manifest.sourceSize == size, manifest.sourceModified == modified,
            manager.fileExists(atPath: backupArchive(data).path)
        {
            return
        }
        do {
            try manager.createDirectory(at: data.shaderBackups, withIntermediateDirectories: true)
            try atomicCopy(data.shaderCache, to: backupArchive(data))
            let manifest = ShaderCacheBackup(
                sourceSize: size, sourceModified: modified,
                sha256: try FileDigest.sha256(backupArchive(data)), shaders: summary.shaders,
                pipelines: summary.pipelines, savedAt: ISO8601DateFormatter().string(from: Date()),
                engine: engineRevision)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: backupManifest(data), options: .atomic)
        } catch {
            return
        }
    }

    private static func restoreCandidates(_ data: PlayerData) -> [URL] {
        var candidates = [backupArchive(data)]
        let latest = data.shaderBackups.appendingPathComponent("latest.json")
        if let manifestData = try? Data(contentsOf: latest),
            let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            let cache = manifest["cache"] as? [String: Any],
            let archive = cache["archive"] as? String
        {
            candidates.append(
                data.shaderBackups.appendingPathComponent("snapshots", isDirectory: true)
                    .appendingPathComponent((archive as NSString).lastPathComponent))
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func preservePartial(_ data: PlayerData) {
        guard let digest = try? FileDigest.sha256(data.shaderCache) else { return }
        let partial = data.shaderBackups.appendingPathComponent(
            "partial/\(digest).partial.zip")
        guard !FileManager.default.fileExists(atPath: partial.path) else { return }
        try? FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? atomicCopy(data.shaderCache, to: partial)
    }

    static func atomicCopy(_ source: URL, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: staging)
        guard rename(staging.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String)
    {
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
