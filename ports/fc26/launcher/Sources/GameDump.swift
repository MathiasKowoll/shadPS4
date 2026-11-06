import CryptoKit
import Foundation

struct PortProfile: Decodable {
    struct GameFile: Decodable {
        let size: Int64
        let sha256: String
    }

    let titleID: String
    let appVersion: String
    let files: [String: GameFile]

    private enum CodingKeys: String, CodingKey {
        case titleID = "title_id"
        case appVersion = "app_version"
        case files
    }

    static func load(_ url: URL) throws -> PortProfile {
        try JSONDecoder().decode(PortProfile.self, from: Data(contentsOf: url))
    }

    var fileNames: [String] { files.keys.sorted() }
    var totalSize: Int64 { files.values.reduce(0) { $0 + $1.size } }
}

enum ParamSFOError: LocalizedError {
    case tooSmall
    case invalidMagic
    case truncated

    var errorDescription: String? {
        switch self {
        case .tooSmall: "the file is too small"
        case .invalidMagic: "the file is not a PS4 param.sfo"
        case .truncated: "the file is truncated"
        }
    }
}

enum ParamSFO {
    struct Entry {
        let key: String
        let format: Int
        let valueStart: Int
        let length: Int
    }

    static func read(_ url: URL) throws -> [String: String] {
        try parse([UInt8](Data(contentsOf: url)))
    }

    static func parse(_ bytes: [UInt8]) throws -> [String: String] {
        var values: [String: String] = [:]
        for entry in try entries(bytes) {
            if entry.format == 0x0404, entry.length >= 4 {
                values[entry.key] = String(try u32(bytes, entry.valueStart))
            } else {
                var valueEnd = entry.valueStart + entry.length
                while valueEnd > entry.valueStart, bytes[valueEnd - 1] == 0 {
                    valueEnd -= 1
                }
                values[entry.key] = String(
                    decoding: bytes[entry.valueStart..<valueEnd], as: UTF8.self)
            }
        }
        return values
    }

    static func zeroing(_ key: String, in bytes: [UInt8]) throws -> [UInt8] {
        var result = bytes
        for entry in try entries(bytes) where entry.key == key {
            result.replaceSubrange(
                entry.valueStart..<entry.valueStart + entry.length,
                with: repeatElement(0, count: entry.length))
        }
        return result
    }

    static func entries(_ bytes: [UInt8]) throws -> [Entry] {
        guard bytes.count >= 20 else { throw ParamSFOError.tooSmall }
        guard bytes[0..<4].elementsEqual([0x00, 0x50, 0x53, 0x46]) else {
            throw ParamSFOError.invalidMagic
        }
        let keyTable = try u32(bytes, 8)
        let dataTable = try u32(bytes, 12)
        let count = try u32(bytes, 16)
        var entries: [Entry] = []
        for index in 0..<count {
            let entry = 20 + index * 16
            let keyStart = keyTable + (try u16(bytes, entry))
            let format = try u16(bytes, entry + 2)
            let length = try u32(bytes, entry + 4)
            let valueStart = dataTable + (try u32(bytes, entry + 12))
            guard keyStart < bytes.count, let keyEnd = bytes[keyStart...].firstIndex(of: 0) else {
                throw ParamSFOError.truncated
            }
            guard valueStart + length <= bytes.count else { throw ParamSFOError.truncated }
            entries.append(
                Entry(
                    key: String(decoding: bytes[keyStart..<keyEnd], as: UTF8.self),
                    format: format, valueStart: valueStart, length: length))
        }
        return entries
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { throw ParamSFOError.truncated }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ParamSFOError.truncated }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
            | Int(bytes[offset + 3]) << 24
    }
}

struct GameDump {
    let chosenFolder: URL
    let baseFolder: URL
    let updateFolder: URL?
    let title: String
    let titleID: String
    let appVersion: String
    let problems: [String]
    let notes: [String]

    var isPlayable: Bool { problems.isEmpty }

    func resolve(_ relativePath: String) -> URL {
        GameDump.resolve(relativePath, base: baseFolder, update: updateFolder)
    }

    static func resolve(_ relativePath: String, base: URL, update: URL?) -> URL {
        if let update {
            let candidate = update.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return base.appendingPathComponent(relativePath)
    }
}

enum GameDumpInspector {
    static let accessHint =
        "If the folder is there, choose it again with Choose…, or allow EA SPORTS FC 26 Port in "
        + "System Settings > Privacy & Security > Files & Folders."

    private static let updateSuffixes = ["-UPDATE", "-patch"]
    private static let overlaySuffixes = ["-UPDATE", "-patch", "-mods"]
    private static let paramSFO = "sce_sys/param.sfo"

    static func inspect(_ chosen: URL, profile: PortProfile) -> GameDump {
        var notes: [String] = []
        var problems: [String] = []
        let chosen = chosen.standardizedFileURL

        guard isDirectory(chosen) else {
            problems.append(
                "The game folder cannot be found: \(chosen.path). Connect the drive that holds it, "
                    + "or choose the folder again. \(accessHint)")
            return GameDump(
                chosenFolder: chosen, baseFolder: chosen, updateFolder: nil, title: "", titleID: "",
                appVersion: "", problems: problems, notes: notes)
        }

        let base = baseFolder(for: chosen, titleID: profile.titleID, notes: &notes)
        let update = updateSuffixes.lazy
            .map { sibling(of: base, suffix: $0) }
            .first(where: isDirectory)
        if let update {
            notes.append("Update folder found next to the game: \(update.lastPathComponent).")
        }
        let mods = sibling(of: base, suffix: "-mods")
        if isDirectory(mods) {
            notes.append(
                "A mods folder (\(mods.lastPathComponent)) is next to the game. The engine loads its "
                    + "files over the game; the launcher does not check them, and the port is only "
                    + "validated without mods.")
        }

        let sfoURL = GameDump.resolve(paramSFO, base: base, update: update)
        var sfo: [String: String] = [:]
        if !FileManager.default.fileExists(atPath: sfoURL.path) {
            problems.append(
                "This folder is not a PS4 game dump: sce_sys/param.sfo was not found. Choose the "
                    + "folder that contains eboot.bin and the sce_sys folder.")
        } else {
            do {
                sfo = try ParamSFO.read(sfoURL)
            } catch  where isPermissionError(error) {
                problems.append(
                    "macOS does not let the launcher read the game folder. \(accessHint)")
            } catch {
                problems.append(
                    "sce_sys/param.sfo cannot be read (\(error.localizedDescription)). The dump may "
                        + "be damaged; dump the game again.")
            }
        }

        let titleID = sfo["TITLE_ID"] ?? ""
        let appVersion = sfo["APP_VER"] ?? ""
        let title = sfo["TITLE"] ?? ""
        if problems.isEmpty {
            if titleID != profile.titleID {
                let found =
                    title.isEmpty
                    ? (titleID.isEmpty ? "an unknown game" : titleID)
                    : "\(title) (\(titleID.isEmpty ? "no title ID" : titleID))"
                problems.append(
                    "This dump is \(found). The port runs only EA SPORTS FC 26 with title ID "
                        + "\(profile.titleID).")
            } else if appVersion != profile.appVersion {
                problems.append(
                    versionProblem(
                        found: appVersion, expected: profile.appVersion, titleID: titleID))
            } else {
                problems += fileProblems(base: base, update: update, profile: profile)
            }
        }

        return GameDump(
            chosenFolder: chosen, baseFolder: base, updateFolder: update, title: title,
            titleID: titleID, appVersion: appVersion, problems: problems, notes: notes)
    }

    private static func versionProblem(found: String, expected: String, titleID: String) -> String {
        guard !found.isEmpty else {
            return
                "sce_sys/param.sfo has no app version. The dump may be damaged; dump the game again."
        }
        if found.compare(expected, options: .numeric) == .orderedAscending {
            return
                "This dump is version \(found). The port needs version \(expected): install update "
                + "\(expected) on your PS4 and dump the game again with the update included, or put "
                + "the update dump next to the game folder as \(titleID)-UPDATE."
        }
        return
            "This dump is version \(found), which is newer than \(expected). The port has only been "
            + "validated with version \(expected) and does not start other versions."
    }

    private static func fileProblems(base: URL, update: URL?, profile: PortProfile) -> [String] {
        var problems: [String] = []
        var damaged: [String] = []
        for name in profile.fileNames {
            guard let expected = profile.files[name] else { continue }
            let url = GameDump.resolve(name, base: base, update: update)
            guard let size = fileSize(url) else {
                damaged.append(name)
                problems.append("\(name) is missing. The dump is incomplete; dump the game again.")
                continue
            }
            if size != expected.size {
                damaged.append(name)
                problems.append(
                    "\(name) has the wrong size (\(size) bytes, expected \(expected.size)). The dump "
                        + "is incomplete or comes from another version.")
            }
        }
        guard damaged.count > 3 else { return problems }
        return [
            "The dump is incomplete: \(damaged.count) of \(profile.files.count) required files are "
                + "missing or have the wrong size (\(damaged.joined(separator: ", "))). Dump the game "
                + "again."
        ]
    }

    private static func baseFolder(for chosen: URL, titleID: String, notes: inout [String]) -> URL {
        let name = chosen.lastPathComponent
        for suffix in overlaySuffixes where name.count > suffix.count && name.hasSuffix(suffix) {
            let base = chosen.deletingLastPathComponent()
                .appendingPathComponent(String(name.dropLast(suffix.count)), isDirectory: true)
            if isDirectory(base) {
                notes.append(
                    "You chose the \(suffix.dropFirst()) folder; the launcher uses the game folder "
                        + "\(base.lastPathComponent) next to it.")
                return base
            }
        }
        if !containsGame(chosen), let child = childGameFolder(in: chosen, titleID: titleID) {
            notes.append(
                "Using the game folder \(child.lastPathComponent) inside the folder you chose.")
            return child
        }
        return chosen
    }

    private static func containsGame(_ folder: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: folder.appendingPathComponent(paramSFO).path)
            || manager.fileExists(atPath: folder.appendingPathComponent("eboot.bin").path)
    }

    private static func childGameFolder(in folder: URL, titleID: String) -> URL? {
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]))
            ?? []
        let games = children.filter { child in
            isDirectory(child) && containsGame(child)
                && !overlaySuffixes.contains { child.lastPathComponent.hasSuffix($0) }
        }
        if let exact = games.first(where: { $0.lastPathComponent == titleID }) {
            return exact
        }
        let prefixed = games.filter { $0.lastPathComponent.hasPrefix(titleID) }
        if prefixed.count == 1 {
            return prefixed[0]
        }
        return games.count == 1 ? games[0] : nil
    }

    private static func sibling(of folder: URL, suffix: String) -> URL {
        folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent + suffix, isDirectory: true)
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
            [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
        {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return error.domain == NSPOSIXErrorDomain
                && [Int(EPERM), Int(EACCES)].contains(error.code)
        }
        return isPermissionError(underlying)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.resolvingSymlinksInPath().path),
            (attributes[.type] as? FileAttributeType) == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.int64Value
    }
}

enum GameHashVerifier {
    static func fingerprint(_ dump: GameDump, profile: PortProfile) -> String {
        profile.fileNames.map { name -> String in
            let url = dump.resolve(name).resolvingSymlinksInPath()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path)|\(size)|\(modified)"
        }.joined(separator: "\n")
    }

    static func mismatchedFiles(
        _ dump: GameDump, profile: PortProfile, progress: (Double) -> Void
    ) throws -> [String] {
        let total = max(profile.totalSize, 1)
        var processed: Int64 = 0
        var mismatched: [String] = []
        for name in profile.fileNames {
            guard let expected = profile.files[name] else { continue }
            let digest = try FileDigest.sha256(dump.resolve(name)) { bytes in
                processed += bytes
                progress(Double(processed) / Double(total))
            }
            if digest != expected.sha256 {
                mismatched.append(name)
            }
        }
        return mismatched
    }
}

enum FileDigest {
    static func sha256(_ url: URL, onRead: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            onRead(Int64(chunk.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
