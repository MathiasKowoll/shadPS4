import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum HashState: Equatable {
    case idle
    case running(Double)
    case verified
    case mismatch([String])
    case failed(String)
}

enum RunState: Equatable {
    case idle
    case preparing
    case running(since: Date)
    case finishing
}

struct LastRun: Equatable {
    let endedAt: Date
    let duration: TimeInterval
    let status: Int32
    let crashed: Bool
    let stoppedByUser: Bool
    let cacheNote: String?
}

@MainActor
@Observable
final class LauncherModel {
    static let shared = LauncherModel()

    private enum Keys {
        static let gameFolder = "GameFolder"
        static let playerFolder = "PlayerFolder"
        static let recentPlayers = "RecentPlayerFolders"
        static let verifiedGame = "VerifiedGameFingerprint"
        static let shaderCacheSeed = "ShaderCacheSeed"
    }

    let profile: PortProfile?
    let buildInfo = BuildInfo.load()
    let engine = EngineBundle.embedded
    private let seedConfig = Bundle.main.url(forResource: "managed", withExtension: "json")
    private let launcherDamage: String?

    private(set) var rosettaInstalled = true
    private(set) var gameFolder: URL?
    private(set) var gameDump: GameDump?
    private(set) var hashState = HashState.idle
    private(set) var playerFolder: URL?
    private(set) var player: PlayerData?
    private(set) var playerError: String?
    private(set) var configUnreadable = false
    private(set) var recentPlayers: [URL]
    private(set) var missingModules: [String] = []
    private(set) var squads: [SquadSave] = []
    private(set) var isInstallingSquads = false
    private(set) var isImportingCache = false
    private(set) var cacheState = ShaderCacheState.empty
    private(set) var engineSettings = EngineSettings()
    private(set) var launcherSettings = LauncherSettings()
    private(set) var runState = RunState.idle
    private(set) var lastRun: LastRun?
    private(set) var isCheckingGame = false
    private(set) var isCheckingPlayer = false

    private var gameGeneration = 0
    private var playerGeneration = 0
    private var hashGeneration = 0
    private var hashTask: Task<Void, Never>?
    private var process: Process?
    private var lock: PlayerDataLock?
    private var stopRequested = false
    private var pendingTermination = false

    private init() {
        var damage: [String] = []
        if let url = Bundle.main.url(forResource: "profile", withExtension: "json"),
            let profile = try? PortProfile.load(url)
        {
            self.profile = profile
        } else {
            profile = nil
            damage.append("profile.json")
        }
        if seedConfig == nil {
            damage.append("managed.json")
        }
        damage += engine.missingFiles()
        launcherDamage =
            damage.isEmpty
            ? nil
            : "The launcher is incomplete (\(damage.joined(separator: ", ")) missing from the app). "
                + "Download or build the launcher again."

        let defaults = UserDefaults.standard
        recentPlayers = (defaults.stringArray(forKey: Keys.recentPlayers) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let gamePath = defaults.string(forKey: Keys.gameFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let playerPath =
            defaults.string(forKey: Keys.playerFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? PlayerData.defaultPlayersFolder().appendingPathComponent(
                "Default", isDirectory: true)
        Task { @MainActor in
            if let gamePath {
                LauncherModel.shared.inspectGame(gamePath)
            }
            LauncherModel.shared.selectPlayer(playerPath)
            let rosetta = await Task.detached { HostCheck.rosettaInstalled() }.value
            LauncherModel.shared.rosettaInstalled = rosetta
        }
    }

    var titleID: String { profile?.titleID ?? "CUSA52342" }
    var appVersion: String { profile?.appVersion ?? "01.25" }
    var isRunning: Bool { runState != .idle }

    var blockingProblem: String? {
        if let launcherDamage {
            return launcherDamage
        }
        if !rosettaInstalled {
            return "Rosetta 2 is not installed. The PS4 game code needs it on Apple silicon."
        }
        if isCheckingGame {
            return "Checking the game folder…"
        }
        guard let gameDump else {
            return "Choose the folder of your EA SPORTS FC 26 dump."
        }
        if let problem = gameDump.problems.first {
            return problem
        }
        if isCheckingPlayer {
            return "Opening the player data…"
        }
        guard player != nil, playerError == nil else {
            return playerError ?? "Choose a player data folder."
        }
        return nil
    }

    var canPlay: Bool { runState == .idle && blockingProblem == nil }

    func chooseGameFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the EA SPORTS FC 26 Game Folder"
        panel.message =
            "Choose the folder of your PS4 dump (\(titleID), version \(appVersion)). It contains "
            + "eboot.bin and the sce_sys folder."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = gameFolder {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let player, isInside(player.root, url) || isInside(url, player.root) {
            showError(
                "Game and player data must be separate",
                "The game folder and the player data folder cannot contain each other. Choose the "
                    + "game dump itself, and keep player data in its own folder.")
            return
        }
        UserDefaults.standard.set(url.path, forKey: Keys.gameFolder)
        inspectGame(url)
    }

    func inspectGame(_ url: URL) {
        guard let profile else { return }
        gameGeneration += 1
        hashGeneration += 1
        let generation = gameGeneration
        gameFolder = url.standardizedFileURL
        gameDump = nil
        hashTask?.cancel()
        hashState = .idle
        isCheckingGame = true
        Task.detached(priority: .userInitiated) {
            let dump = GameDumpInspector.inspect(url, profile: profile)
            let fingerprint =
                dump.isPlayable ? GameHashVerifier.fingerprint(dump, profile: profile) : nil
            await MainActor.run {
                LauncherModel.shared.applyGame(
                    dump, fingerprint: fingerprint, generation: generation)
            }
        }
    }

    private func applyGame(_ dump: GameDump, fingerprint: String?, generation: Int) {
        guard generation == gameGeneration else { return }
        isCheckingGame = false
        gameDump = dump
        guard let fingerprint else { return }
        if UserDefaults.standard.string(forKey: Keys.verifiedGame) == fingerprint {
            hashState = .verified
        } else {
            verifyGameFiles()
        }
    }

    func verifyGameFiles() {
        guard let profile, let dump = gameDump, dump.isPlayable, !isRunning else { return }
        hashTask?.cancel()
        hashGeneration += 1
        let generation = hashGeneration
        hashState = .running(0)
        hashTask = Task.detached(priority: .utility) {
            let fingerprint = GameHashVerifier.fingerprint(dump, profile: profile)
            var lastReported = 0.0
            do {
                let mismatched = try GameHashVerifier.mismatchedFiles(dump, profile: profile) {
                    fraction in
                    guard fraction - lastReported >= 0.02 else { return }
                    lastReported = fraction
                    Task { @MainActor in
                        LauncherModel.shared.reportHashProgress(fraction, generation: generation)
                    }
                }
                await MainActor.run {
                    LauncherModel.shared.finishHash(
                        mismatched, fingerprint: fingerprint, generation: generation)
                }
            } catch is CancellationError {
                await MainActor.run {
                    LauncherModel.shared.failHash(nil, generation: generation)
                }
            } catch {
                let reason = error.localizedDescription
                await MainActor.run {
                    LauncherModel.shared.failHash(reason, generation: generation)
                }
            }
        }
    }

    private func reportHashProgress(_ fraction: Double, generation: Int) {
        guard generation == hashGeneration, case .running = hashState else { return }
        hashState = .running(fraction)
    }

    private func finishHash(_ mismatched: [String], fingerprint: String, generation: Int) {
        guard generation == hashGeneration else { return }
        if mismatched.isEmpty {
            UserDefaults.standard.set(fingerprint, forKey: Keys.verifiedGame)
            hashState = .verified
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.verifiedGame)
            hashState = .mismatch(mismatched)
        }
    }

    private func failHash(_ reason: String?, generation: Int) {
        guard generation == hashGeneration else { return }
        hashState = reason.map(HashState.failed) ?? .idle
    }

    func selectPlayer(_ url: URL) {
        guard let profile, let seedConfig else { return }
        let data = PlayerData(root: url.standardizedFileURL, titleID: profile.titleID)
        playerGeneration += 1
        let generation = playerGeneration
        playerFolder = data.root
        player = nil
        playerError = nil
        configUnreadable = false
        missingModules = []
        squads = []
        cacheState = .empty
        isCheckingPlayer = true
        let seedCache = shaderCacheSeed
        Task.detached(priority: .userInitiated) {
            let snapshot = PlayerSnapshot(
                data, seedConfig: seedConfig, seedCache: seedCache, inspectCache: true)
            await MainActor.run {
                LauncherModel.shared.applyPlayer(snapshot, generation: generation)
            }
        }
    }

    private func applyPlayer(_ snapshot: PlayerSnapshot, generation: Int) {
        guard generation == playerGeneration else { return }
        isCheckingPlayer = false
        playerError = snapshot.error
        configUnreadable = snapshot.configUnreadable
        guard snapshot.isUsable else {
            player = nil
            return
        }
        player = snapshot.data
        UserDefaults.standard.set(snapshot.data.root.path, forKey: Keys.playerFolder)
        rememberPlayer(snapshot.data.root)
        launcherSettings = snapshot.launcherSettings
        engineSettings = snapshot.engineSettings
        missingModules = snapshot.missingModules
        squads = snapshot.squads
        if let cache = snapshot.cacheState {
            cacheState = cache
        }
    }

    func refreshPlayerStatus() {
        guard let player else { return }
        missingModules = player.missingModules()
        squads = SquadSaves.installed(in: player)
        Task.detached(priority: .utility) {
            let state = ShaderCacheGuard.inspect(player)
            await MainActor.run {
                LauncherModel.shared.updateCacheState(state, for: player.root)
            }
        }
    }

    private func updateCacheState(_ state: ShaderCacheState, for root: URL) {
        guard player?.root == root, !isRunning else { return }
        cacheState = state
    }

    func createPlayer() {
        let alert = NSAlert()
        alert.messageText = "New Player"
        alert.informativeText =
            "Each player has their own saves, settings and shader cache. The folder is created in "
            + "\(EngineRun.display(PlayerData.defaultPlayersFolder()))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Player name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !name.isEmpty else {
            showError("Enter a name", "The player needs a name for their folder.")
            return
        }
        let url = PlayerData.defaultPlayersFolder().appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path),
            !confirm(
                "A player named “\(name)” already exists",
                "Use the existing player data in \(EngineRun.display(url))?", action: "Use It")
        {
            return
        }
        selectPlayer(url)
    }

    func choosePlayerFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Player Data Folder"
        panel.message =
            "Choose or create a folder for this player's saves, settings, shader cache and logs."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = playerFolder?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let game = gameDump?.baseFolder, isInside(url, game) || isInside(game, url) {
            showError(
                "Choose a folder outside the game",
                "Player data cannot live inside the game dump, and the game cannot live inside "
                    + "player data. Choose or create a separate folder.")
            return
        }
        selectPlayer(url)
    }

    func resetEngineSettings() {
        guard let player, let seedConfig,
            confirm(
                "Reset engine settings?",
                "This player's engine settings are replaced by the port defaults. The current file "
                    + "is kept next to it. Saves and the shader cache are not touched.",
                action: "Reset")
        else {
            return
        }
        do {
            _ = try player.resetEngineConfig(seedConfig: seedConfig)
            engineSettings = try player.readEngineSettings()
            playerError = nil
            configUnreadable = false
        } catch {
            showError("Engine settings could not be reset", error.localizedDescription)
        }
    }

    func updateEngineSettings(_ change: (inout EngineSettings) -> Void) {
        var settings = engineSettings
        change(&settings)
        if settings.upscaler != .fsr {
            settings.rcas = false
        }
        guard settings != engineSettings, let player else { return }
        engineSettings = settings
        do {
            try player.saveEngineSettings(settings)
        } catch {
            showError("Settings could not be saved", error.localizedDescription)
        }
    }

    func updateLauncherSettings(_ change: (inout LauncherSettings) -> Void) {
        var settings = launcherSettings
        change(&settings)
        guard settings != launcherSettings, let player else { return }
        launcherSettings = settings
        do {
            try player.saveLauncherSettings(settings)
        } catch {
            showError("Settings could not be saved", error.localizedDescription)
        }
    }

    func addModules() {
        guard let player else { return }
        let panel = NSOpenPanel()
        panel.title = "Add System Modules"
        panel.message =
            "Choose the system modules dumped from your own PS4, for example "
            + PlayerData.recommendedModules.joined(separator: ", ") + "."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "sprx") ?? .data]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let installed = try player.installModules(panel.urls)
            refreshPlayerStatus()
            let missing = player.missingModules()
            showInfo(
                "Modules added",
                "Added \(installed.joined(separator: ", ")) to \(EngineRun.display(player.systemModules))."
                    + (missing.isEmpty ? "" : " Still missing: \(missing.joined(separator: ", ")).")
            )
        } catch {
            showError("Modules could not be added", error.localizedDescription)
        }
    }

    func installSquads() {
        guard let player else { return }
        let panel = NSOpenPanel()
        panel.title = "Install Squads"
        panel.message =
            "Choose an EA SPORTS FC 26 PS4 squads save: its folder (with DATA, INDEX and sce_sys) "
            + "or a .zip that contains it."
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isInstallingSquads = true
        Task.detached(priority: .userInitiated) {
            let outcome: (SquadInstall?, String?)
            do {
                outcome = (try SquadSaves.install(from: source, into: player), nil)
            } catch {
                outcome = (nil, error.localizedDescription)
            }
            await MainActor.run {
                LauncherModel.shared.finishSquadInstall(
                    outcome.0, failure: outcome.1, for: player.root)
            }
        }
    }

    private func finishSquadInstall(_ install: SquadInstall?, failure: String?, for root: URL) {
        isInstallingSquads = false
        if player?.root == root {
            refreshPlayerStatus()
        }
        guard let install else {
            showError("Squads could not be installed", failure ?? "")
            return
        }
        var message =
            "Installed "
            + install.installed.map { "“\($0.displayName)”" }.joined(separator: ", ")
            + " for this player. In the game, load it from Customize > Profile > Load > Squads."
        if !install.replacedBackups.isEmpty {
            message +=
                " The squad save it replaced was moved to "
                + install.replacedBackups.map(EngineRun.display).joined(separator: ", ") + "."
        }
        showInfo("Squads installed", message)
    }

    var shaderCacheSeed: URL? {
        UserDefaults.standard.string(forKey: Keys.shaderCacheSeed)
            .map { URL(fileURLWithPath: $0) }
    }

    func importShaderCache() {
        guard let player else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Shader Cache"
        panel.message =
            "Choose a shader cache (\(titleID).zip) from the user/cache folder of another player or "
            + "port data folder. New players will start with it too."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isImportingCache = true
        Task.detached(priority: .userInitiated) {
            let outcome: (ShaderCacheSummary?, String?)
            do {
                outcome = (try ShaderCacheGuard.importCache(from: source, into: player), nil)
            } catch {
                outcome = (nil, error.localizedDescription)
            }
            await MainActor.run {
                LauncherModel.shared.finishCacheImport(
                    outcome.0, failure: outcome.1, source: source, for: player.root)
            }
        }
    }

    private func finishCacheImport(
        _ summary: ShaderCacheSummary?, failure: String?, source: URL, for root: URL
    ) {
        isImportingCache = false
        guard let summary else {
            showError("The shader cache could not be imported", failure ?? "")
            return
        }
        UserDefaults.standard.set(source.path, forKey: Keys.shaderCacheSeed)
        if player?.root == root {
            cacheState = .valid(summary)
        }
        showInfo(
            "Shader cache imported",
            "This player now starts with \(summary.shaders) shaders and \(summary.pipelines) "
                + "pipelines, which the engine builds before the game starts. New players will "
                + "start with the same cache.")
    }

    func showSaves() {
        guard let player else { return }
        try? FileManager.default.createDirectory(
            at: player.saves, withIntermediateDirectories: true)
        NSWorkspace.shared.open(player.saves)
    }

    func openModulesFolder() {
        guard let player else { return }
        NSWorkspace.shared.open(player.systemModules)
    }

    func showPlayerFolder() {
        guard let player else { return }
        NSWorkspace.shared.activateFileViewerSelecting([player.root])
    }

    func showLogs() {
        guard let player else { return }
        let manager = FileManager.default
        let items = [player.consoleLog, player.engineLogs].filter {
            manager.fileExists(atPath: $0.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting(items.isEmpty ? [player.logs] : items)
    }

    func copyRosettaCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HostCheck.rosettaCommand, forType: .string)
    }

    func checkRosettaAgain() {
        rosettaInstalled = HostCheck.rosettaInstalled()
    }

    func play() {
        guard runState == .idle else { return }
        if let problem = blockingProblem {
            showError("The game cannot start", problem)
            return
        }
        guard let profile, let seedConfig, let game = gameDump, let player else { return }
        runState = .preparing
        let gameGeneration = gameGeneration
        let playerGeneration = playerGeneration
        Task.detached(priority: .userInitiated) {
            let check = PlayCheck(
                gameGeneration: gameGeneration,
                playerGeneration: playerGeneration,
                rosettaInstalled: HostCheck.rosettaInstalled(),
                game: GameDumpInspector.inspect(game.chosenFolder, profile: profile),
                player: PlayerSnapshot(
                    player, seedConfig: seedConfig, seedCache: nil, inspectCache: false),
                runningEngines: HostCheck.runningEngines())
            await MainActor.run {
                LauncherModel.shared.continuePlay(check)
            }
        }
    }

    private func continuePlay(_ check: PlayCheck) {
        runState = .idle
        guard check.gameGeneration == gameGeneration, check.playerGeneration == playerGeneration,
            !pendingTermination
        else {
            return
        }
        rosettaInstalled = check.rosettaInstalled
        if let current = gameDump,
            check.game.problems != current.problems || check.game.baseFolder != current.baseFolder
                || check.game.updateFolder != current.updateFolder
        {
            gameGeneration += 1
            hashGeneration += 1
            gameDump = check.game
            hashState = .idle
        }
        playerError = check.player.error
        configUnreadable = check.player.configUnreadable
        if check.player.isUsable {
            engineSettings = check.player.engineSettings
            launcherSettings = check.player.launcherSettings
            missingModules = check.player.missingModules
        } else {
            player = nil
        }
        if let problem = blockingProblem {
            showError("The game cannot start", problem)
            return
        }
        guard let game = gameDump, let player else { return }
        let gameFolders = [game.baseFolder, game.updateFolder].compactMap { $0 }
        if gameFolders.contains(where: { isInside(player.root, $0) || isInside($0, player.root) }) {
            showError(
                "Game and player data must be separate",
                "The game folder and the player data folder cannot contain each other. Choose "
                    + "another player folder.")
            return
        }
        if !check.runningEngines.isEmpty {
            showError(
                "The game engine is already running",
                "Another shadPS4 game is running (process "
                    + check.runningEngines.map(String.init).joined(separator: ", ")
                    + "). Quit it first; if it does not respond, force quit it in Activity Monitor."
            )
            return
        }
        guard case .acquired(let lock) = PlayerDataLock.acquire(player) else {
            showError(
                "This player is already playing",
                "Another launcher is using \(EngineRun.display(player.root)). Close it, or choose "
                    + "another player.")
            return
        }
        guard confirmWarnings(player) else { return }
        start(game, player, lock: lock)
    }

    private func start(_ game: GameDump, _ player: PlayerData, lock: PlayerDataLock?) {
        self.lock = lock
        hashTask?.cancel()
        if case .running = hashState {
            hashState = .idle
        }
        runState = .preparing
        stopRequested = false
        let settings = engineSettings
        let launcherSettings = launcherSettings
        let revision = buildInfo?.engineRevision ?? "unknown"
        Task.detached(priority: .userInitiated) {
            let cache = ShaderCacheGuard.protect(player, engineRevision: revision)
            let failure: String?
            do {
                try player.applyRunProfile(settings, diagnosticLog: launcherSettings.diagnosticLog)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                LauncherModel.shared.launch(
                    game, player, settings, launcherSettings, cache: cache, failure: failure)
            }
        }
    }

    private func confirmWarnings(_ player: PlayerData) -> Bool {
        if !missingModules.isEmpty, !launcherSettings.modulesNoticeShown {
            let alert = NSAlert()
            alert.messageText = "Some system modules are missing"
            alert.informativeText =
                "Missing: \(missingModules.joined(separator: ", ")).\n\nThe game starts and plays "
                + "without them, but menu videos and their sound may be missing. They come from your "
                + "own PS4's system software; the launcher cannot include them. You can add them "
                + "later in System Modules."
            alert.addButton(withTitle: "Play Anyway")
            alert.addButton(withTitle: "Add Modules…")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                updateLauncherSettings { $0.modulesNoticeShown = true }
            case .alertSecondButtonReturn:
                addModules()
                return false
            default:
                return false
            }
        }
        if case .mismatch(let files) = hashState,
            !confirm(
                "Your game files differ from the reference dump",
                "\(files.joined(separator: ", ")) do not match the SHA-256 of the 01.25 dump the port "
                    + "was validated with. The game may still work if your dumper wrote them "
                    + "differently; if you see crashes or broken graphics, dump the game again.",
                action: "Play Anyway")
        {
            return false
        }
        if !FileManager.default.fileExists(atPath: player.shaderCache.path),
            !launcherSettings.shaderNoticeShown
        {
            guard
                confirm(
                    "The first runs stutter",
                    "The game compiles its shaders while you play, so the first runs pause and "
                        + "stutter, especially in new scenes. The shader cache is saved for this "
                        + "player and later runs get smoother. Quit the game with ⌘Q so the cache "
                        + "is saved.",
                    action: "Play")
            else {
                return false
            }
            updateLauncherSettings { $0.shaderNoticeShown = true }
        }
        return true
    }

    private func launch(
        _ game: GameDump, _ player: PlayerData, _ settings: EngineSettings,
        _ launcherSettings: LauncherSettings, cache: ShaderCacheState, failure: String?
    ) {
        cacheState = cache
        if let failure {
            finishWithoutRun()
            showError("The game cannot start", failure)
            return
        }
        let run = EngineRun(
            engine: engine, game: game, data: player, settings: settings,
            launcherSettings: launcherSettings, buildInfo: buildInfo)
        let started = Date()
        do {
            process = try run.start { status, reason in
                Task { @MainActor in
                    LauncherModel.shared.engineExited(
                        status: status, reason: reason, started: started, player: player)
                }
            }
            runState = .running(since: started)
        } catch {
            finishWithoutRun()
            showError("The game engine could not be started", error.localizedDescription)
        }
    }

    private func finishWithoutRun() {
        runState = .idle
        lock = nil
        process = nil
    }

    private func engineExited(
        status: Int32, reason: Process.TerminationReason, started: Date, player: PlayerData
    ) {
        let stoppedByUser = stopRequested
        let crashed = reason == .uncaughtSignal || status != 0
        let ended = Date()
        process = nil
        runState = .finishing
        let revision = buildInfo?.engineRevision ?? "unknown"
        Task.detached(priority: .userInitiated) {
            let cache = ShaderCacheGuard.protect(player, engineRevision: revision)
            let run = LastRun(
                endedAt: ended, duration: ended.timeIntervalSince(started), status: status,
                crashed: crashed && !stoppedByUser, stoppedByUser: stoppedByUser,
                cacheNote: LauncherModel.cacheNote(cache))
            await MainActor.run {
                LauncherModel.shared.completeRun(run, cache: cache)
            }
        }
    }

    private func completeRun(_ run: LastRun, cache: ShaderCacheState) {
        lastRun = run
        cacheState = cache
        runState = .idle
        lock = nil
        if let settings = try? player?.readEngineSettings() {
            engineSettings = settings
        }
        if pendingTermination {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.activate()
        } else {
            NSApp.terminate(nil)
        }
    }

    nonisolated private static func cacheNote(_ state: ShaderCacheState) -> String? {
        switch state {
        case .restored:
            "The shader cache from this session was incomplete; the last saved cache was restored."
        case .discarded:
            "The shader cache was damaged and no saved copy exists; it starts again from empty."
        default:
            nil
        }
    }

    func forceStop() {
        guard let process, process.isRunning,
            confirm(
                "Force the game to stop?",
                "Progress since your last save is lost, and shaders compiled in this session may "
                    + "not be kept. Quitting from the game window with ⌘Q is safer.",
                action: "Force Stop")
        else {
            return
        }
        stop(process)
    }

    private func stop(_ process: Process) {
        stopRequested = true
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    func terminationReply() -> NSApplication.TerminateReply {
        switch runState {
        case .idle, .preparing:
            return .terminateNow
        case .finishing:
            pendingTermination = true
            return .terminateLater
        case .running:
            guard let process, process.isRunning else { return .terminateNow }
            guard
                confirm(
                    "The game is still running",
                    "Quit the game from its window with ⌘Q first. Stopping it from here loses "
                        + "progress since your last save.",
                    action: "Stop Game and Quit")
            else {
                return .terminateCancel
            }
            pendingTermination = true
            stop(process)
            return .terminateLater
        }
    }

    private func rememberPlayer(_ root: URL) {
        recentPlayers.removeAll { $0.standardizedFileURL == root.standardizedFileURL }
        recentPlayers.insert(root, at: 0)
        recentPlayers = Array(recentPlayers.prefix(8))
        UserDefaults.standard.set(recentPlayers.map(\.path), forKey: Keys.recentPlayers)
    }

    private func isInside(_ child: URL, _ parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private struct PlayerSnapshot {
    let data: PlayerData
    var error: String?
    var configUnreadable = false
    var launcherSettings = LauncherSettings()
    var engineSettings = EngineSettings()
    var missingModules: [String] = []
    var squads: [SquadSave] = []
    var cacheState: ShaderCacheState?

    var isUsable: Bool { error == nil || configUnreadable }

    init(_ data: PlayerData, seedConfig: URL, seedCache: URL?, inspectCache: Bool) {
        self.data = data
        do {
            try data.prepare(seedConfig: seedConfig, seedCache: seedCache)
        } catch {
            self.error = error.localizedDescription
            return
        }
        launcherSettings = data.loadLauncherSettings()
        do {
            engineSettings = try data.readEngineSettings()
        } catch {
            self.error = error.localizedDescription
            configUnreadable = true
        }
        missingModules = data.missingModules()
        squads = SquadSaves.installed(in: data)
        if inspectCache {
            cacheState = ShaderCacheGuard.inspect(data)
        }
    }
}

private struct PlayCheck {
    let gameGeneration: Int
    let playerGeneration: Int
    let rosettaInstalled: Bool
    let game: GameDump
    let player: PlayerSnapshot
    let runningEngines: [Int32]
}
