import MetalKit
import UIKit

/// HDR render graph. Owns targets across frames and is driven only by SpectrumStore.
@MainActor
final class PhosphorCompositor {
    private let device: MTLDevice
    private let lines: MTLRenderPipelineState
    private let historyPipeline: MTLRenderPipelineState
    private let seedPipeline: MTLRenderPipelineState
    private let downPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var core: MTLTexture?
    private var emission: MTLTexture?
    private var depth: MTLTexture?
    private var history: [MTLTexture] = []
    private var bloom: [[MTLTexture]] = []
    private var artwork: MTLTexture
    private var clearArtwork: MTLTexture?
    private var strokeBuffers: [MTLBuffer] = []
    private var strokeCapacity=0
    private var slot=0
    private var historyIndex=0
    private var historyValid=false
    private var lastTime:Double?
    private var width=0,height=0
    private var lastEffect:PhosphorEffect?
    private var uniforms=PhosphorUniforms(viewport:.zero,timing:.zero,regions:.zero)
    private(set) var targetBytes=0

    init(device:MTLDevice,library:MTLLibrary)throws{
        self.device=device
        func pipeline(_ vertex:String,_ fragment:String,_ format:MTLPixelFormat = .rgba16Float,
                      mrt:Bool=false)throws->MTLRenderPipelineState{
            guard let v=library.makeFunction(name:vertex),let f=library.makeFunction(name:fragment) else{throw WaveTextRenderer.RenderError.shader}
            let d=MTLRenderPipelineDescriptor();d.vertexFunction=v;d.fragmentFunction=f
            d.colorAttachments[0].pixelFormat=format
            if mrt{
                d.depthAttachmentPixelFormat = .depth32Float
                d.colorAttachments[1].pixelFormat = .rgba16Float
                for i in 0...1{
                    let a=d.colorAttachments[i]!
                    // Light sources saturate rather than stack: max blending keeps the 96 joints
                    // of every ring and arc from doubling into beads, in core and emission alike.
                    a.isBlendingEnabled=true;a.sourceRGBBlendFactor = .one;a.destinationRGBBlendFactor = .one
                    a.sourceAlphaBlendFactor = .one;a.destinationAlphaBlendFactor = .one
                    a.rgbBlendOperation = .max;a.alphaBlendOperation = .max
                }
            }
            return try device.makeRenderPipelineState(descriptor:d)
        }
        lines=try pipeline("phosphorStrokeVertex","phosphorStrokeFragment",mrt:true)
        historyPipeline=try pipeline("phosphorFullscreenVertex","phosphorHistoryFragment")
        seedPipeline=try pipeline("phosphorFullscreenVertex","phosphorSeedFragment")
        downPipeline=try pipeline("phosphorFullscreenVertex","phosphorDownsampleFragment")
        blurPipeline=try pipeline("phosphorFullscreenVertex","phosphorBlurFragment")
        compositePipeline=try pipeline("phosphorFullscreenVertex","phosphorCompositeFragment",.bgra8Unorm_srgb)
        let ds=MTLDepthStencilDescriptor();ds.depthCompareFunction = .lessEqual;ds.isDepthWriteEnabled=true
        guard let state=device.makeDepthStencilState(descriptor:ds) else{throw WaveTextRenderer.RenderError.allocation};depthState=state
        let empty=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm_srgb,width:1,height:1,mipmapped:false)
        empty.storageMode = .shared;empty.usage = .shaderRead
        guard let tex=device.makeTexture(descriptor:empty) else{throw WaveTextRenderer.RenderError.allocation}
        var pixel:UInt32=0xff050505
        tex.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&pixel,bytesPerRow:4);artwork=tex
    }

    func setArtwork(_ image:CGImage,status:CGRect,action:CGRect)throws{
        artwork=try uploadArtwork(image)
        uniforms.regions=SIMD4(Float(status.minY),Float(status.maxY),Float(action.minY),Float(action.maxY))
    }
    func setClearArtwork(_ image:CGImage)throws{clearArtwork=try uploadArtwork(image)}
    /// Patch part of the current artwork in place (pixel origin), instead of a full re-upload.
    func replaceArtwork(_ image:CGImage,at origin:(x:Int,y:Int))throws{
        let w=min(image.width,artwork.width-origin.x),h=min(image.height,artwork.height-origin.y)
        guard origin.x>=0,origin.y>=0,w>0,h>0 else{return}
        let bytes=try rgba(image)
        artwork.replace(region:MTLRegionMake2D(origin.x,origin.y,w,h),mipmapLevel:0,withBytes:bytes.contents(),bytesPerRow:image.width*4)
    }
    /// Premultiplied sRGB RGBA bytes, top row first.
    private func rgba(_ image:CGImage)throws->MTLBuffer{
        let w=image.width,h=image.height,row=w*4
        guard w>0,h>0,let bytes=device.makeBuffer(length:row*h,options:.storageModeShared),
              let space=CGColorSpace(name:CGColorSpace.sRGB),
              let context=CGContext(data:bytes.contents(),width:w,height:h,bitsPerComponent:8,bytesPerRow:row,
                space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)
        else{throw WaveTextRenderer.RenderError.allocation}
        bytes.contents().initializeMemory(as:UInt8.self,repeating:0,count:row*h)
        context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        return bytes
    }

    private func uploadArtwork(_ image:CGImage)throws->MTLTexture{
        let w=image.width,h=image.height,row=w*4
        let bytes=try rgba(image)
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm_srgb,width:w,height:h,mipmapped:false)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:d)else{throw WaveTextRenderer.RenderError.allocation}
        texture.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:bytes.contents(),bytesPerRow:row)
        return texture
    }

    private func texture(_ w:Int,_ h:Int,_ format:MTLPixelFormat = .rgba16Float)throws->MTLTexture{
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:max(1,w),height:max(1,h),mipmapped:false)
        d.storageMode = .private;d.usage = [.renderTarget,.shaderRead]
        guard let t=device.makeTexture(descriptor:d)else{throw WaveTextRenderer.RenderError.allocation}
        targetBytes+=max(1,w)*max(1,h)*(format == .depth32Float ? 4:8)
        return t
    }

    private func resize(_ drawable:MTLTexture)throws{
        guard width != drawable.width || height != drawable.height else{return}
        width=drawable.width;height=drawable.height;targetBytes=0
        core=try texture(width,height);emission=try texture(width,height);depth=try texture(width,height,.depth32Float)
        history=try (0..<2).map{_ in try texture((width+1)/2,(height+1)/2)}
        bloom=try (1...3).map{level in try (0..<2).map{_ in try texture(max(1,width>>level),max(1,height>>level))}}
        historyValid=false;lastTime=nil
        IMicLog.write("iphone.visual","HDR targets \(width)x\(height), \(targetBytes/1048576) MiB, three bloom scales")
    }

    func begin(command:MTLCommandBuffer,drawable:MTLTexture,scene:PhosphorScene,size:CGSize,now:Double)throws{
        try resize(drawable)
        let effect=scene.effect
        let strength=scene.reduceTransparency ? 0:effect.crtStrength
        let glow=scene.reduceTransparency ? 0:effect.bloomStrength
        let dt=lastTime.map{max(0,now-$0)} ?? 1
        let reset = !historyValid || dt>0.2 || lastEffect != effect
        uniforms.viewport=SIMD4(Float(size.width),Float(size.height),Float(drawable.width)/max(1,Float(size.width)),strength)
        uniforms.timing=SIMD4(PhosphorMath.decay(dt:dt),reset ? 1:0,glow,1)
        uniforms.interaction=SIMD4(scene.clearProgress,scene.pressScale(at:now),0,0)
        lastTime=now;lastEffect=effect
        if strokeBuffers.isEmpty || strokeCapacity<scene.strokes.count{
            strokeCapacity=max(8192,scene.strokes.count*2)
            strokeBuffers=try (0..<3).map{_ in
                guard let b=device.makeBuffer(length:strokeCapacity*MemoryLayout<PhosphorStroke>.stride,options:.storageModeShared)else{throw WaveTextRenderer.RenderError.allocation};return b
            }
        }
        guard let core,let emission,let depth else{throw WaveTextRenderer.RenderError.allocation}
        let pass=MTLRenderPassDescriptor()
        for (i,t) in [core,emission].enumerated(){
            pass.colorAttachments[i].texture=t;pass.colorAttachments[i].loadAction = .clear;pass.colorAttachments[i].storeAction = .store
            pass.colorAttachments[i].clearColor=MTLClearColorMake(0,0,0,0)
        }
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .store;pass.depthAttachment.clearDepth=1
        guard let e=command.makeRenderCommandEncoder(descriptor:pass)else{throw WaveTextRenderer.RenderError.allocation}
        e.label="3D wireframe / linear HDR emission";e.setRenderPipelineState(lines);e.setDepthStencilState(depthState)
        let buffer=strokeBuffers[slot];slot=(slot+1)%3
        scene.strokes.withUnsafeBytes{if let p=$0.baseAddress{memcpy(buffer.contents(),p,$0.count)}}
        e.setVertexBuffer(buffer,offset:0,index:0);e.setVertexBytes(&uniforms,length:MemoryLayout<PhosphorUniforms>.stride,index:1)
        e.setFragmentBytes(&uniforms,length:MemoryLayout<PhosphorUniforms>.stride,index:1)
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:scene.strokes.count);e.endEncoding()
        // History is captured BEFORE glyph rendering: text never gains a second motion trail.
        let next=(historyIndex+1)%2
        fullscreen(command:command,pipeline:historyPipeline,destination:history[next],textures:[emission,history[historyIndex]])
        historyIndex=next;historyValid=true
    }

    func glyphEncoder(_ command:MTLCommandBuffer)->MTLRenderCommandEncoder?{
        guard let core,let emission,let depth else{return nil}
        let p=MTLRenderPassDescriptor()
        for (i,t) in [core,emission].enumerated(){p.colorAttachments[i].texture=t;p.colorAttachments[i].loadAction = .load;p.colorAttachments[i].storeAction = .store}
        p.depthAttachment.texture=depth;p.depthAttachment.loadAction = .load;p.depthAttachment.storeAction = .dontCare
        let e=command.makeRenderCommandEncoder(descriptor:p)
        e?.label="Glyph atlas / unchanged shutter exposure"
        e?.setFragmentBytes(&uniforms,length:MemoryLayout<PhosphorUniforms>.stride,index:1)
        return e
    }

    func finish(command:MTLCommandBuffer,drawable:MTLTexture){
        guard let emission,let core else{return}
        if uniforms.timing.z>0{
            fullscreen(command:command,pipeline:seedPipeline,destination:bloom[0][0],textures:[emission,history[historyIndex],artwork,clearArtwork ?? artwork])
            for level in 0..<bloom.count{
                if level>0{fullscreen(command:command,pipeline:downPipeline,destination:bloom[level][0],textures:[bloom[level-1][0]])}
                blur(command,source:bloom[level][0],destination:bloom[level][1],horizontal:true)
                blur(command,source:bloom[level][1],destination:bloom[level][0],horizontal:false)
            }
        } else {
            // These targets were newly allocated without initial contents on a clean-mode launch.
            for level in bloom{clear(command,texture:level[0])}
        }
        fullscreen(command:command,pipeline:compositePipeline,destination:drawable,
                   textures:[core,artwork,bloom[0][0],bloom[1][0],bloom[2][0],clearArtwork ?? artwork])
    }

    private func blur(_ command:MTLCommandBuffer,source:MTLTexture,destination:MTLTexture,horizontal:Bool){
        var direction=SIMD2<Float>(horizontal ? 1/Float(source.width):0,horizontal ? 0:1/Float(source.height))
        fullscreen(command:command,pipeline:blurPipeline,destination:destination,textures:[source]){e in
            e.setFragmentBytes(&direction,length:MemoryLayout<SIMD2<Float>>.stride,index:0)
        }
    }
    private func clear(_ command:MTLCommandBuffer,texture:MTLTexture){
        let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=texture;p.colorAttachments[0].loadAction = .clear;p.colorAttachments[0].storeAction = .store
        p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);command.makeRenderCommandEncoder(descriptor:p)?.endEncoding()
    }
    private func fullscreen(command:MTLCommandBuffer,pipeline:MTLRenderPipelineState,destination:MTLTexture,
                            textures:[MTLTexture],extra:((MTLRenderCommandEncoder)->Void)?=nil){
        let p=MTLRenderPassDescriptor();p.colorAttachments[0].texture=destination;p.colorAttachments[0].loadAction = .dontCare;p.colorAttachments[0].storeAction = .store
        guard let e=command.makeRenderCommandEncoder(descriptor:p)else{return}
        e.setRenderPipelineState(pipeline)
        for (i,t) in textures.enumerated(){e.setFragmentTexture(t,index:i)}
        e.setFragmentBytes(&uniforms,length:MemoryLayout<PhosphorUniforms>.stride,index:1)
        extra?(e);e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);e.endEncoding()
    }
}
