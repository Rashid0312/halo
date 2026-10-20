import AppKit
import MetalKit
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

struct FluidGradient: View {
    var configuration: FluidGradientConfiguration = .halo
    @State private var appeared = false

    var body: some View {
        FluidGradientMetalView(configuration: configuration)
            .opacity(appeared ? configuration.opacity : 0)
            .animation(.easeOut(duration: 0.8), value: appeared)
            .onAppear { appeared = true }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct FluidGradientMetalView: NSViewRepresentable {
    var configuration: FluidGradientConfiguration

    func makeCoordinator() -> Renderer { Renderer(configuration: configuration) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1)
        view.framebufferOnly = true
        // Always a still frame: an animated Metal background froze Halo's main
        // thread for up to 83 s while the panel resized or lost the foreground
        // (measured 2026-10-20: 91.6 s vs 6.2 s for the same request).
        view.preferredFramesPerSecond = 1
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        context.coordinator.attach(device: view.device, pixelFormat: view.colorPixelFormat)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.reduceMotion = true
        view.preferredFramesPerSecond = 1
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true
        view.delegate = nil
        coordinator.stop()
    }

    final class Renderer: NSObject, MTKViewDelegate {
        struct Uniforms {
            var resolution = SIMD2<Float>(1, 1)
            var time: Float = 0
            var speed: Float = 0.1
            var intensity: Float = 0.8
            var motion: Float = 1
        }

        var configuration: FluidGradientConfiguration
        var reduceMotion = false
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private let started = CACurrentMediaTime()

        init(configuration: FluidGradientConfiguration) {
            self.configuration = configuration
            super.init()
        }

        func attach(device: MTLDevice?, pixelFormat: MTLPixelFormat) {
            guard let device else { return }
            queue = device.makeCommandQueue()
            do {
                let library = try device.makeLibrary(source: Self.shader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "fluidVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "fluidFragment")
                descriptor.colorAttachments[0].pixelFormat = pixelFormat
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                assertionFailure("Fluid gradient shader failed: \(error)")
            }
        }

        func stop() {
            pipeline = nil
            queue = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let queue, let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            var uniforms = Uniforms(
                resolution: SIMD2(Float(max(view.drawableSize.width, 1)), Float(max(view.drawableSize.height, 1))),
                time: reduceMotion ? 2.4 : Float(CACurrentMediaTime() - started),
                speed: Float(configuration.speed),
                intensity: Float(configuration.intensity),
                motion: reduceMotion ? 0 : 1
            )
            var palette = configuration.colors.prefix(8).map(Self.rgba)
            while palette.count < 8 { palette.append(palette.last ?? SIMD4(0.5, 0.6, 0.9, 1)) }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            palette.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    encoder.setFragmentBytes(baseAddress, length: bytes.count, index: 1)
                }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }

        private static func rgba(_ color: Color) -> SIMD4<Float> {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
            return SIMD4(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), Float(ns.alphaComponent))
        }

        private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct RasterData { float4 position [[position]]; float2 uv; };
        struct Uniforms {
            float2 resolution;
            float time;
            float speed;
            float intensity;
            float motion;
        };

        vertex RasterData fluidVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            RasterData out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            out.uv = float2(p.x, 1.0 - p.y);
            return out;
        }

        float hash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }

        float valueNoise(float2 p) {
            float2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
                       mix(hash21(i + float2(0, 1)), hash21(i + 1.0), f.x), f.y);
        }

        float fbm(float2 p) {
            float value = 0.0;
            float amplitude = 0.52;
            float2x2 rotation = float2x2(0.80, -0.60, 0.60, 0.80);
            for (int i = 0; i < 5; i++) {
                value += amplitude * valueNoise(p);
                p = rotation * p * 2.03 + 9.7;
                amplitude *= 0.49;
            }
            return value;
        }

        fragment float4 fluidFragment(RasterData in [[stage_in]],
                                      constant Uniforms &u [[buffer(0)]],
                                      constant float4 *palette [[buffer(1)]]) {
            float2 uv = in.uv;
            float aspect = u.resolution.x / max(u.resolution.y, 1.0);
            float2 p = (uv - 0.5) * float2(aspect, 1.0);
            float t = u.time * u.speed * u.motion;

            float2 q = float2(
                fbm(p * 1.05 + float2(0.0, t * 0.72)),
                fbm(p * 1.12 + float2(4.1, -t * 0.57))
            );
            float2 r = float2(
                fbm(p * 0.86 + 2.2 * q + float2(t * 0.31, 7.3)),
                fbm(p * 0.91 + 2.0 * q + float2(8.4, -t * 0.28))
            );
            float2 warped = p + (q - 0.5) * (0.48 * u.intensity) + (r - 0.5) * (0.36 * u.intensity);

            float4 color = float4(0.0);
            float total = 0.0;
            for (int i = 0; i < 8; i++) {
                float fi = float(i);
                float phase = fi * 0.785398;
                float2 center = float2(
                    0.58 * sin(t * (0.62 + fi * 0.025) + phase) + 0.11 * sin(t * 0.21 + phase * 2.3),
                    0.47 * cos(t * (0.48 + fi * 0.021) + phase * 1.37) + 0.10 * sin(t * 0.18 - phase)
                );
                float2 delta = warped - center;
                float bend = 0.76 + 0.22 * sin(t * 0.35 + phase + fbm(warped * 0.7) * 3.0);
                delta.x *= bend;
                delta.y /= bend;
                float weight = exp(-dot(delta, delta) * (1.45 + 0.18 * sin(phase + t * 0.2)));
                color += palette[i] * weight;
                total += weight;
            }
            color /= max(total, 0.001);

            float haze = fbm(warped * 1.35 + r * 0.8);
            color.rgb = mix(color.rgb, float3(0.78, 0.87, 0.98), 0.08 + haze * 0.08);
            color.rgb = mix(float3(dot(color.rgb, float3(0.299, 0.587, 0.114))), color.rgb, 0.78);
            color.rgb *= 0.94 + 0.08 * fbm(warped * 2.0 + t * 0.1);

            float dither = (hash21(in.position.xy + fract(u.time) * 17.0) - 0.5) / 255.0;
            color.rgb += dither;
            return float4(color.rgb, 1.0);
        }
        """
    }
}
