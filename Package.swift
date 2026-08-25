// swift-tools-version: 6.0
import PackageDescription

// Working package name — the shipped app name/branding is still TBD.
let package = Package(
    name: "Emulator",
    // .macOS(.v15)/.iOS(.v18) for the Synchronization module (lock-free audio ring).
    // The shared lower layers (EmulatorCore, LibraryKit, and — once a native iOS libmgba is
    // built — MGBABridge/GBACore) build for both; only emu-window (AppKit) is macOS-only.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "EmulatorCore", targets: ["EmulatorCore"]),
        .library(name: "GBACore", targets: ["GBACore"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .library(name: "ContinuityKit", targets: ["ContinuityKit"]),
        .executable(name: "emu-boot", targets: ["emu-boot"]),
        .executable(name: "emu-window", targets: ["emu-window"]),
    ],
    dependencies: [
        // In-app auto-update (macOS only): downloads + installs new releases in place, no browser.
        // Sparkle ships as a binary xcframework via SwiftPM; release.sh embeds + signs it in the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Core-agnostic contract every emulator core conforms to, plus a mock GBA
        // core so the whole app (render/audio/input/library) can be built and tested
        // without the native libmgba dependency. This is the one swap boundary:
        // libmgba drops in behind `EmulatorCore` as `GBACore` with zero UI changes.
        .target(name: "EmulatorCore"),

        // C bridge over libmgba. Requires the static core built first:
        //   ./scripts/build-mgba.sh   -> vendor/mgba/build/libmgba.a
        .target(
            name: "MGBABridge",
            cSettings: [
                .unsafeFlags([
                    "-Ivendor/mgba/include",
                    "-Ivendor/mgba/build/include",
                ]),
            ],
            linkerSettings: [
                // macOS links the flat static lib from ./scripts/build-mgba.sh. On iOS the
                // libmgba symbols come from vendor/mgba/mgba.xcframework instead (built by
                // ./scripts/build-mgba-ios.sh), linked at the app-target level so Xcode can pick
                // the device vs simulator slice — so no -L/-lmgba here for iOS.
                .unsafeFlags(["-Lvendor/mgba/build", "-lmgba"], .when(platforms: [.macOS])),
                .linkedLibrary("m"),
                // OpenGL is macOS-only (removed on iOS); the iOS libmgba slice is built without
                // the GL renderer so these symbols aren't referenced there.
                .linkedFramework("OpenGL", .when(platforms: [.macOS])),
            ]
        ),

        // Real GBA core: EmulatorCore implemented on libmgba via MGBABridge.
        .target(name: "GBACore", dependencies: ["EmulatorCore", "MGBABridge"]),

        // Library model + persistence + ROM import + box-art fetching (no AppKit).
        .target(
            name: "LibraryKit",
            resources: [.process("Resources")]   // bundled Libretro GBA database (CC BY-SA 4.0)
        ),

        // Cross-device "continue where you left off": savestate + card synced through the
        // user's private CloudKit DB, keyed by ROM hash. No EmulatorCore dependency —
        // works on Data + romHash, so both apps and tests share it.
        .target(name: "ContinuityKit"),

        // Headless "does it boot and run frames" runner (Milestone M1).
        .executableTarget(
            name: "emu-boot",
            dependencies: ["EmulatorCore", "GBACore"]
        ),

        // Live Metal window + flat "Analogue OS" library + glass play UI. AppKit + MetalKit (macOS).
        .executableTarget(
            name: "emu-window",
            dependencies: [
                "EmulatorCore", "GBACore", "LibraryKit", "ContinuityKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.process("Resources")],   // bundled Departure Mono pixel font (SIL OFL)
            linkerSettings: [
                // The assembled .app carries Sparkle.framework in Contents/Frameworks; teach the
                // executable to find it there at runtime (SwiftPM's dev rpath points at .build only).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                             .when(platforms: [.macOS])),
            ]
        ),

        .testTarget(
            name: "EmulatorCoreTests",
            dependencies: ["EmulatorCore"]
        ),

        // Integration tests against the real libmgba-backed core.
        .testTarget(
            name: "GBACoreTests",
            dependencies: ["GBACore", "EmulatorCore"]
        ),

        .testTarget(
            name: "LibraryKitTests",
            dependencies: ["LibraryKit"]
        ),

        .testTarget(
            name: "ContinuityKitTests",
            dependencies: ["ContinuityKit"]
        ),
    ]
)
