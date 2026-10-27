import Metal
import QuartzCore
import UIKit
import CoreText

/// Immutable font data and one serial worker keep first-use CJK shaping off the display clock.
private final class WaveGlyphRasterizer {
    private let device: MTLDevice
    private let side: Int
    private let rowBytes: Int
    private let attributes: [NSAttributedString.Key: Any]
    private let space = CGColorSpaceCreateDeviceGray()
    private let worker = DispatchQueue(label: "imic.visual.glyphs", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    init(device: MTLDevice, side: Int, rowBytes: Int, font: UIFont) {
        self.device = device
        self.side = side
        self.rowBytes = rowBytes
        attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ]
    }

    func invalidate(generation: UInt64) {
        lock.lock()
        self.generation = generation
        lock.unlock()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    func prepare(_ character: Character, generation: UInt64,
                 completion: @escaping @MainActor (MTLBuffer?) -> Void) {
        worker.async {
            guard self.isCurrent(generation) else { return }
            let bytes: MTLBuffer? = autoreleasepool {
                guard let buffer = self.device.makeBuffer(length: self.rowBytes * self.side, options: .storageModeShared) else { return nil }
                buffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: buffer.length)
                guard let context = CGContext(data: buffer.contents(), width: self.side, height: self.side,
                                              bitsPerComponent: 8, bytesPerRow: self.rowBytes,
                                              space: self.space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: self.attributes))
                let bounds = CTLineGetImageBounds(line, context)
                guard !bounds.isNull else { return buffer }
                context.textPosition = CGPoint(
                    x: (CGFloat(self.side) - bounds.width) / 2 - bounds.minX,
                    y: (CGFloat(self.side) - bounds.height) / 2 - bounds.minY
                )
                CTLineDraw(line, context)
                return buffer
            }
            guard self.isCurrent(generation) else { return }
            DispatchQueue.main.async { completion(bytes) }
        }
    }
}

/// Manually presented from SpectrumStore's clock; no second display link.
final class WaveTextCanvas: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// One draw per atlas page, not one view/layer/draw call per character. New glyphs
/// are rasterized only on ingestion; ordered blits prevent CPU/GPU texture races.
@MainActor
final class WaveTextRenderer {
    enum RenderError: Error { case unavailable, shader, allocation }
    private struct Upload {
        let bytes: MTLBuffer
        let texture: MTLTexture
        let origin: MTLOrigin
    }

    private let view: WaveTextCanvas
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let displayPipeline: MTLRenderPipelineState
    private let compositor: PhosphorCompositor
    private let glyphDepth: MTLDepthStencilState
    private let metrics=PhosphorMetrics()
    private let pass = MTLRenderPassDescriptor()
    private let slots = DispatchSemaphore(value: 3)
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private var capacity = 0
    private var sampleCapacity = 0
    private var glyphs: [Character: WaveGlyphTexture] = [:]
    private var pages: [MTLTexture] = []
    private var uploads: [Upload] = []
    /// New pages are zeroed before any glyph copy: mip filtering reaches across cell edges,
    /// and private textures otherwise start with undefined contents.
    private var clears: [MTLTexture] = []
    private var zeroPage: MTLBuffer?
    private var pageCounts: [Int] = []
    private var pageStarts: [Int] = []
    private var pageCursors: [Int] = []
    // Alpha coverage needs one channel; high-resolution entry/exit text does not need RGBA.
    private let rasterizer: WaveGlyphRasterizer
    private var preparing: Set<Character> = []
    private var prepared: [Character: MTLBuffer] = [:]
    private var failed: Set<Character> = []
    private var atlasGeneration: UInt64 = 0
    private static let pageSide = 2048
    private static let cellSide = 128
    private static let tileRowBytes = 256
    private static let columns = pageSide / cellSide
    private static let cellsPerPage = columns * columns
    private static let mipLevels = 5

    init(view: WaveTextCanvas) throws {
        assert(MemoryLayout<WaveGlyphInstance>.stride == 48)
        assert(MemoryLayout<WaveGlyphInstance>.offset(of: \.sampleRange) == 32)
        assert(MemoryLayout<WaveGlyphSample>.stride == 32)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
        }
        self.view = view
        self.device = device
        self.queue = queue
        rasterizer = WaveGlyphRasterizer(device: device, side: Self.cellSide, rowBytes: Self.tileRowBytes,
                                         font: UIFont.systemFont(ofSize: 88, weight: .medium))
        view.metalLayer.device = device
        view.metalLayer.pixelFormat = .bgra8Unorm_srgb
        view.metalLayer.framebufferOnly = true
        view.metalLayer.isOpaque = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "waveGlyphVertex"),
              let fragment = library.makeFunction(name: "waveGlyphFragment") else { throw RenderError.shader }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.metalLayer.pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let display=MTLRenderPipelineDescriptor()
        display.vertexFunction=vertex
        display.fragmentFunction=library.makeFunction(name:"waveGlyphDisplayFragment")
        display.depthAttachmentPixelFormat = .depth32Float
        for index in 0...1 {
            let attachment=display.colorAttachments[index]!
            attachment.pixelFormat = .rgba16Float
            attachment.isBlendingEnabled=true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = index==0 ? .oneMinusSourceAlpha:.one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = index==0 ? .oneMinusSourceAlpha:.one
        }
        displayPipeline=try device.makeRenderPipelineState(descriptor:display)
        compositor=try PhosphorCompositor(device:device,library:library)
        let depth=MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual;depth.isDepthWriteEnabled=false
        guard let glyphDepth=device.makeDepthStencilState(descriptor:depth)else{throw RenderError.allocation}
        self.glyphDepth=glyphDepth
        try reserve(instances: 1024, samples: 1024)
    }

    func setArtwork(_ image:CGImage,status:CGRect,action:CGRect)throws {
        try compositor.setArtwork(image,status:status,action:action)
    }
    func setClearArtwork(_ image:CGImage)throws{try compositor.setClearArtwork(image)}
    func replaceArtwork(_ image:CGImage,at origin:(x:Int,y:Int))throws{try compositor.replaceArtwork(image,at:origin)}

    func prepare(_ character: Character) {
        guard glyphs[character] == nil, prepared[character] == nil, !failed.contains(character),
              preparing.insert(character).inserted else { return }
        let generation = atlasGeneration
        rasterizer.prepare(character, generation: generation) { [weak self] bytes in
            guard let self, self.atlasGeneration == generation else { return }
            self.preparing.remove(character)
            if let bytes { self.prepared[character] = bytes }
            else { self.failed.insert(character) }
        }
    }

    func texture(for character: Character) throws -> WaveGlyphTexture? {
        if let cached = glyphs[character] { return cached }
        if failed.contains(character) { throw RenderError.allocation }
        guard let bytes = prepared.removeValue(forKey: character) else { return nil }
        let ordinal = glyphs.count
        let page = ordinal / Self.cellsPerPage
        let cell = ordinal % Self.cellsPerPage
        if page == pages.count {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: Self.pageSide, height: Self.pageSide, mipmapped: true)
            // 2048 → 128: enough for 7pt launch glyphs; deeper levels would bleed between cells.
            descriptor.mipmapLevelCount = Self.mipLevels
            descriptor.storageMode = .private
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocation }
            if zeroPage == nil {
                // Shared buffers are zero-filled on allocation; one is reused for every page.
                zeroPage = device.makeBuffer(length: Self.pageSide * Self.pageSide, options: .storageModeShared)
            }
            guard zeroPage != nil else { throw RenderError.allocation }
            clears.append(texture)
            pages.append(texture)
            pageCounts.append(0)
            pageStarts.append(0)
            pageCursors.append(0)
        }
        let side = Self.cellSide
        let x = cell % Self.columns * side
        let y = cell / Self.columns * side
        uploads.append(Upload(bytes: bytes, texture: pages[page], origin: MTLOrigin(x: x, y: y, z: 0)))
        let unit = Float(Self.pageSide)
        let glyph = WaveGlyphTexture(page: page, uv: SIMD4(Float(x) / unit, Float(y) / unit,
                                                         Float(side) / unit, Float(side) / unit))
        glyphs[character] = glyph
        return glyph
    }

    /// Growth happens as content arrives, never by creating a buffer for each draw.
    func reserve(instances: Int, samples: Int) throws {
        guard instances > capacity || samples > sampleCapacity else { return }
        var next = max(1024, capacity)
        while next < instances { next *= 2 }
        var nextSamples = max(1024, sampleCapacity)
        while nextSamples < samples { nextSamples *= 2 }
        let length = next * MemoryLayout<WaveGlyphInstance>.stride + nextSamples * MemoryLayout<WaveGlyphSample>.stride
        var replacement: [MTLBuffer] = []
        replacement.reserveCapacity(3)
        for _ in 0..<3 {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw RenderError.allocation
            }
            replacement.append(buffer)
        }
        buffers = replacement
        capacity = next
        sampleCapacity = nextSamples
    }

    func resetAtlas() {
        atlasGeneration &+= 1
        rasterizer.invalidate(generation: atlasGeneration)
        preparing.removeAll(keepingCapacity: true)
        prepared.removeAll(keepingCapacity: true)
        failed.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        uploads.removeAll(keepingCapacity: true)
        clears.removeAll(keepingCapacity: true)
        pageCounts.removeAll(keepingCapacity: true)
        pageStarts.removeAll(keepingCapacity: true)
        pageCursors.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func draw(_ draws: [WaveGlyphDraw], samples: [WaveGlyphSample] = [], size: CGSize,
              scene: PhosphorScene? = nil) -> Bool {
        guard size.width > 0, size.height > 0, draws.count <= capacity, samples.count <= sampleCapacity,
              slots.wait(timeout: .now()) == .success else { return false }
        guard let drawable = view.metalLayer.nextDrawable(),
              let command = queue.makeCommandBuffer() else { slots.signal(); return false }
        pass.colorAttachments[0].texture = drawable.texture
        let semaphore = slots
        let metrics=metrics
        command.addCompletedHandler { command in
            metrics.record(start:command.gpuStartTime,end:command.gpuEndTime)
            semaphore.signal()
        }
        if !uploads.isEmpty || !clears.isEmpty, let blit = command.makeBlitCommandEncoder() {
            if let zeroPage {
                for page in clears {
                    blit.copy(from: zeroPage, sourceOffset: 0, sourceBytesPerRow: Self.pageSide,
                              sourceBytesPerImage: Self.pageSide * Self.pageSide,
                              sourceSize: MTLSize(width: Self.pageSide, height: Self.pageSide, depth: 1),
                              to: page, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
            }
            for upload in uploads {
                blit.copy(from: upload.bytes, sourceOffset: 0, sourceBytesPerRow: Self.tileRowBytes,
                          sourceBytesPerImage: Self.tileRowBytes * Self.cellSide,
                          sourceSize: MTLSize(width: Self.cellSide, height: Self.cellSide, depth: 1),
                          to: upload.texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: upload.origin)
            }
            // Only pages that received glyphs this frame; ordered after the copies above.
            var touched: [ObjectIdentifier] = []
            for upload in uploads where !touched.contains(ObjectIdentifier(upload.texture)) {
                touched.append(ObjectIdentifier(upload.texture))
                blit.generateMipmaps(for: upload.texture)
            }
            blit.endEncoding()
        }
        let encoder:MTLRenderCommandEncoder?
        if let scene {
            do { try compositor.begin(command:command,drawable:drawable.texture,scene:scene,size:size,now:CACurrentMediaTime()) }
            catch { slots.signal();IMicLog.write("iphone.visual","HDR frame failed: \(error)");return false }
            encoder=compositor.glyphEncoder(command)
        } else { encoder=command.makeRenderCommandEncoder(descriptor:pass) }
        guard let encoder else {
            slots.signal()
            return false
        }
        for page in pages.indices { pageCounts[page] = 0 }
        for draw in draws { pageCounts[draw.page] += 1 }
        var offset = 0
        for page in pages.indices {
            pageStarts[page] = offset
            pageCursors[page] = offset
            offset += pageCounts[page]
        }
        let buffer = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        let output = buffer.contents().bindMemory(to: WaveGlyphInstance.self, capacity: capacity)
        for draw in draws {
            output[pageCursors[draw.page]] = draw.instance
            pageCursors[draw.page] += 1
        }
        let sampleOffset = capacity * MemoryLayout<WaveGlyphInstance>.stride
        samples.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, !bytes.isEmpty {
                memcpy(buffer.contents().advanced(by: sampleOffset), base, bytes.count)
            }
        }
        encoder.setRenderPipelineState(scene == nil ? pipeline:displayPipeline)
        if scene != nil { encoder.setDepthStencilState(glyphDepth) }
        encoder.setFragmentBuffer(buffer, offset: sampleOffset, index: 0)
        var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for page in pages.indices where pageCounts[page] > 0 {
            encoder.setVertexBuffer(buffer, offset: pageStarts[page] * MemoryLayout<WaveGlyphInstance>.stride, index: 0)
            encoder.setFragmentTexture(pages[page], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pageCounts[page])
        }
        encoder.endEncoding()
        if scene != nil { compositor.finish(command:command,drawable:drawable.texture) }
        command.present(drawable)
        command.commit()
        uploads.removeAll(keepingCapacity: true)
        clears.removeAll(keepingCapacity: true)
        return true
    }
}
