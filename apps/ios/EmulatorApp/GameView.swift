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
    @State private var showSaveStates = false
    @State private var immersive = false
    @State private var isLandscape = false
    @State private var speed: Double
    @State private var toast: String?

    @State private var ambiencePopover = false

    // Live global settings adjustable in-game (persist to the same store the Settings screen uses).
    @AppStorage(SettingsKey.masterVolume) private var volume = SettingsDefault.masterVolume
    @AppStorage(SettingsKey.ambientScene) private var ambientSceneRaw = SettingsDefault.ambientScene
    @AppStorage(SettingsKey.ambientVolume) private var ambientVolume = SettingsDefault.ambientVolume
    @AppStorage(SettingsKey.rewindEnabled) private var rewindEnabled = SettingsDefault.rewindEnabled

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

                // Landscape floats the toolbar transparently over the game so the picture can use the
                // full height — but that leaves the top-bar icons (fast-forward, save, menu…) sitting
                // on unpredictable game content, where they wash out over bright frames (a white menu
                // screen, etc.). A slim scrim — dark at the very top, fading to clear — sits beneath the
                // floating bar so every control stays legible over ANY game, while the picture below is
                // left untouched. Portrait already has a solid bar; full-screen hides the bar entirely.
                if landscape && !immersive {
                    LinearGradient(
                        colors: [.black.opacity(0.6), .black.opacity(0.3), .clear],
                        startPoint: .top, endPoint: .bottom)
                        .frame(height: 130)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // The on-screen pad is always available (a connected controller works alongside it).
                // The solar "light" button appears only for cartridges with a real light sensor
                // (Boktai / Lunar Knights): tap toggles full sun (on) vs darkness (off).
                TouchControls(
                    onChange: { touchMask = $0; pushInput() },
                    showSolar: session.hasLightSensor,
                    onSolar: { session.setLuminance($0 ? 255 : 0) }
                )
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
        .sheet(isPresented: $showSaveStates, onDismiss: { session.setPaused(false) }) {
            SaveStatesSheet(
                directory: SavePaths.directory(forHash: game.romHash),
                onSave: { slot, done in
                    session.saveState(toSlotStateURL: slot.stateURL, thumbURL: slot.thumbURL) { ok in
                        flash(ok ? "Saved to Slot \(slot.index)" : "Save failed"); done(ok)
                    }
                },
                onLoad: { slot, done in
                    session.loadState(fromSlotStateURL: slot.stateURL) { ok in
                        flash(ok ? "Loaded Slot \(slot.index)" : "Load failed"); done(ok)
                    }
                })
        }
        // In landscape, hide the title and let the toolbar float over the game (its buttons sit over
        // the side letterbox bars) so the picture can use the full screen height. Portrait keeps the
        // solid bar but no title — the game name is redundant against the cover art.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DS.background, for: .navigationBar)
        .toolbarBackground(isLandscape ? .hidden : .visible, for: .navigationBar)
        .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .automatic)
        // Portrait keeps a lean bar — fast-forward + audio leading, Save + Menu trailing — so those
        // two never spill into iOS's auto "•••" overflow (where Save became unreachable and the
        // overflow itself misbehaved). Landscape's toolbar floats over the wide letterbox with room
        // to spare, so it also carries the quick Screenshot / Full Screen buttons. Both actions stay
        // one tap away in portrait via the in-game Menu.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { fastForwardButton }
            ToolbarItem(placement: .topBarLeading) { audioButton }
            if isLandscape {
                ToolbarItem(placement: .topBarTrailing) { fullScreenButton }
                ToolbarItem(placement: .topBarTrailing) { screenshotButton }
            }
            ToolbarItem(placement: .topBarTrailing) { saveSlotsButton }
            ToolbarItem(placement: .topBarTrailing) { menuButton }
        }
        .onChange(of: volume) { _, v in session.setVolume(v) }
        .onChange(of: rewindEnabled) { _, on in session.setRewindEnabled(on) }
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

    // MARK: - Toolbar buttons

    private var fastForwardButton: some View {
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
                .foregroundStyle(speed > 1.0 ? DS.accent : DS.textSecondary)
        }
        .accessibilityLabel("Fast forward")
    }

    private var audioButton: some View {
        Button { ambiencePopover = true } label: {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(ambientSceneRaw == AmbientScene.off.rawValue ? DS.textSecondary : DS.accent)
        }
        .accessibilityLabel("Audio")
        .popover(isPresented: $ambiencePopover) { ambiencePopoverContent }
    }

    private var fullScreenButton: some View {
        Button { immersive.toggle() } label: {
            Image(systemName: immersive ? "arrow.down.right.and.arrow.up.left"
                                        : "arrow.up.left.and.arrow.down.right")
        }
        .accessibilityLabel(immersive ? "Exit full screen" : "Full screen")
    }

    private var screenshotButton: some View {
        Button { takeScreenshot() } label: { Image(systemName: "camera") }
            .accessibilityLabel("Screenshot")
    }

    /// Opens the multi-slot Save States panel (six numbered slots, each Save/Load with a thumbnail).
    /// Pauses while the panel is up so the captured frame + state are the moment you opened it.
    private var saveSlotsButton: some View {
        Button {
            session.setPaused(true)
            showSaveStates = true
        } label: { Image(systemName: "square.stack") }
            .accessibilityLabel("Save states")
    }

    private var menuButton: some View {
        Button { openMenu() } label: { Image(systemName: "line.3.horizontal") }
            .accessibilityLabel("Menu")
    }

    // MARK: - Screen

    @ViewBuilder
    private func screen(landscape: Bool) -> some View {
        // The picture keeps the console's native aspect (GBA 3:2, Game Boy / Color 10:9) so it fills
        // the frame edge-to-edge with no letterbox bars.
        let aspect = game.system.screenAspect
        if landscape {
            // Edge-to-edge: the picture fills the full screen height (under the notch/home indicator
            // and behind the floating toolbar), as large as the console's screen can be on a phone.
            GameMetalView(session: session, filter: filter,
                          lcdBacklit: AppSettings.lcdBacklit, lcdGhosting: AppSettings.lcdGhosting)
                .aspectRatio(aspect, contentMode: .fit)
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
                    .aspectRatio(aspect, contentMode: .fit)
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
                    // Hold-to-rewind lives here (not floating over the game). The sheet's .medium
                    // detent leaves the picture visible up top, so you can watch the scrub; pressing
                    // un-pauses and rewinds, releasing re-pauses. Only shown when enabled in Settings.
                    if rewindEnabled {
                        RewindRow(
                            onDown: { session.setPaused(false); session.setRewinding(true) },
                            onUp: { session.setRewinding(false); session.setPaused(true) })
                    }
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
                        Slider(value: $volume, in: 0...1).tint(DS.accent)
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
                            Slider(value: ambientVolumeBinding, in: 0...1).tint(DS.accent)
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
        .tint(DS.accent)
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

/// Hold-to-rewind menu row: scrubs the state history backward while pressed, green while held.
/// Lives in the in-game menu's Save section; the caller un-pauses on press and re-pauses on release.
private struct RewindRow: View {
    let onDown: () -> Void
    let onUp: () -> Void
    @State private var down = false

    var body: some View {
        HStack {
            Label("Hold to Rewind", systemImage: "backward.fill")
            Spacer()
            if down { Text("Rewinding…").font(.footnote) }
        }
        .foregroundStyle(down ? DS.accent : Color.primary)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; onDown() } }
                .onEnded { _ in down = false; onUp() }
        )
        .accessibilityLabel("Hold to rewind")
    }
}
