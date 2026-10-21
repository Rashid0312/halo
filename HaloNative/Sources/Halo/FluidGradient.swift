import SwiftUI

struct FluidGradientConfiguration: Equatable {
    var colors: [Color]
    var speed: Double
    var intensity: Double
    var opacity: Double

    static let halo = FluidGradientConfiguration(
        colors: [
            Color(red: 0.43, green: 0.48, blue: 0.97),
            Color(red: 0.72, green: 0.56, blue: 0.96),
            Color(red: 0.96, green: 0.65, blue: 0.80),
            Color(red: 0.96, green: 0.72, blue: 0.60),
            Color(red: 0.65, green: 0.85, blue: 0.81),
            Color(red: 0.62, green: 0.79, blue: 0.96),
            Color(red: 0.48, green: 0.88, blue: 0.91),
            Color(red: 0.82, green: 0.70, blue: 0.98),
        ],
        speed: 0.105,
        intensity: 0.82,
        opacity: 0.78
    )

    static let bar = FluidGradientConfiguration(
        colors: halo.colors,
        speed: 0.12,
        intensity: 0.9,
        opacity: 0.9
    )
}

/// The panel's atmospheric background: a still mesh of the Halo palette.
/// It was an animated Metal shader, but that froze Halo's main thread for up
/// to 83 s while the panel resized or lost the foreground (2026-10-20), so it
/// is drawn as a static SwiftUI mesh gradient with no per-frame work.
struct FluidGradient: View {
    var configuration: FluidGradientConfiguration = .halo
    @State private var appeared = false

    var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points, colors: meshColors, smoothsColors: true)
            .saturation(0.85 + 0.15 * configuration.intensity)
            .opacity(appeared ? configuration.opacity : 0)
            .animation(.easeOut(duration: 0.8), value: appeared)
            .onAppear { appeared = true }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    /// A gently offset 3x3 grid so colour regions flow rather than tile.
    private static let points: [SIMD2<Float>] = [
        [0, 0], [0.55, 0], [1, 0],
        [0, 0.45], [0.42, 0.58], [1, 0.38],
        [0, 1], [0.6, 1], [1, 1],
    ]

    private var meshColors: [Color] {
        let palette = configuration.colors.isEmpty ? FluidGradientConfiguration.halo.colors : configuration.colors
        return (0..<9).map { palette[($0 * 3 + 1) % palette.count] }
    }
}
