import Foundation
import Metal

/// A user post-processing pass (Ghostty's `custom-shader`, in Metal rather
/// than GLSL): the grid is drawn into an offscreen texture, then a
/// full-screen pass runs the user's function over it.
///
/// The source must define:
///
/// ```metal
/// float4 postprocess(float2 position, texture2d<float> source, constant PostUniforms &u);
/// ```
///
/// where `position` is the pixel being shaded (origin top-left), `source`
/// the rendered terminal (premultiplied BGRA), and `PostUniforms` holds
/// `float2 resolution` and `float time` (seconds since the renderer was
/// created). `<metal_stdlib>` is already included.
final class PostProcess {
  struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var pad: Float = 0
  }

  static let header = """
    #include <metal_stdlib>
    using namespace metal;
    struct PostUniforms { float2 resolution; float time; float pad; };

    """

  static let footer = """

    struct PostOut { float4 position [[position]]; };

    vertex PostOut post_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        PostOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    fragment float4 post_fragment(PostOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                  constant PostUniforms &u [[buffer(0)]]) {
        return postprocess(in.position.xy, source, u);
    }
    """

  let pipeline: MTLRenderPipelineState
  /// The shader may read `time`, so frames can change without new output.
  let usesTime: Bool
  private var texture: MTLTexture?

  init(device: MTLDevice, source: String) throws {
    let library = try device.makeLibrary(
      source: Self.header + source + Self.footer,
      options: nil
    )
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "post_vertex")
    d.fragmentFunction = library.makeFunction(name: "post_fragment")
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    pipeline = try device.makeRenderPipelineState(descriptor: d)
    // The compiler splices continued lines before recognizing comments
    // or identifiers, so a continuation can split `time` or extend a comment.
    let joined = source.replacingOccurrences(
      of: #"\\[ \t\x0B\x0C]*(?:\r\n|\n|\r)"#,
      with: "",
      options: .regularExpression,
    )
    // Comments are whitespace in Metal, including between a member
    // access operator and its identifier. Ignore commented-out accesses.
    let code = joined.replacingOccurrences(
      of: #"(?s)/\*.*?\*/|//[^\r\n]*"#,
      with: " ",
      options: .regularExpression,
    )
    // Macros, token pasting, and includes can hide a time access from
    // this scan. Keep those shaders moving rather than freezing them.
    let directTime =
      code.range(
        of: #"(?:\.|->)\s*time\b|(?m)^\s*#"#,
        options: .regularExpression
      ) != nil
    // Copies, function arguments and addresses of the uniforms can hide
    // a time read. Only direct resolution/pad reads are known to be static.
    let declarations = try NSRegularExpression(
      pattern: #"\bPostUniforms\s*(?:const\s*)?[&*]\s*([A-Za-z_]\w*)"#
    )
    let range = NSRange(code.startIndex..., in: code)
    let names = declarations.matches(in: code, range: range)
      .compactMap { match in
        Range(match.range(at: 1), in: code).map { String(code[$0]) }
      }
    let reads = declarations.stringByReplacingMatches(
      in: code,
      range: range,
      withTemplate: ""
    )
    // References and addresses can expose time through a resolution/pad
    // alias, even without a cast. Conservatively animate opaque memory
    // access after removing the ordinary uniform parameter declarations.
    // Binary bitwise AND does not take an address or create a reference.
    let memorySyntax =
      #"\b(?:reinterpret_cast|const_cast)\s*<|\b(?:constant|device|thread|threadgroup)\b[^;{}=]*[&*]"#
      + #"|(?:^|[({=,;?:!~]|\breturn)\s*&\s*[A-Za-z_(]"#
    let indirectMemory =
      reads.range(of: memorySyntax, options: .regularExpression) != nil
    let opaqueUniforms =
      names.isEmpty
      || names.contains { name in
        let identifier = NSRegularExpression.escapedPattern(for: name)
        let pattern =
          "\\b" + identifier + #"\b(?!\s*\.\s*(?:resolution|pad)\b)|&\s*\(*\s*"#
          + identifier + #"\b"#
        return reads.range(of: pattern, options: .regularExpression) != nil
      }
    usesTime = directTime || indirectMemory || opaqueUniforms
  }

  /// An offscreen texture the size of `target`, reused across frames.
  func intermediate(
    matching target: MTLTexture,
    device: MTLDevice
  ) -> MTLTexture? {
    if let texture, texture.width == target.width,
      texture.height == target.height
    {
      return texture
    }
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: target.width,
      height: target.height,
      mipmapped: false,
    )
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .private
    texture = device.makeTexture(descriptor: d)
    return texture
  }

  func encode(
    from source: MTLTexture,
    to target: MTLTexture,
    commandBuffer: MTLCommandBuffer,
    time: Float
  ) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
    else { return }
    var uniforms = Uniforms(
      resolution: SIMD2(Float(target.width), Float(target.height)),
      time: time
    )
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(source, index: 0)
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<Uniforms>.stride,
      index: 0
    )
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
  }
}
