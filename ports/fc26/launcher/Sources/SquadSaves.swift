import Foundation

struct SquadSave: Identifiable, Equatable {
    let folder: URL
    let directoryName: String
    let displayName: String

    var id: String { directoryName }
}

struct SquadInstall {
    let installed: [SquadSave]
    let replacedBackups: [URL]
}

enum SquadSaveError: LocalizedError {
    case noneFound
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .noneFound:
            "No EA SPORTS FC 26 squad save was found there. Choose a squads save folder (with DATA, "
                + "INDEX and sce_sys/param.sfo) or a .zip that contains one."
        case .extractionFailed:
            "The .zip file could not be extracted."
        }
    }
}

enum SquadSaves {
    private static let installedFiles = [
        "DATA", "INDEX", "NAME", "sce_sys/param.sfo", "sce_sys/icon0.png",
    ]

    static func installed(in data: PlayerData) -> [SquadSave] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: data.saves.path)) ?? []
        return names.sorted().compactMap {
            inspect(data.saves.appendingPathComponent($0, isDirectory: true), titleID: data.titleID)
        }
    }

    static func inspect(_ folder: URL, titleID: String) -> SquadSave? {
        guard let sfo = try? ParamSFO.read(folder.appendingPathComponent("sce_sys/param.sfo")),
            sfo["CATEGORY"] == "sd", sfo["TITLE_ID"] == titleID,
            let directory = sfo["SAVEDATA_DIRECTORY"], !directory.isEmpty,
            !directory.contains("/"), directory != ".", directory != "..",
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("INDEX").path),
            containsSquads(folder.appendingPathComponent("DATA"))
        else {
            return nil
        }
        let subtitle = sfo["SUBTITLE"] ?? ""
        return SquadSave(
            folder: folder, directoryName: directory,
            displayName: subtitle.isEmpty ? directory : subtitle)
    }

    static func install(from source: URL, into data: PlayerData) throws -> SquadInstall {
        let manager = FileManager.default
        var searchRoot = source
        var extracted: URL?
        defer {
            if let extracted {
                try? manager.removeItem(at: extracted)
            }
        }
        if source.pathExtension.lowercased() == "zip" {
            let folder = manager.temporaryDirectory
                .appendingPathComponent("FC26Port-squads-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            extracted = folder
            guard extract(source, to: folder) else { throw SquadSaveError.extractionFailed }
            searchRoot = folder
        }
        let saves = candidates(in: searchRoot, titleID: data.titleID)
        guard !saves.isEmpty else { throw SquadSaveError.noneFound }

        try manager.createDirectory(at: data.saves, withIntermediateDirectories: true)
        var installed: [SquadSave] = []
        var backups: [URL] = []
        for save in saves {
            let destination = data.saves.appendingPathComponent(
                save.directoryName, isDirectory: true)
            let staging = data.root.appendingPathComponent(
                ".squads-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(
                at: staging.appendingPathComponent("sce_sys", isDirectory: true),
                withIntermediateDirectories: true)
            do {
                for file in installedFiles
                where manager.fileExists(atPath: save.folder.appendingPathComponent(file).path) {
                    try manager.copyItem(
                        at: save.folder.appendingPathComponent(file),
                        to: staging.appendingPathComponent(file))
                }
                let sfo = staging.appendingPathComponent("sce_sys/param.sfo")
                try Data(ParamSFO.zeroing("ACCOUNT_ID", in: [UInt8](Data(contentsOf: sfo))))
                    .write(to: sfo, options: .atomic)
                if manager.fileExists(atPath: destination.path) {
                    let backup = unusedBackup(for: save.directoryName, in: data.saveBackups)
                    try manager.createDirectory(
                        at: data.saveBackups, withIntermediateDirectories: true)
                    try manager.moveItem(at: destination, to: backup)
                    backups.append(backup)
                }
                try manager.moveItem(at: staging, to: destination)
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
            installed.append(
                SquadSave(
                    folder: destination, directoryName: save.directoryName,
                    displayName: save.displayName))
        }
        return SquadInstall(installed: installed, replacedBackups: backups)
    }

    private static func candidates(in root: URL, titleID: String) -> [SquadSave] {
        if let save = inspect(root, titleID: titleID) {
            return [save]
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            return []
        }
        var saves: [SquadSave] = []
        while let url = enumerator.nextObject() as? URL {
            guard enumerator.level <= 3, GameDumpInspector.isDirectory(url) else {
                if enumerator.level > 3 {
                    enumerator.skipDescendants()
                }
                continue
            }
            if let save = inspect(url, titleID: titleID),
                !saves.contains(where: { $0.directoryName == save.directoryName })
            {
                saves.append(save)
                enumerator.skipDescendants()
            }
        }
        return saves
    }

    private static func containsSquads(_ data: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: data),
            let head = try? handle.read(upToCount: 16 << 10)
        else {
            return false
        }
        try? handle.close()
        return head.range(of: Data("SaveType_Squads".utf8)) != nil
    }

    private static func extract(_ archive: URL, to folder: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func unusedBackup(for name: String, in folder: URL) -> URL {
        let base = "\(name)-\(timestamp())"
        var candidate = folder.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime]
        )
        .replacingOccurrences(of: ":", with: "")
    }
}
