import SwiftUI
import MetalKit
import AppKit

/// Metal-accelerated emulator display with CRT effects
class MetalDisplayNSView: MTKView, MTKViewDelegate {
    static weak var current: MetalDisplayNSView?
    weak var emulator: EmulatorCore?

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var videoTexture: MTLTexture?
    private var vertexBuffer: MTLBuffer?
    private static var blankTexData = [UInt8](repeating: 0, count: 80 * 256)
    private var lastScrollValue: Int = -1  // force first frame to render

    var phosphorIndex: Int = 0
    var bloomAmount: Float = 0.6
    var scanlineAmount: Float = 0.5
    var curvatureAmount: Float = 0.4
    var screenGlowAmount: Float = 0.5

    override var acceptsFirstResponder: Bool { true }

    // Shared Metal resources — compiled once, reused across all windows
    private static var sharedDevice: MTLDevice?
    private static var sharedPipeline: MTLRenderPipelineState?
    private static var sharedSetupDone = false

    /// Call early (e.g. from App.init) to compile the shader before any window opens.
    static func precompileShader() { ensureSharedSetup() }

    private static func ensureSharedSetup() {
        guard !sharedSetupDone else { return }
        sharedSetupDone = true
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        sharedDevice = device
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vf = library.makeFunction(name: "vertexShader"),
                  let ff = library.makeFunction(name: "fragmentShader") else { return }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vf
            desc.fragmentFunction = ff
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            sharedPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("Metal shader error: \(error)")
        }
    }

    func setup() {
        Self.ensureSharedSetup()
        guard let device = Self.sharedDevice else { return }
        self.device = device
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 60
        self.framebufferOnly = true

        commandQueue = device.makeCommandQueue()
        pipelineState = Self.sharedPipeline

        let vertices: [Float] = [
            -1, -1,  0, 1,
             1, -1,  1, 1,
            -1,  1,  0, 0,
             1,  1,  1, 0,
        ]
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.size)

        // Video RAM texture: stored column-major (80 columns × 256 rows)
        // Upload directly without CPU transpose; shader swaps coordinates
        let texDesc = MTLTextureDescriptor()
        texDesc.width = 256   // each column is 256 bytes
        texDesc.height = 80   // 80 columns
        texDesc.pixelFormat = .r8Unorm
        texDesc.usage = [.shaderRead]
        #if arch(arm64)
        texDesc.storageMode = .shared
        #else
        texDesc.storageMode = .managed
        #endif
        videoTexture = device.makeTexture(descriptor: texDesc)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let emulator = emulator,
              let pipeline = pipelineState,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let drawable = currentDrawable,
              let passDesc = currentRenderPassDescriptor,
              let videoTex = videoTexture else { return }

        // Skip texture upload when display hasn't changed
        let scroll = Int(emulator.io.scanline)
        let dirty = emulator.memory.videoDirty || scroll != lastScrollValue
        if dirty {
            emulator.memory.videoDirty = false
            lastScrollValue = scroll

            // Upload video RAM directly — column-major layout matches texture (256×80)
            // No CPU transpose needed; scroll handled in shader
            let ram = emulator.memory.ram  // UnsafeMutablePointer — no COW copy
            if emulator.io.blankDisplay {
                videoTex.replace(region: MTLRegionMake2D(0, 0, 256, 80),
                                 mipmapLevel: 0, withBytes: &Self.blankTexData, bytesPerRow: 256)
            } else {
                // Direct memcpy from video RAM (80 columns × 256 bytes each)
                videoTex.replace(region: MTLRegionMake2D(0, 0, 256, 80),
                                 mipmapLevel: 0, withBytes: ram + 0x20000, bytesPerRow: 256)
            }
        }

        // Render (always — drawable must be presented even if texture unchanged)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(videoTex, index: 0)

        var uniforms = CRTUniforms(
            phosphorR: phosphorColors[phosphorIndex].0,
            phosphorG: phosphorColors[phosphorIndex].1,
            phosphorB: phosphorColors[phosphorIndex].2,
            bloom: bloomAmount,
            scanline: scanlineAmount,
            curvature: curvatureAmount,
            screenGlow: screenGlowAmount,
            visibleLines: 240,
            scrollOffset: Float(scroll) / 256.0
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CRTUniforms>.size, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private let phosphorColors: [(Float, Float, Float)] = [
        (0.44, 1.0, 0.44),   // Green P31
        (1.0, 0.69, 0.0),    // Amber P3
        (0.93, 0.91, 0.82),  // Paperwhite P4 (warm cream like original Mac)
    ]

    // MARK: - Screenshot

    func saveScreenshot() {
        guard let device = device else { return }
        let w = Int(drawableSize.width)
        let h = Int(drawableSize.height)
        guard w > 0, h > 0 else { return }

        // Render one frame to an offscreen texture we can read back
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .managed
        guard let offscreen = device.makeTexture(descriptor: texDesc),
              let pipeline = pipelineState,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let videoTex = videoTexture else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = offscreen
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(videoTex, index: 0)
        var uniforms = CRTUniforms(
            phosphorR: phosphorColors[phosphorIndex].0,
            phosphorG: phosphorColors[phosphorIndex].1,
            phosphorB: phosphorColors[phosphorIndex].2,
            bloom: bloomAmount, scanline: scanlineAmount,
            curvature: curvatureAmount, screenGlow: screenGlowAmount,
            visibleLines: 240,
            scrollOffset: Float(emulator?.io.scanline ?? 0) / 256.0
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CRTUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Sync managed texture
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: offscreen)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read pixels
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        offscreen.getBytes(&pixels, bytesPerRow: bytesPerRow,
                          from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        // BGRA → RGBA
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = pixels[i]
            pixels[i] = pixels[i + 2]
            pixels[i + 2] = b
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        // Use macOS screenshot conventions: save to Desktop, play shutter sound,
        // then move to ~/Screenshots (or wherever screencapture defaults)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let ts = df.string(from: Date())
        let filename = "NorthMac Screenshot \(ts).png"
        let desktopURL = desktop.appendingPathComponent(filename)
        try? png.write(to: desktopURL)

        // Play the macOS screenshot sound
        NSSound(named: "Grab")?.play()

        // Move to ~/Pictures/Screenshots after a brief delay (like Finder)
        let screenshotsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Screenshots")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
            let finalURL = screenshotsDir.appendingPathComponent(filename)
            try? FileManager.default.moveItem(at: desktopURL, to: finalURL)
            NSLog("Screenshot moved: %@", finalURL.path)
        }
        NSLog("Screenshot saved: %@", desktopURL.path)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) { emulator?.handleKeyDown(event) }
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    // MARK: - Shader

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct CRTUniforms {
        float phosphorR;
        float phosphorG;
        float phosphorB;
        float bloom;         // 0=none, 1=heavy glow
        float scanline;      // 0=none, 1=strong lines
        float curvature;     // 0=flat, 1=curved
        float screenGlow;    // 0=none, 1=strong ambient CRT glow
        float visibleLines;
        float scrollOffset;  // scanline scroll as fraction of 256
    };

    // Texture is 256×80 column-major: X=scanline, Y=column byte
    // Screen coords: screenX (0-1 = 640 pixels), screenY (0-1 = visibleLines scanlines)
    float decodePixel(texture2d<float> tex, sampler s,
                      float screenX, float screenY, float scrollOffset) {
        // Column byte position (0-79)
        float colByte = screenX * 80.0;
        // Bit within byte
        int bitIndex = 7 - (int(screenX * 640.0) % 8);
        // Scanline with scroll (wraps at 256)
        float row = fract(screenY + scrollOffset);
        // Sample: X axis = scanline (row/256), Y axis = column (colByte/80)
        float2 texUV = float2(row, colByte / 80.0);
        float byteVal = tex.sample(s, texUV).r;
        int byteInt = int(byteVal * 255.0 + 0.5);
        return float((byteInt >> bitIndex) & 1);
    }

    vertex VertexOut vertexShader(uint vid [[vertex_id]],
                                  constant float4 *vertices [[buffer(0)]]) {
        VertexOut out;
        float4 v = vertices[vid];
        out.position = float4(v.xy, 0, 1);
        out.texCoord = v.zw;
        return out;
    }

    fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                    texture2d<float> videoTex [[texture(0)]],
                                    constant CRTUniforms &u [[buffer(0)]]) {
        constexpr sampler nearest(filter::nearest);

        float2 uv = in.texCoord;

        // CRT barrel distortion
        float2 centered = uv - 0.5;
        float r2 = dot(centered, centered);
        uv = uv + centered * r2 * 0.08 * u.curvature;

        if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1)
            return float4(0, 0, 0, 1);

        // Scale to visible lines
        float visFrac = u.visibleLines / 256.0;
        float screenX = uv.x;
        float screenY = uv.y * visFrac;

        // Decode current pixel
        float pixel = decodePixel(videoTex, nearest, screenX, screenY, u.scrollOffset);

        // Bloom: 4 cardinal + 4 diagonal neighbors
        float bloomVal = 0.0;
        if (u.bloom > 0.01) {
            float bw = 1.0 / 640.0;
            float bh = 1.0 / u.visibleLines;
            bloomVal += decodePixel(videoTex, nearest, screenX - bw, screenY, u.scrollOffset);
            bloomVal += decodePixel(videoTex, nearest, screenX + bw, screenY, u.scrollOffset);
            bloomVal += decodePixel(videoTex, nearest, screenX, screenY - bh, u.scrollOffset);
            bloomVal += decodePixel(videoTex, nearest, screenX, screenY + bh, u.scrollOffset);
            bloomVal += decodePixel(videoTex, nearest, screenX - bw, screenY - bh, u.scrollOffset) * 0.7;
            bloomVal += decodePixel(videoTex, nearest, screenX + bw, screenY - bh, u.scrollOffset) * 0.7;
            bloomVal += decodePixel(videoTex, nearest, screenX - bw, screenY + bh, u.scrollOffset) * 0.7;
            bloomVal += decodePixel(videoTex, nearest, screenX + bw, screenY + bh, u.scrollOffset) * 0.7;
            bloomVal /= 6.8;
            pixel = min(pixel + bloomVal * u.bloom * 1.5, 1.0);
        }

        // Scanline effect
        float scanMask = 1.0;
        if (u.scanline > 0.01) {
            float scanPos = fract(uv.y * u.visibleLines);
            float scanDark = 0.5 * u.scanline;
            scanMask = 1.0 - scanDark * (1.0 - abs(scanPos - 0.5) * 2.0);
        }

        // Screen glow: base ambient + bloom-derived content glow
        float ambientGlow = (0.24 + bloomVal * 0.8) * u.screenGlow;
        float lit = max(pixel, ambientGlow);

        // Apply phosphor color
        float3 color = float3(u.phosphorR, u.phosphorG, u.phosphorB);
        float3 hotColor = mix(color, float3(1.0), lit * 0.15);
        color = hotColor * lit * scanMask;

        // Vignette
        float vignette = 1.0 - r2 * 2.0 * u.curvature;
        color *= max(vignette, 0.3);

        return float4(color, 1.0);
    }
    """;
}

struct CRTUniforms {
    var phosphorR: Float
    var phosphorG: Float
    var phosphorB: Float
    var bloom: Float
    var scanline: Float
    var curvature: Float
    var screenGlow: Float
    var visibleLines: Float
    var scrollOffset: Float
}

/// SwiftUI wrapper
struct MetalEmulatorDisplayView: NSViewRepresentable {
    @ObservedObject var emulator: EmulatorCore
    var phosphor: PhosphorColor
    var bloom: Double
    var scanline: Double
    var curvature: Double
    var screenGlow: Double

    func makeNSView(context: Context) -> MetalDisplayNSView {
        let view = MetalDisplayNSView()
        view.emulator = emulator
        view.setup()
        MetalDisplayNSView.current = view
        return view
    }

    func updateNSView(_ nsView: MetalDisplayNSView, context: Context) {
        switch phosphor {
        case .green: nsView.phosphorIndex = 0
        case .amber: nsView.phosphorIndex = 1
        case .white: nsView.phosphorIndex = 2
        }
        nsView.bloomAmount = Float(bloom)
        nsView.scanlineAmount = Float(scanline)
        nsView.curvatureAmount = Float(curvature)
        nsView.screenGlowAmount = Float(screenGlow)
    }
}
