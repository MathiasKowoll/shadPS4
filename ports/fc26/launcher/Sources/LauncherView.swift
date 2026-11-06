import SwiftUI

struct LauncherView: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !model.rosettaInstalled {
                    rosettaSection
                }
                gameSection
                playerSection
                modulesSection
                squadsSection
                settingsSection
                cacheAndLogsSection
            }
            .formStyle(.grouped)
            .disabled(model.isRunning)
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 640, idealHeight: 820)
    }

    private var rosettaSection: some View {
        Section {
            StatusLine(
                .error, "Rosetta 2 is not installed. The PS4 game code runs through Rosetta.")
            Text("Open Terminal, run the command below, then check again.")
                .foregroundStyle(.secondary)
            Text(HostCheck.rosettaCommand)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Copy Command") { model.copyRosettaCommand() }
                Button("Check Again") { model.checkRosettaAgain() }
            }
        } header: {
            Text("This Mac")
        }
    }

    private var gameSection: some View {
        Section {
            LabeledContent("Game folder") {
                HStack {
                    PathText(model.gameFolder, placeholder: "Not chosen")
                    Button("Choose…") { model.chooseGameFolder() }
                }
            }
            if model.isCheckingGame {
                ProgressView { Text("Checking the game folder…") }
                    .controlSize(.small)
            } else if let dump = model.gameDump {
                if dump.isPlayable {
                    StatusLine(
                        .ok,
                        "\(dump.title.isEmpty ? "EA SPORTS FC 26" : dump.title) · \(dump.titleID) · "
                            + "version \(dump.appVersion)")
                    hashStatus
                } else {
                    ForEach(dump.problems, id: \.self) { StatusLine(.error, $0) }
                }
                ForEach(dump.notes, id: \.self) { StatusLine(.info, $0) }
            }
        } header: {
            Text("Game")
        } footer: {
            Text(
                "Your own PS4 dump of EA SPORTS FC 26 (\(model.titleID)), version "
                    + "\(model.appVersion), either merged with the update or with the update dump "
                    + "next to it as \(model.titleID)-UPDATE. Nothing from the game comes with the "
                    + "launcher.")
        }
    }

    @ViewBuilder
    private var hashStatus: some View {
        switch model.hashState {
        case .idle:
            Button("Verify Files") { model.verifyGameFiles() }
        case .running(let fraction):
            ProgressView(value: fraction) {
                Text("Checking the game files against the reference dump (SHA-256)…")
            }
        case .verified:
            StatusLine(.ok, "Game files match the reference dump (SHA-256).")
        case .mismatch(let files):
            StatusLine(
                .warning,
                "\(files.joined(separator: ", ")) differ from the reference dump. The game may still "
                    + "work; if it crashes or looks broken, dump it again.")
            Button("Verify Again") { model.verifyGameFiles() }
        case .failed(let reason):
            StatusLine(.warning, "The game files could not be checked: \(reason)")
            Button("Verify Again") { model.verifyGameFiles() }
        }
    }

    private var playerSection: some View {
        Section {
            LabeledContent("Data folder") {
                HStack {
                    PathText(model.playerFolder, placeholder: "Not chosen")
                    Menu("Change") {
                        Button("New Player…") { model.createPlayer() }
                        Button("Use Another Folder…") { model.choosePlayerFolder() }
                        let others = model.recentPlayers.filter { $0 != model.playerFolder }
                        if !others.isEmpty {
                            Divider()
                            ForEach(others, id: \.self) { folder in
                                Button(EngineRun.display(folder)) { model.selectPlayer(folder) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            if model.isCheckingPlayer {
                ProgressView { Text("Opening the player data…") }
                    .controlSize(.small)
            }
            if let error = model.playerError {
                StatusLine(.error, error)
                if model.configUnreadable {
                    Button("Reset Engine Settings…") { model.resetEngineSettings() }
                }
            }
            if model.player != nil {
                Button("Show in Finder") { model.showPlayerFolder() }
            }
        } header: {
            Text("Player")
        } footer: {
            Text(
                "Saves, settings, shader cache and logs for one player. Create a player for each "
                    + "person who plays on this Mac.")
        }
    }

    private var modulesSection: some View {
        Section {
            ForEach(PlayerData.recommendedModules, id: \.self) { module in
                LabeledContent(module) {
                    if model.missingModules.contains(module) {
                        Text("Missing").foregroundStyle(.orange)
                    } else if model.player != nil {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            HStack {
                Button("Add Modules…") { model.addModules() }
                Button("Open Folder") { model.openModulesFolder() }
            }
            .disabled(model.player == nil)
        } header: {
            Text("System modules")
        } footer: {
            Text(
                "Recommended. Without them the game starts and plays, but menu videos and their "
                    + "sound may be missing. They are part of the PS4 system software: dump them "
                    + "from your own console, where they are in /system/common/lib. The launcher "
                    + "never includes or downloads them.")
        }
    }

    private var squadsSection: some View {
        Section {
            if model.squads.isEmpty {
                Text("No squad saves for this player yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.squads) { squad in
                    LabeledContent(squad.displayName) {
                        Text(squad.directoryName).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Install Squads…") { model.installSquads() }
                    .disabled(model.isInstallingSquads)
                Button("Open Saves Folder") { model.showSaves() }
            }
            .disabled(model.player == nil)
        } header: {
            Text("Squads")
        } footer: {
            Text(
                "Install updated squads made for the PS4 version: a squads save folder, or a .zip "
                    + "that contains one. Load them in the game from Customize > Profile > Load > "
                    + "Squads. The launcher checks that the file is an FC 26 squads save, not who "
                    + "made it; community squads are not supported by EA or by the port.")
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("Fullscreen (turns on macOS Game Mode)", isOn: engineBinding(\.fullscreen))
            Toggle("Show frame rate", isOn: engineBinding(\.showFPS))
            Picker("Upscaling", selection: upscalerBinding) {
                ForEach(Upscaler.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("RCAS sharpening", isOn: engineBinding(\.rcas))
                .disabled(model.engineSettings.upscaler != .fsr)
            Toggle("60 FPS in menus", isOn: launcherBinding(\.menusAt60))
            Toggle("PS4 Pro mode (experimental)", isOn: engineBinding(\.ps4Pro))
            Toggle("Metal performance HUD", isOn: launcherBinding(\.metalHUD))
        } header: {
            Text("Settings")
        } footer: {
            Text(
                "The game always renders at 1920×1080, the validated baseline. Upscaling only "
                    + "changes how that image reaches your display: Bilinear filtering (the "
                    + "default), FSR with optional RCAS sharpening, or Apple's MetalFX, which also "
                    + "gives the window full Retina resolution. 60 FPS in menus is the port's "
                    + "validated default; off, the game's own rate applies, with menus at 30 as on a "
                    + "PS4 and matches at 60. PS4 Pro mode tells the game it runs on a PS4 Pro; it is "
                    + "experimental, and the known issue is a square of noise around the "
                    + "controlled-player marker. The Metal HUD is Apple's performance overlay for "
                    + "diagnostics. Connect your controller before you press Play. Seen once, not "
                    + "confirmed yet: if a goalkeeper wears the outfield kit, open Select Kits in "
                    + "Match Preview, rotate through the kits and pick yours again before Start "
                    + "Match.")
        }
        .disabled(model.player == nil || model.configUnreadable)
    }

    private var cacheAndLogsSection: some View {
        Section {
            LabeledContent("Shader cache") {
                HStack {
                    Text(cacheDescription).multilineTextAlignment(.trailing)
                    Button("Import…") { model.importShaderCache() }
                        .disabled(model.player == nil || model.isImportingCache)
                }
            }
            StatusLine(
                .info,
                "The first runs stutter while shaders compile. The cache is saved for this player "
                    + "when you quit with ⌘Q, and later runs get smoother.")
            LabeledContent("Logs") {
                HStack {
                    PathText(model.player?.logs, placeholder: "—")
                    Button("Show Logs") { model.showLogs() }
                        .disabled(model.player == nil)
                }
            }
            Toggle("Detailed log for bug reports (slower)", isOn: launcherBinding(\.diagnosticLog))
                .disabled(model.player == nil)
        } header: {
            Text("Shader cache and logs")
        } footer: {
            Text(
                "Import copies a shader cache from another player or port data folder on this "
                    + "Mac; the engine builds its pipelines before the game starts, and new players "
                    + "start with the last imported cache. The launcher never downloads or bundles "
                    + "caches. Each run writes logs/last-run.console.log in the player folder and "
                    + "keeps the previous run next to it. The detailed log goes to user/log.")
        }
    }

    private var cacheDescription: String {
        switch model.cacheState {
        case .empty:
            "Empty: the first runs will stutter"
        case .valid(let summary), .restored(let summary):
            "\(summary.shaders) shaders, \(summary.pipelines) pipelines ("
                + ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file) + ")"
        case .unchecked(let bytes):
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                + " (could not be checked)"
        case .damaged:
            "Damaged; the last saved copy is restored when you press Play"
        case .discarded:
            "Damaged; it starts again from empty"
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                footerStatus
                Text(versionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .running = model.runState {
                Button("Force Stop…", role: .destructive) { model.forceStop() }
            }
            Button {
                model.play()
            } label: {
                Text(model.isRunning ? "Playing" : "Play").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canPlay)
        }
        .padding(16)
    }

    @ViewBuilder
    private var footerStatus: some View {
        switch model.runState {
        case .preparing:
            Label("Preparing the shader cache and settings…", systemImage: "hourglass")
        case .running(let since):
            if let preload = model.shaderPreload, !preload.finished {
                Label(
                    preload.summary + " The game starts when this finishes.",
                    systemImage: "hourglass")
            } else {
                Label {
                    Text(
                        "Playing since \(since.formatted(date: .omitted, time: .shortened)). Quit "
                            + "the game with ⌘Q in its window.")
                } icon: {
                    Image(systemName: "gamecontroller.fill")
                }
            }
        case .finishing:
            Label("Saving the shader cache…", systemImage: "hourglass")
        case .idle:
            if let problem = model.blockingProblem {
                StatusLine(.warning, problem).lineLimit(2)
            } else if let run = model.lastRun {
                lastRunStatus(run)
            } else {
                StatusLine(.ok, "Ready to play.")
            }
        }
    }

    @ViewBuilder
    private func lastRunStatus(_ run: LastRun) -> some View {
        let duration = Duration.seconds(run.duration)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        VStack(alignment: .leading, spacing: 2) {
            if run.crashed {
                HStack {
                    StatusLine(
                        .error,
                        "The game stopped unexpectedly after \(duration) (exit code \(run.status))."
                    )
                    Button("Show Log") { model.showLogs() }
                }
            } else if run.stoppedByUser {
                StatusLine(.warning, "The game was stopped after \(duration).")
            } else {
                StatusLine(.ok, "The last session ended normally after \(duration).")
            }
            if let note = run.cacheNote {
                StatusLine(.warning, note)
            }
        }
    }

    private var versionLine: String {
        guard let info = model.buildInfo else { return "Development build" }
        let launcher =
            info.launcherRevision.map { "\(info.launcherVersion) (\($0))" }
            ?? info.launcherVersion
        return "Launcher \(launcher) · engine \(info.engineRevision) · KosmicKrisp "
            + info.kosmicKrispRevision
    }

    private var upscalerBinding: Binding<Upscaler> {
        Binding(
            get: { model.engineSettings.upscaler },
            set: { value in model.updateEngineSettings { $0.upscaler = value } })
    }

    private func engineBinding(_ keyPath: WritableKeyPath<EngineSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.engineSettings[keyPath: keyPath] },
            set: { value in model.updateEngineSettings { $0[keyPath: keyPath] = value } })
    }

    private func launcherBinding(_ keyPath: WritableKeyPath<LauncherSettings, Bool>) -> Binding<
        Bool
    > {
        Binding(
            get: { model.launcherSettings[keyPath: keyPath] },
            set: { value in model.updateLauncherSettings { $0[keyPath: keyPath] = value } })
    }
}

private struct PathText: View {
    let url: URL?
    let placeholder: String

    init(_ url: URL?, placeholder: String) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Text(url.map(EngineRun.display) ?? placeholder)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(url == nil ? .secondary : .primary)
            .help(url?.path ?? "")
    }
}

struct StatusLine: View {
    enum Kind {
        case ok
        case info
        case warning
        case error
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch kind {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
