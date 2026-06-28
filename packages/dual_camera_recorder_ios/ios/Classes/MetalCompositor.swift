import CoreVideo
import Metal
import simd

/// Layout geometry from Dart, applied identically to preview / video / photo.
struct CompositeLayout {
    var pictureInPicture: Bool
    var primaryFront: Bool
    var insetRect: CGRect   // normalized, origin top-left
    var cornerRadiusPx: Float
    var mirrorFront: Bool
    var splitVertical: Bool
}

private struct QuadUniforms {
    var mvp: simd_float4x4
    var mirror: Float
    var rounded: Float
    var quadSizePx: simd_float2
    var cornerRadiusPx: Float
    var _pad: Float = 0
    var yuvMatrix: simd_float3x3
    var yuvOffset: simd_float3
}

/// The unified Metal compositor (ARCHITECTURE.md §5.2). Zero-copy in via
/// `CVMetalTextureCache`; composes two biplanar-YUV camera buffers into one
/// BGRA/IOSurface-backed `CVPixelBuffer` from a pool — the single buffer feeds
/// both the writer and the Flutter texture.
final class MetalCompositor {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool!
    let width: Int
    let height: Int

    // BT.709 limited-range YCbCr -> RGB.
    private let yuvMatrix = simd_float3x3(columns: (
        simd_float3(1.1644, 1.1644, 1.1644),
        simd_float3(0.0, -0.2132, 2.1124),
        simd_float3(1.7927, -0.5329, 0.0)
    ))
    private let yuvOffset = simd_float3(-0.0627, -0.5, -0.5)

    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: MetalCompositor.self)),
              let vfn = library.makeFunction(name: "dcr_vertex"),
              let ffn = library.makeFunction(name: "dcr_fragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pipeline

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    /// Compose primary (full-frame) + secondary (inset/half) into one BGRA buffer.
    func compose(
        primary: CVPixelBuffer,
        secondary: CVPixelBuffer?,
        layout: CompositeLayout
    ) -> CVPixelBuffer? {
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let out = outBuffer,
              let target = metalTexture(from: out, plane: 0, format: .bgra8Unorm) else {
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipeline)

        let primaryMirror = layout.primaryFront && layout.mirrorFront
        drawFeed(enc, buffer: primary, mvp: matrix_identity_float4x4,
                 mirror: primaryMirror, rounded: false, quadPx: simd_float2(Float(width), Float(height)), radius: 0)

        if let secondary = secondary {
            let secMirror = !layout.primaryFront && layout.mirrorFront
            let rect = layout.pictureInPicture ? layout.insetRect : halfRect(layout)
            let mvp = mvpFor(rect: rect)
            let quadPx = simd_float2(Float(rect.width) * Float(width), Float(rect.height) * Float(height))
            drawFeed(enc, buffer: secondary, mvp: mvp, mirror: secMirror,
                     rounded: layout.pictureInPicture && layout.cornerRadiusPx > 0,
                     quadPx: quadPx, radius: layout.cornerRadiusPx)
        }

        enc.endEncoding()
        cmd.commit() // async — never waitUntilCompleted on the hot path (§9)
        return out
    }

    private func drawFeed(
        _ enc: MTLRenderCommandEncoder,
        buffer: CVPixelBuffer,
        mvp: simd_float4x4,
        mirror: Bool,
        rounded: Bool,
        quadPx: simd_float2,
        radius: Float
    ) {
        guard let luma = metalTexture(from: buffer, plane: 0, format: .r8Unorm),
              let chroma = metalTexture(from: buffer, plane: 1, format: .rg8Unorm) else { return }
        enc.setFragmentTexture(luma, index: 0)
        enc.setFragmentTexture(chroma, index: 1)
        var u = QuadUniforms(
            mvp: mvp, mirror: mirror ? 1 : 0, rounded: rounded ? 1 : 0,
            quadSizePx: quadPx, cornerRadiusPx: radius,
            yuvMatrix: yuvMatrix, yuvOffset: yuvOffset
        )
        enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func metalTexture(
        from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat
    ) -> MTLTexture? {
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format, max(w, 1), max(h, 1), plane, &cvTex)
        guard status == kCVReturnSuccess, let cvTex = cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Map a normalized rect (top-left origin) to an NDC scale+translate matrix.
    private func mvpFor(rect: CGRect) -> simd_float4x4 {
        let sx = Float(rect.width)
        let sy = Float(rect.height)
        let cx = Float(rect.midX) * 2 - 1
        let cy = 1 - Float(rect.midY) * 2
        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(sx, 0, 0, 0)
        m.columns.1 = simd_float4(0, sy, 0, 0)
        m.columns.3 = simd_float4(cx, cy, 0, 1)
        return m
    }

    private func halfRect(_ layout: CompositeLayout) -> CGRect {
        layout.splitVertical
            ? CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            : CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    }
}
