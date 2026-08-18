import SwiftUI
import LibraryKit
import EmulatorCore

/// The play screen: the live game rendered with Metal, plus input from the on-screen gamepad and/or
/// a hardware controller, fast-forward, and an in-game menu (save/load/reset/quit). Owns one
/// `EmulationSession` for this game's ROM. Adapts between portrait (screen on top, pad below) and
/// landscape (screen centered, pad overlaid on the sides). Battery SRAM flushes on background /
/// dismiss; save state is manual.
struct GameView: View {
    let game: Game
    let resume: Bool

    @Environment(LibraryModel.self) private var library
    @Environment(ContinuityService.self) private var continuity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var session: EmulationSession
    @State private var pad = GameControllerInput()
    @State private var isReal: Bool

    @State private var touchMask = GBAButtons()
    @State private var padMask = GBAButtons()

    @State private var menuOpen = false
    @State private var immersive = false
    @State private var isLandscape = false
    @State private var speed: Double
    @State private var toast: String?

    @State private var ambiencePopover = false

    // Live global settings adjustable in-game (persist to the same store the Settings screen uses).
    @AppStorage(SettingsKey.masterVolume) private var volume = SettingsDefault.masterVolume
    @AppStorage(SettingsKey.ambientScene) private var ambientSceneRaw = SettingsDefault.ambientScene
    @AppStorage(SettingsKey.ambientVolume) private var ambientVolume = SettingsDefault.ambientVolume

    // Per-game settings, applied at launch. Per-game override wins; otherwise inherit the global default.
    private let filter: DisplayFilter
    private let swapAB: Bool

    init(game: Game, resume: Bool = false) {
        self.game = game
        self.resume = resume
        self.filter = DisplayFilter(rawValue: game.overrideFilter ?? AppSettings.defaultFilter.rawValue) ?? .sharp
        self.swapAB = game.overrideSwapAB ?? AppSettings.defaultSwapAB
        _speed = State(initialValue: game.overrideSpeed ?? 1.0)
        let made = CoreProvider.core(for: game)
        _isReal = State(initialValue: made.isReal)
        _session = State(initialValue: EmulationSession(
            core: made.core,
            saveDirectory: SavePaths.directory(forHash: game.romHash)))
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                DS.background.ignoresSafeArea()

                screen(landscape: landscape)

                // The on-screen pad is always available (a connected controller works alongside it).
                TouchControls { touchMask = $0; pushInput() }
                    .opacity(AppSettings.controlOpacity)
                    .ignoresSafeArea(.container, edges: .bottom)

                // Full Screen: the top bar is hidden for a bigger, cleaner view; this small floating
                // button restores it.
                if immersive {
                    Button { immersive = false } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 6).padding(.trailing, 10)
                    .accessibilityLabel("Exit full screen")
                }

                if let toast {
                    Text(toast)
                        .font(DS.mono(12, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.8), in: Capsule())
                        .transition(.opacity).allowsHitTesting(false)
                }
            }
            .onAppear { isLandscape = landscape }
            .onChange(of: landscape) { _, value in isLandscape = value }
        }
        .sheet(isPresented: $menuOpen, onDismiss: { session.setPaused(false) }) { menuSheet }
        // In landscape, hide the title and let the toolbar float over the game (its buttons sit over
        // the side letterbox bars) so the picture can use the full screen height. Portrait keeps the
        // solid bar.
        .navigationTitle(isLandscape ? "" : game.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.background, for: .navigationBar)
        .toolbarBackground(isLandscape ? .hidden : .visible, for: .navigationBar)
        .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Speed", selection: speedBinding) {
                        Text("Normal (1×)").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                        Text("3×").tag(3.0)
                        Text("4×").tag(4.0)
                    }
                } label: {
                    Image(systemName: "forward.fill")
                        .foregroundStyle(speed > 1.0 ? Color.green : DS.textSecondary)
                }
                .accessibilityLabel("Fast forward")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { ambiencePopover = true } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(ambientSceneRaw == AmbientScene.off.rawValue ? DS.textSecondary : Color.green)
                }
                .accessibilityLabel("Audio")
                .popover(isPresented: $ambiencePopover) { ambiencePopoverContent }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { immersive.toggle() } label: {
                    Image(systemName: immersive ? "arrow.down.right.and.arrow.up.left"
                                                : "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel(immersive ? "Exit full screen" : "Full screen")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { takeScreenshot() } label: { Image(systemName: "camera") }
                    .accessibilityLabel("Screenshot")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session.saveState { ok in flash(ok ? "State saved" : "Save failed") }
                } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Save state")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { openMenu() } label: { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("Menu")
            }
        }
        .onChange(of: volume) { _, v in session.setVolume(v) }
        .onAppear {
            session.start()
            if speed != 1.0 { session.setSpeed(speed) }
            library.markPlayed(game)
            pad.onChange = { mask in padMask = mask; pushInput() }
            pad.onMenu = { menuOpen ? closeMenu() : openMenu() }
            if ProcessInfo.processInfo.environment["EMU_OPEN_MENU"] != nil { openMenu() }
            if resume {
                Task {
                    if let state = await continuity.resumeState(romHash: game.romHash) {
                        session.loadStateData(state) { ok in flash(ok ? "Resumed" : "Couldn't resume") }
                    }
                }
            }
        }
        .onDisappear {
            publishContinuity()
            session.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                session.persistBattery()
                publishContinuity()
            }
        }
    }

    /// Snapshot the current session (save state + frame thumbnail) and publish it for cross-device
    /// "continue where you left off". Best-effort; skipped for the mock core.
    private func publishContinuity() {
        guard isReal else { return }
        let game = game
        session.captureSnapshot { state, thumbnail in
            guard let state else { return }
            Task { await continuity.publish(game: game, state: state, thumbnailPNG: thumbnail) }
        }
    }

    // MARK: - Screen

    @ViewBuilder
    private func screen(landscape: Bool) -> some View {
        if landscape {
            // Edge-to-edge: the 3:2 picture fills the full screen height (under the notch/home
            // indicator and behind the floating toolbar), as large as a GBA screen can be on a phone.
            GameMetalView(session: session, filter: filter,
                          lcdBacklit: AppSettings.lcdBacklit, lcdGhosting: AppSettings.lcdGhosting)
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all)
        } else {
            // Portrait: the screen sits just under the top safe area (never clipped by the notch /
            // dynamic island), full width, with the pad below. Centered in the space above the pad so
            // it isn't stranded at the very top with a large void beneath.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                GameMetalView(session: session, filter: filter,
                          lcdBacklit: AppSettings.lcdBacklit, lcdGhosting: AppSettings.lcdGhosting)
                    .aspectRatio(3.0 / 2.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Spacer(minLength: 0)   // bias the screen slightly above center, clear of the thumb area
            }
        }
    }

    // MARK: - In-game menu

    /// In-game menu as a native sheet (Apple HIG): grouped inset list, SF fonts, standard
    /// Picker/Slider controls, drag indicator + detents. Presented via `.sheet(isPresented:)`.
    private var menuSheet: some View {
        NavigationStack {
            List {
                if !isReal {
                    Section {
                        Label("Mock core — ROM failed to load", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button { closeMenu() } label: { Label("Resume", systemImage: "play.fill") }
                    Button { takeScreenshot(); closeMenu() } label: { Label("Screenshot", systemImage: "camera") }
                    Button { immersive = true; closeMenu() } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }

                Section("Save") {
                    Button {
                        session.saveState { ok in flash(ok ? "State saved" : "Save failed") }; closeMenu()
                    } label: { Label("Save State", systemImage: "arrow.down.circle") }
                    Button {
                        session.loadState { ok in flash(ok ? "State loaded" : "No save state") }; closeMenu()
                    } label: { Label("Load State", systemImage: "arrow.up.circle") }
                        .disabled(!session.hasSaveState)
                    Button {
                        session.reset(); flash("Reset"); closeMenu()
                    } label: { Label("Reset Game", systemImage: "arrow.counterclockwise") }
                }

                Section("Speed") {
                    Picker("Speed", selection: speedBinding) {
                        Text("Normal (1×)").tag(1.0)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                        Text("3×").tag(3.0)
                        Text("4×").tag(4.0)
                    }
                }

                Section("Audio") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1).tint(.green)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }

                Section("Background Sound") {
                    Picker("Soundscape", selection: ambientBinding) {
                        ForEach(AmbientScene.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if ambientSceneRaw != AmbientScene.off.rawValue {
                        HStack {
                            Image(systemName: "cloud.rain").foregroundStyle(.secondary)
                            Slider(value: ambientVolumeBinding, in: 0...1).tint(.green)
                            Image(systemName: "cloud.heavyrain").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) { quitToLibrary() } label: {
                        Label("Quit to Library", systemImage: "xmark")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(game.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { closeMenu() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    /// Compact popover for the toolbar's audio button: manage the game volume AND the background
    /// soundscape (scene + its own volume) together.
    private var ambiencePopoverContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio").font(.headline)

            Text("GAME").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary).frame(width: 22)
                Slider(value: $volume, in: 0...1)
            }

            Divider()

            Text("AMBIENCE").font(.caption2).foregroundStyle(.secondary)
            Picker("Soundscape", selection: ambientBinding) {
                ForEach(AmbientScene.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if ambientSceneRaw != AmbientScene.off.rawValue {
                HStack {
                    Image(systemName: "cloud.rain").foregroundStyle(.secondary).frame(width: 22)
                    Slider(value: ambientVolumeBinding, in: 0...1)
                }
            }
        }
        .padding()
        .frame(width: 300)
        .tint(.green)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Actions

    /// Pickers/sliders that apply their side effect on change.
    private var speedBinding: Binding<Double> {
        Binding(get: { speed }, set: { setSpeed($0) })
    }
    private var ambientBinding: Binding<Int> {
        Binding(get: { ambientSceneRaw }, set: { ambientSceneRaw = $0; AmbientPlayer.shared.apply() })
    }
    private var ambientVolumeBinding: Binding<Double> {
        Binding(get: { ambientVolume }, set: { ambientVolume = $0; AmbientPlayer.shared.apply() })
    }

    private func quitToLibrary() {
        menuOpen = false
        dismiss()
    }

    private func pushInput() { session.setButtons(applyingSwap(touchMask.union(padMask))) }

    /// Honor the per-game A/B swap before the mask reaches the core.
    private func applyingSwap(_ mask: GBAButtons) -> GBAButtons {
        guard swapAB else { return mask }
        var m = mask
        let a = mask.contains(.a), b = mask.contains(.b)
        m.remove(.a); m.remove(.b)
        if a { m.insert(.b) }
        if b { m.insert(.a) }
        return m
    }

    private func openMenu() {
        menuOpen = true
        session.setPaused(true)
    }

    private func closeMenu() {
        menuOpen = false
        session.setPaused(false)
    }

    /// Set the emulation speed (the toolbar's fast-forward menu and the in-game Speed row both use this).
    private func setSpeed(_ value: Double) {
        speed = value
        session.setSpeed(value)
    }

    private func takeScreenshot() {
        guard let png = session.latestFramePNG() else { flash("Screenshot failed"); return }
        ScreenshotSaver.save(png) { ok in flash(ok ? "Saved to Photos" : "Couldn't save") }
    }

    private func flash(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { if toast == message { toast = nil } }
        }
    }
}

/// Hold-to-rewind: reports pressed/released. Green while held.
private struct RewindButton: View {
    let onChange: (Bool) -> Void
    @State private var down = false

    var body: some View {
        Image(systemName: "backward.fill")
            .font(.system(size: 20))
            .foregroundStyle(down ? .green : DS.textSecondary)
            .frame(width: 54, height: 54)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(DS.hairline, lineWidth: 1))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; onChange(true) } }
                    .onEnded { _ in down = false; onChange(false) }
            )
            .accessibilityLabel("Rewind")
    }
}
