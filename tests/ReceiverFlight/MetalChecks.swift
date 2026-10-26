import Foundation
import CoreGraphics
import Metal

/// Exercise the actual production shader offscreen, including its Swift/Metal ABI.
/// Runtime shader compilation is confined to this test, never used in the iOS app.
func verifyMetalExposure(shaderPath: String) throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("A Metal device is required to verify shutter integration")
    }
    let source = try String(contentsOfFile: shaderPath, encoding: .utf8)
    let library = try device.makeLibrary(source: source, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "waveGlyphVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "waveGlyphFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    expect(MemoryLayout<WaveGlyphInstance>.stride == 48, "Instance ABI must match Metal")
    expect(MemoryLayout<WaveGlyphSample>.stride == 32, "Sample ABI must match Metal")

    let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 8, height: 8, mipmapped: false)
    atlasDescriptor.storageMode = .shared
    atlasDescriptor.usage = .shaderRead
    let atlas = device.makeTexture(descriptor: atlasDescriptor)!
    let white = [UInt8](repeating: 255, count: 64)
    white.withUnsafeBytes { atlas.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }

    func pose(x: CGFloat = 48, y: CGFloat = 32, width: CGFloat = 16, height: CGFloat = 16,
              rotation: CGFloat = 0, opacity: CGFloat = 1) -> ReceiverFlightPose {
        ReceiverFlightPose(center: CGPoint(x: x, y: y), size: CGSize(width: width, height: height),
                           rotation: rotation, opacity: opacity, warmth: 0)
    }

    func render(_ poses: [ReceiverFlightPose]) -> [UInt8] {
        // Nonzero sample offset also checks ranges after the renderer groups atlas pages.
        var samples = [WaveGlyphSample](repeating: WaveGlyphSample(pose(opacity: 0)), count: 3)
        samples.append(contentsOf: poses.map(WaveGlyphSample.init))
        let bounds = poses.reduce(CGRect.null) { $0.union($1.bounds) }
        var glyph = WaveGlyphInstance(bounds: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.width), Float(bounds.height)),
                                      uvRect: SIMD4(0, 0, 1, 1), sampleRange: SIMD2(3, UInt32(poses.count)))
        let instances = device.makeBuffer(bytes: &glyph, length: MemoryLayout<WaveGlyphInstance>.stride)!
        let samplesBuffer = samples.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 96, mipmapped: false)
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .renderTarget
        let output = device.makeTexture(descriptor: outputDescriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instances, offset: 0, index: 0)
        var viewport = SIMD2<Float>(128, 96)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setFragmentBuffer(samplesBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expect(command.status == .completed, "Offscreen shader execution must complete")
        var pixels = [UInt8](repeating: 0, count: 128 * 96 * 4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 96), mipmapLevel: 0) }
        return pixels
    }

    func alpha(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Float { Float(pixels[(y * 128 + x) * 4 + 3]) / 255 }
    func mass(_ pixels: [UInt8]) -> Float { stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + Float(pixels[$1]) / 255 } }
    let sharp = render([pose()])
    expect(alpha(sharp, 48, 32) == 1 && alpha(sharp, 38, 32) == 0, "Static glyphs must stay sharp")

    let moving = render((0..<64).map { pose(x: 32 + (CGFloat($0) + 0.5) * 0.5) })
    expect(abs(alpha(moving, 48, 32) - 0.5) < 0.03, "Motion must blur the glyph itself, without an added sharp head")
    expect(alpha(moving, 33, 32) > 0 && alpha(moving, 63, 32) > 0, "Exposure must extend to both sides of the frame position")
    expect(abs(mass(moving) - mass(sharp)) < mass(sharp) * 0.02, "Normalized exposure must conserve image energy")
    expect(alpha(moving, 48, 20) == 0, "Shutter samples must not leak outside their atlas cell")

    let spinning = render([pose(width: 16, height: 8), pose(width: 16, height: 8, rotation: .pi / 2)])
    expect(abs(alpha(spinning, 54, 32) - 0.5) < 0.03 && abs(alpha(spinning, 48, 38) - 0.5) < 0.03,
           "Exposure must include actual rotation at each subframe")
    let growing = render([pose(width: 8, height: 8), pose(width: 24, height: 24)])
    expect(alpha(growing, 48, 32) == 1 && abs(alpha(growing, 58, 32) - 0.5) < 0.03,
           "Exposure must include actual scale at each subframe")
    let fading = render([pose(opacity: 0), pose(opacity: 1)])
    expect(abs(alpha(fading, 48, 32) - 0.5) < 0.03, "Opacity must be averaged in premultiplied space")
}
