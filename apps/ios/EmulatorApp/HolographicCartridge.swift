import SwiftUI
import UIKit
import CoreMotion
import LibraryKit

/// A cartridge sheathed in glossy plastic: as you tilt the phone, a soft reflection of light glides
/// across its face — the sheen you see sliding over shrink-wrap. The reflection is a real Metal shader
/// (`PlasticSheen.metal`, applied via `.colorEffect`): a directional glare, a pastel prismatic fringe,
/// a cellophane streak, and a faint sparkle, all blooming only as the card leans into the light.
///
/// The light source is the device's tilt (CoreMotion gyro), measured relative to however you were
/// holding the phone when you picked the card up. Where there's no gyro (Simulator, and the macOS
/// shelf) it falls back to a slow auto-orbit.
///
/// Used as the long-press context-menu preview on the shelf — pick a game up and it catches the light.
struct HolographicCartridge: View {
    let system: GameSystem
    let cover: UIImage?
    let title: String
    let systemTag: String
    var crop: CoverCrop? = nil

    @ObservedObject private var motion = TiltMotion.shared

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Tilt drives everything: −1…1 on each axis. Auto-orbit when there's no gyro.
                let tx = motion.isAvailable ? motion.tiltX : CGFloat(sin(t * 0.8)) * 0.5
                let ty = motion.isAvailable ? motion.tiltY : CGFloat(cos(t * 0.55)) * 0.5

                CartridgeView(system: system, cover: cover, title: title,
                              systemTag: systemTag, crop: crop,
                              foilTilt: CGSize(width: tx, height: ty))
                    // A gentle parallax bank toward the light, so the sheen reads as a reflection off
                    // a physical surface rather than a moving decal.
                    .rotation3DEffect(.degrees(Double(tx) * 10), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(Double(-ty) * 7), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            }
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }
}

/// Publishes the device's tilt as a smoothed −1…1 offset on each axis, from CoreMotion's gravity
/// vector — measured *relative* to the pose when a preview appears, so the sheen starts centred and
/// responds to movement rather than to how you happen to be holding the phone. A light spring gives it
/// a touch of overshoot and settle. Ref-counted start/stop so the one shared manager only runs while a
/// holo preview is on screen.
final class TiltMotion: ObservableObject {
    static let shared = TiltMotion()

    @Published var tiltX: CGFloat = 0   // −1 leaned left … +1 leaned right (relative to pick-up pose)
    @Published var tiltY: CGFloat = 0   // −1 leaned away … +1 leaned toward you

    private var velX: CGFloat = 0, velY: CGFloat = 0
    private var baseX: CGFloat = 0, baseY: CGFloat = 0
    private var hasBase = false

    private let manager = CMMotionManager()
    private var subscribers = 0

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        subscribers += 1
        guard subscribers == 1, manager.isDeviceMotionAvailable else { return }
        hasBase = false
        velX = 0; velY = 0
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            let gx = CGFloat(g.x), gy = CGFloat(g.y)
            // First sample after appearing defines "flat" — everything after is movement from there.
            if !self.hasBase { self.baseX = gx; self.baseY = gy; self.hasBase = true }
            let tx = max(-1, min(1, (gx - self.baseX) * 2.6))
            let ty = max(-1, min(1, (gy - self.baseY) * 2.6))
            // Critically-damped-ish spring toward the target — glides with a little life, no jitter.
            let stiffness: CGFloat = 0.20, damping: CGFloat = 0.72
            self.velX = self.velX * damping + (tx - self.tiltX) * stiffness
            self.velY = self.velY * damping + (ty - self.tiltY) * stiffness
            self.tiltX += self.velX
            self.tiltY += self.velY
        }
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { manager.stopDeviceMotionUpdates() }
    }
}
