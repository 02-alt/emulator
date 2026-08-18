# Emulator (working title)

A game console emulator written in Swift with a flat, monochrome **"Analogue OS"** design.
macOS today; an **iOS port is in progress** (shared core/library targets build cross-platform).
**1.0 target: Game Boy Advance**, fully playable and polished. PSP is a later phase; PS2 is a
long-term moonshot. Design docs live in [`.context/`](.context/).

## Status — M1 boots ✅ · M2 window ✅ · M3 sound ✅ · M4 saves ✅ · M5 shell ✅ · M6 library ✅ · M7 shelves+box-back ✅
- `EmulatorCore` protocol is the one core-swap boundary.
- `MockGBACore` — animated, input-reactive test pattern + tone; lets the app be built/tested
  with no native dependency.
- `GBACore` — the **real** core, backed by libmgba through a thin C bridge (`MGBABridge`).
- `emu-boot` — headless runner that drives the frame loop and dumps a framebuffer to PPM.
- `emu-window` — **live macOS app**: Metal window at 60fps, dedicated emulation thread, audio
  (AVAudioEngine, audio-master sync), keyboard + game controllers, save states / battery /
  auto-resume, a flat **"Analogue OS"** library (cartridge carousel, Departure Mono pixel type),
  and an Apple-Music-style **glass** play surface with an LCD-grid shader.

## Layout
```
Sources/EmulatorCore   protocol + shared types + MockGBACore
Sources/MGBABridge     C bridge over libmgba (mgba_bridge.c/.h)
Sources/GBACore        real EmulatorCore on libmgba
Sources/emu-boot       headless boot/frame-loop runner
Sources/LibraryKit     library model + JSON store + ROM import + box-art fetch (no AppKit)
Sources/emu-window     the macOS app (AppKit): Analogue-OS Library + glass Play windows
vendor/mgba            libmgba submodule (pinned 0.10.5)
scripts/build-mgba.sh  builds the minimal static libmgba.a
```

## Building

### 1. One-time: build the native core
Requires CMake. There's no Homebrew here, so the pip-provided CMake works:
```sh
python3 -m pip install --user cmake      # if not already available
./scripts/build-mgba.sh                  # -> vendor/mgba/build/libmgba.a
```

### 2. Build + run the Swift package
```sh
swift build
swift test

# Mock core (no ROM needed):
swift run emu-boot --frames 120 --out out/mock.ppm

# Real libmgba core (needs a .gba ROM you own):
swift run emu-boot --real --rom /path/to/game.gba --frames 120 --out out/real.ppm

# The app: opens the wooden-shelf Library (add games, click to play):
swift run emu-window
# Skip the library and play a ROM directly, or run the mock core:
swift run emu-window --rom /path/to/game.gba
swift run emu-window --mock
```

Window controls: Arrows = D-pad · Z = A · X = B · A = L · S = R · Return = Start · Right Shift = Select.
Save/load: F5 quicksave · F9 quickload. Battery saves + auto-resume are automatic. Saves live in
`~/Library/Application Support/Emulator/saves/<game>/`.

Settings (Video · Audio · Emulation · Achievements · Storage) open with **⌘,** or the footer
**SETTINGS** button — from the library or from within a running game — and apply live.

## Notes
- libmgba is **MPL-2.0** — compatible with a closed-source/commercial app.
- CMake 4 needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` for mgba 0.10.5 (handled by the script).
- Next milestones: M2 live Metal window → M3 audio + controller = playable.
