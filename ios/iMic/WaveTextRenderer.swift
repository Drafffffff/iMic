import Metal
import QuartzCore
import UIKit

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

/// Swift and Metal share this 64-byte, SIMD-aligned instance layout.
struct WaveGlyphInstance {
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var uvRect: SIMD4<Float>
    var orientation: SIMD2<Float>
    var color: SIMD4<Float>
}

struct WaveGlyphTexture {
    let page: Int
    let uv: SIMD4<Float>
}

struct WaveGlyphDraw {
    var instance: WaveGlyphInstance
    let page: Int
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
    private let pass = MTLRenderPassDescriptor()
    private let slots = DispatchSemaphore(value: 3)
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private var capacity = 0
    private var glyphs: [Character: WaveGlyphTexture] = [:]
    private var pages: [MTLTexture] = []
    private var uploads: [Upload] = []
    private var pageCounts: [Int] = []
    private var pageStarts: [Int] = []
    private var pageCursors: [Int] = []
    private let font = UIFont.systemFont(ofSize: 33, weight: .medium)
    private static let pageSide = 1024
    private static let cellSide = 48
    private static let tileRowBytes = 256
    private static let columns = pageSide / cellSide
    private static let cellsPerPage = columns * columns

    init(view: WaveTextCanvas) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
        }
        self.view = view
        self.device = device
        self.queue = queue
        view.metalLayer.device = device
        view.metalLayer.pixelFormat = .bgra8Unorm
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
        try reserve(instances: 1024)
    }

    func texture(for character: Character) throws -> WaveGlyphTexture {
        if let cached = glyphs[character] { return cached }
        let ordinal = glyphs.count
        let page = ordinal / Self.cellsPerPage
        let cell = ordinal % Self.cellsPerPage
        if page == pages.count {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: Self.pageSide, height: Self.pageSide, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocation }
            pages.append(texture)
            pageCounts.append(0)
            pageStarts.append(0)
            pageCursors.append(0)
        }
        let side = Self.cellSide
        guard let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: Self.tileRowBytes,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                        | CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data else { throw RenderError.allocation }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        let text = String(character) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (CGFloat(side) - size.width) / 2,
                              y: (CGFloat(side) - size.height) / 2), withAttributes: attributes)
        UIGraphicsPopContext()
        guard let bytes = device.makeBuffer(bytes: pixels, length: Self.tileRowBytes * side,
                                            options: .storageModeShared) else { throw RenderError.allocation }
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
    func reserve(instances: Int) throws {
        guard instances > capacity else { return }
        var next = max(1024, capacity)
        while next < instances { next *= 2 }
        let length = next * MemoryLayout<WaveGlyphInstance>.stride
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
    }

    func resetAtlas() {
        glyphs.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        uploads.removeAll(keepingCapacity: true)
        pageCounts.removeAll(keepingCapacity: true)
        pageStarts.removeAll(keepingCapacity: true)
        pageCursors.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func draw(_ draws: [WaveGlyphDraw], size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, draws.count <= capacity,
              slots.wait(timeout: .now()) == .success else { return false }
        guard let drawable = view.metalLayer.nextDrawable(),
              let command = queue.makeCommandBuffer() else { slots.signal(); return false }
        pass.colorAttachments[0].texture = drawable.texture
        let semaphore = slots
        command.addCompletedHandler { _ in semaphore.signal() }
        if !uploads.isEmpty, let blit = command.makeBlitCommandEncoder() {
            for upload in uploads {
                blit.copy(from: upload.bytes, sourceOffset: 0, sourceBytesPerRow: Self.tileRowBytes,
                          sourceBytesPerImage: Self.tileRowBytes * Self.cellSide,
                          sourceSize: MTLSize(width: Self.cellSide, height: Self.cellSide, depth: 1),
                          to: upload.texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: upload.origin)
            }
            blit.endEncoding()
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
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
        encoder.setRenderPipelineState(pipeline)
        var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        for page in pages.indices where pageCounts[page] > 0 {
            encoder.setVertexBuffer(buffer, offset: pageStarts[page] * MemoryLayout<WaveGlyphInstance>.stride, index: 0)
            encoder.setFragmentTexture(pages[page], index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pageCounts[page])
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        uploads.removeAll(keepingCapacity: true)
        return true
    }
}
