import Foundation

/// Swift and Metal share a 48-byte instance and a 32-byte temporal sample.
struct WaveGlyphInstance {
    var bounds: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var sampleRange: SIMD2<UInt32>
    var depth: Float = 0
    var reserved: Float = 0 // style: 1 dark ink, 0..<0.5 extra glow
}

struct WaveGlyphSample {
    var geometry: SIMD4<Float> // center.xy, size.xy
    var appearance: SIMD4<Float> // cos, sin, opacity, warmth

    init(_ pose: ReceiverFlightPose) {
        geometry = SIMD4(Float(pose.center.x), Float(pose.center.y), Float(pose.size.width), Float(pose.size.height))
        appearance = SIMD4(Float(cos(pose.rotation)), Float(sin(pose.rotation)), Float(pose.opacity), Float(pose.warmth))
    }
}

struct WaveGlyphTexture {
    let page: Int
    let uv: SIMD4<Float>
}

struct WaveGlyphDraw {
    var instance: WaveGlyphInstance
    let page: Int
}

