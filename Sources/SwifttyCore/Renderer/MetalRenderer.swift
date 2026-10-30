import CoreGraphics
import CoreText
import Dispatch
import Foundation
import Metal
import MetalKit
import QuartzCore

/// Per-frame presentation settings that are not terminal state.
public struct RenderOptions: Equatable, Sendable {
  /// Grid inset from the drawable's top-left, in pixels.
  public var paddingX: CGFloat = 8
  public var paddingY: CGFloat = 8
  /// Content is drawn this many pixels higher (smooth scrolling); rows
  /// revealed below come from the snapshot's overscan rows.
  public var scrollOffset: CGFloat = 0
  /// Alpha of the default background (window transparency), clamped to
  /// 0...1. NaN uses the opaque default.
  public var backgroundOpacity: Double = 1
  public var isFocused = true
  /// Draw the cursor this frame (blink phase).
  public var cursorVisible = true
  /// Overrides the terminal's DECSCUSR style; `hollowBlock` is also used
  /// for any block cursor while unfocused.
  public var cursorStyle: CursorStyle?
  public var hollowCursor = false
  public var cursorColor: UInt32?
  public var cursorTextColor: UInt32?
  public var cursorOpacity: Double = 1
  /// Selection colours; with both nil the selection inverts.
  public var selectionForeground: UInt32?
  public var selectionBackground: UInt32?
  public var searchForeground: UInt32 = 0x000000
  public var searchBackground: UInt32 = 0xFFE082
  public var selectedSearchBackground: UInt32 = 0xF2A65A
  /// OSC 8 link id to underline (the one under the pointer), 0 for none.
  public var hoveredLink: UInt8 = 0
  /// Cells to underline, in snapshot rows (a detected URL under the pointer).
  public var underlinedSpan: HighlightSpan?
  /// IME composition text, drawn underlined from the cursor.
  public var preedit: [Unicode.Scalar] = []
  /// Selection in the composition, in UTF-16 units; an empty range draws
  /// a caret. Nil retains the text-only composition presentation.
  public var preeditSelection: NSRange?
  /// Blink phase for SGR 5 text; false hides it. Toggling it does not
  /// rebuild any cells.
  public var textBlinkVisible = true
  /// Minimum WCAG contrast ratio between text and its background (1...21);
  /// text below it is drawn in black or white (Ghostty's `minimum-contrast`).
  public var minimumContrast: Double = 1
  /// Reduce Motion: a custom shader's `time` stays at zero, so it draws a
  /// static frame and never keeps the host animating.
  public var reducesMotion = false

  public init() {}
}

/// Draws `RenderSnapshot`s with Metal.
///
/// Cell instances live in one persistent shared buffer laid out row by row;
/// only rows the snapshot marks dirty (plus rows the cursor enters/leaves)
/// are rebuilt. Glyphs are rasterized once with CoreText into an atlas.
/// Use from a single thread (normally the main thread).
public final class MetalRenderer {
  struct CellInstance {
    var gridX: UInt32
    var gridY: UInt32
    var atlasPos: SIMD2<UInt16>
    var atlasSize: SIMD2<UInt16>
    var offset: SIMD2<Int16>
    var fg: UInt32
    var bg: UInt32
    var flags: UInt32
    var underline: UInt32
  }

  struct Uniforms {
    var cellSize: SIMD2<Float>
    var viewportSize: SIMD2<Float>
    var atlasSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var underlinePosition: Float
    var underlineThickness: Float
    var cursorColor: UInt32
    var blinkHidden: UInt32 = 0
  }

  /// Decoration quads per cell: underline, strike, cursor, three more
  /// edges for a hollow cursor, and overline.
  static let decorationSlots = 7

  enum Flag {
    static let colorGlyph: UInt32 = 1 << 0
    static let underline: UInt32 = 1 << 1
    static let doubleUnderline: UInt32 = 1 << 2
    static let strike: UInt32 = 1 << 3
    static let overline: UInt32 = 1 << 4
    static let cursorBar: UInt32 = 1 << 5
    static let cursorUnderline: UInt32 = 1 << 6
    static let faint: UInt32 = 1 << 7
    static let cursorHollow: UInt32 = 1 << 8
    static let curly: UInt32 = 1 << 9
    static let dotted: UInt32 = 1 << 10
    static let dashed: UInt32 = 1 << 11
    static let blink: UInt32 = 1 << 12
    static let cursorRight: UInt32 = 1 << 13
  }

  public let device: MTLDevice
  public private(set) var font: ResolvedFont
  private let fontManager: CoreTextFontManager
  private let queue: MTLCommandQueue
  private let backgroundPipeline: MTLRenderPipelineState
  private let glyphPipeline: MTLRenderPipelineState
  private let decorationPipeline: MTLRenderPipelineState
  private var atlas: GlyphAtlas
  private var shaper = Shaper()

  var makeInstanceBuffer: (Int) -> MTLBuffer?
  var makeCommandBuffer: () -> MTLCommandBuffer?
  var makeIntermediateTexture: (MTLTextureDescriptor) -> MTLTexture?
  var makeRenderEncoder:
    (MTLCommandBuffer, MTLRenderPassDescriptor) -> MTLRenderCommandEncoder? = {
      $0.makeRenderCommandEncoder(descriptor: $1)
    }

  private var instances: MTLBuffer?
  private var gridSize = (columns: 0, rows: 0)
  private var lastCursor: CursorState?
  private var lastOptions = RenderOptions()
  private var lastSequence: UInt64 = 0
  private var lastSource: SnapshotSource?
  private var needsFullRebuild = true
  let inFlight = DispatchSemaphore(value: 1)
  /// Rows whose cells include SGR 5 text, as last built.
  private var blinkingRows: [Bool] = []
  private var postProcess: PostProcess?
  private let startTime = CACurrentMediaTime()

  /// Whether the last frame had blinking text, so the host knows to keep
  /// toggling `RenderOptions.textBlinkVisible`.
  public var hasBlinkingText: Bool { blinkingRows.contains(true) }

  /// Whether a custom post-processing shader animates (uses `time`), so
  /// the host keeps drawing.
  public var isAnimating: Bool {
    !options.reducesMotion && postProcess?.usesTime == true
  }

  /// Padding around the grid, in pixels (`RenderOptions` overrides it).
  public var padding: CGFloat = 8 {
    didSet {
      options.paddingX = padding;
      options.paddingY = padding
    }
  }

  /// Settings used by the `draw`/`render` calls without explicit options.
  public var options = RenderOptions()

  /// Pixel size of one cell.
  public var cellSize: CGSize {
    CGSize(width: font.cellWidth, height: font.cellHeight)
  }

  public convenience init(
    device: MTLDevice,
    fontManager: CoreTextFontManager,
    font descriptor: FontDescriptor
  ) throws {
    try self.init(
      device: device,
      fontManager: fontManager,
      font: descriptor,
      atlasSize: 2048,
      atlasMaximumSize: 8192
    )
  }

  init(
    device: MTLDevice,
    fontManager: CoreTextFontManager,
    font descriptor: FontDescriptor,
    atlasSize: Int,
    atlasMaximumSize: Int,
  ) throws {
    self.device = device
    makeInstanceBuffer = {
      device.makeBuffer(length: $0, options: .storageModeShared)
    }
    makeIntermediateTexture = { device.makeTexture(descriptor: $0) }
    self.fontManager = fontManager
    font = fontManager.resolve(descriptor)
    guard let queue = device.makeCommandQueue() else {
      throw RendererError.setup("command queue")
    }
    self.queue = queue
    makeCommandBuffer = { queue.makeCommandBuffer() }

    guard
      let url = Bundle.module.url(
        forResource: "Shaders",
        withExtension: "metal"
      )
    else { throw RendererError.setup("Shaders.metal missing from bundle") }
    let library = try device.makeLibrary(
      source: String(contentsOf: url, encoding: .utf8),
      options: nil
    )
    func pipeline(
      _ vertex: String,
      _ fragment: String,
      blending: Bool = true
    ) throws -> MTLRenderPipelineState {
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = library.makeFunction(name: vertex)
      d.fragmentFunction = library.makeFunction(name: fragment)
      let attachment = d.colorAttachments[0]!
      attachment.pixelFormat = .bgra8Unorm
      attachment.isBlendingEnabled = blending
      attachment.sourceRGBBlendFactor = .one
      attachment.sourceAlphaBlendFactor = .one
      attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      return try device.makeRenderPipelineState(descriptor: d)
    }
    // Backgrounds replace the clear color; blending them over the same
    // translucent background would apply the opacity a second time.
    backgroundPipeline = try pipeline(
      "background_vertex",
      "solid_fragment",
      blending: false
    )
    glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
    decorationPipeline = try pipeline(
      "decoration_vertex",
      "decoration_fragment"
    )
    atlas = try GlyphAtlas(
      device: device,
      size: atlasSize,
      maximumSize: atlasMaximumSize
    )
  }

  public func setFont(_ descriptor: FontDescriptor) {
    font = fontManager.resolve(descriptor)
    atlas.reset()
    shaper = Shaper()
    needsFullRebuild = true
  }

  /// Grid dimensions that fit a drawable of `size` pixels.
  public func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
    func dimension(_ available: CGFloat, cell: CGFloat) -> Int {
      let count = available / cell
      guard count > 1 else { return 1 }
      // PTY dimensions use 16-bit coordinates; snapshots may be larger.
      // Clamp before conversion, including a positive infinite size.
      return Int(min(count, CGFloat(UInt16.max)))
    }
    return (
      dimension(size.width - 2 * options.paddingX, cell: font.cellWidth),
      dimension(size.height - 2 * options.paddingY, cell: font.cellHeight),
    )
  }

  /// Renders into the view's current drawable and presents it.
  @MainActor
  @discardableResult
  public func draw(_ snapshot: RenderSnapshot, in view: MTKView) -> Bool {
    guard let drawable = view.currentDrawable,
      let pass = view.currentRenderPassDescriptor
    else { return false }
    guard
      let commandBuffer = try? encode(
        snapshot,
        options: options,
        pass: pass,
        size: view.drawableSize
      )
    else { return false }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    return true
  }

  /// Outcome of a nonblocking submission.
  public enum SubmitResult: Sendable, Equatable {
    case submitted
    /// The previous frame's GPU work still owns the instance buffer.
    case busy
    case noDrawable
    case resourceUnavailable
  }

  /// Like `draw(_:in:)` but never waits for in-flight GPU work. Only a
  /// `.submitted` result means the snapshot is being presented; on
  /// any other result keep it pending and retry later.
  @MainActor
  public func tryDraw(
    _ snapshot: RenderSnapshot,
    in view: MTKView
  ) -> SubmitResult {
    guard inFlight.wait(timeout: .now()) == .success else { return .busy }
    guard let drawable = view.currentDrawable,
      let pass = view.currentRenderPassDescriptor
    else {
      inFlight.signal()
      return .noDrawable
    }
    guard
      let commandBuffer = try? encode(
        snapshot,
        options: options,
        pass: pass,
        size: view.drawableSize,
        acquired: true
      )
    else { return .resourceUnavailable }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    return .submitted
  }

  /// Renders into the layer's next drawable and presents it. Returns false
  /// when no drawable or rendering resources were available.
  @discardableResult
  public func draw(
    _ snapshot: RenderSnapshot,
    options: RenderOptions,
    layer: CAMetalLayer
  ) -> Bool {
    guard let drawable = layer.nextDrawable() else { return false }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].storeAction = .store
    let size = CGSize(
      width: drawable.texture.width,
      height: drawable.texture.height
    )
    guard
      let commandBuffer = try? encode(
        snapshot,
        options: options,
        pass: pass,
        size: size
      )
    else { return false }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    return true
  }

  /// Blocks until every submitted frame has finished, or `timeout`.
  public func waitUntilIdle(timeout: DispatchTime) -> Bool {
    guard inFlight.wait(timeout: timeout) == .success else { return false }
    inFlight.signal()
    return true
  }

  /// Renders into an arbitrary BGRA texture (offscreen, tests, benchmarks).
  /// Throws when resources cannot be allocated; no GPU work is submitted.
  @discardableResult
  public func render(
    _ snapshot: RenderSnapshot,
    to texture: MTLTexture
  ) throws -> MTLCommandBuffer {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let commandBuffer = try encode(
      snapshot,
      options: options,
      pass: pass,
      size: CGSize(width: texture.width, height: texture.height)
    )
    commandBuffer.commit()
    return commandBuffer
  }

  private func encode(
    _ snapshot: RenderSnapshot,
    options: RenderOptions,
    pass: MTLRenderPassDescriptor,
    size: CGSize,
    acquired: Bool = false,
  ) throws -> MTLCommandBuffer {
    // The instance buffer is about to be mutated.
    if !acquired { inFlight.wait() }
    var encoded = false
    defer {
      if !encoded {
        needsFullRebuild = true
        inFlight.signal()
      }
    }
    let palette = effectivePalette(snapshot)
    let bg = palette.background
    let alpha = Double(Self.backgroundAlpha(options.backgroundOpacity)) / 255
    // Premultiplied, matching the blend state.
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(bg >> 16 & 0xFF) / 255 * alpha,
      green: Double(bg >> 8 & 0xFF) / 255 * alpha,
      blue: Double(bg & 0xFF) / 255 * alpha,
      alpha: alpha,
    )
    pass.colorAttachments[0].loadAction = .clear

    try updateInstances(snapshot, palette: palette, options: options)
    if atlas.needsFrameRetry {
      // Previous GPU work has finished and this frame is not encoded yet.
      // Rebuild once with an empty atlas so old glyphs cannot hide new text
      // until a later draw. The retry stays bounded for oversized frames.
      atlas.reset()
      needsFullRebuild = true
      try updateInstances(snapshot, palette: palette, options: options)
    }
    let cursorColor = options.cursorColor ?? palette.cursor
    let cursorAlpha: UInt32 =
      !options.preedit.isEmpty && options.preeditSelection != nil
      ? 255 : UInt32(max(0, min(1, options.cursorOpacity)) * 255)

    guard let commandBuffer = makeCommandBuffer() else {
      throw RendererError.resourceUnavailable("command buffer")
    }
    // With a post-processing shader the grid is drawn offscreen first.
    let target = pass.colorAttachments[0].texture
    let intermediate: MTLTexture?
    if let target, let postProcess {
      guard
        let texture = postProcess.intermediate(
          matching: target,
          device: device,
          allocate: makeIntermediateTexture
        )
      else { throw RendererError.resourceUnavailable("postprocess texture") }
      intermediate = texture
    } else {
      intermediate = nil
    }
    defer {
      if intermediate != nil { pass.colorAttachments[0].texture = target }
    }
    if let intermediate {
      pass.colorAttachments[0].texture = intermediate
      pass.colorAttachments[0].storeAction = .store
    }
    guard let encoder = makeRenderEncoder(commandBuffer, pass) else {
      if let target { pass.colorAttachments[0].texture = target }
      throw RendererError.resourceUnavailable("render encoder")
    }
    var uniforms = Uniforms(
      cellSize: SIMD2(Float(font.cellWidth), Float(font.cellHeight)),
      viewportSize: SIMD2(Float(size.width), Float(size.height)),
      atlasSize: SIMD2(Float(atlas.size), Float(atlas.size)),
      origin: SIMD2(
        Float(options.paddingX),
        Float(options.paddingY - options.scrollOffset)
      ),
      underlinePosition: Float(font.underlinePosition),
      underlineThickness: Float(font.underlineThickness),
      cursorColor: cursorColor << 8 | cursorAlpha,
      blinkHidden: options.textBlinkVisible ? 0 : 1,
    )
    let count = snapshot.columns * snapshot.rowCount
    if let instances, count > 0 {
      encoder.setVertexBuffer(instances, offset: 0, index: 0)
      encoder.setVertexBytes(
        &uniforms,
        length: MemoryLayout<Uniforms>.stride,
        index: 1
      )
      encoder.setRenderPipelineState(backgroundPipeline)
      encoder.drawPrimitives(
        type: .triangleStrip,
        vertexStart: 0,
        vertexCount: 4,
        instanceCount: count
      )
      encoder.setRenderPipelineState(glyphPipeline)
      encoder.setFragmentTexture(atlas.texture, index: 0)
      encoder.drawPrimitives(
        type: .triangleStrip,
        vertexStart: 0,
        vertexCount: 4,
        instanceCount: count
      )
      encoder.setRenderPipelineState(decorationPipeline)
      encoder.drawPrimitives(
        type: .triangleStrip,
        vertexStart: 0,
        vertexCount: 4,
        instanceCount: count * Self.decorationSlots
      )
    }
    encoder.endEncoding()
    if let intermediate, let target, let postProcess {
      try postProcess.encode(
        from: intermediate,
        to: target,
        commandBuffer: commandBuffer,
        time: options.reducesMotion
          ? 0 : Float(CACurrentMediaTime() - startTime),
        makeEncoder: makeRenderEncoder,
      )
    }
    commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
    encoded = true
    return commandBuffer
  }

  /// Installs a post-processing fragment shader (Metal source), or removes
  /// it with nil. See `PostProcess` for the function it must define.
  public func setPostProcessShader(_ source: String?) throws {
    postProcess = try source.map { try PostProcess(device: device, source: $0) }
  }

  private func effectivePalette(_ snapshot: RenderSnapshot) -> Palette {
    var palette = snapshot.palette
    if snapshot.modes.contains(.reverseVideo) {
      swap(&palette.foreground, &palette.background)
    }
    return palette
  }

  /// Use the same quantized alpha for the clear color and cell instances.
  private static func backgroundAlpha(_ opacity: Double) -> UInt32 {
    let normalized = opacity.isNaN ? 1 : max(0, min(1, opacity))
    return UInt32(normalized * 255)
  }

  // MARK: Instances

  static func instanceBufferLength(
    columns: Int,
    rows: Int,
    maximum: Int
  ) throws -> Int {
    guard columns > 0, rows > 0, columns - 1 <= Int(UInt32.max),
      rows - 1 <= Int(UInt32.max)
    else { throw RendererError.invalidDimensions }
    let (count, countOverflow) = columns.multipliedReportingOverflow(by: rows)
    guard !countOverflow, count <= Int(UInt32.max) / decorationSlots else {
      throw RendererError.invalidDimensions
    }
    let (length, byteOverflow) = count.multipliedReportingOverflow(
      by: MemoryLayout<CellInstance>.stride
    )
    guard !byteOverflow, length <= maximum else {
      throw RendererError.resourceUnavailable("instance buffer size")
    }
    return length
  }

  private func updateInstances(
    _ snapshot: RenderSnapshot,
    palette: Palette,
    options: RenderOptions
  ) throws {
    atlas.prepareForFrame()
    let columns = snapshot.columns
    let rows = snapshot.rowCount
    let length = try Self.instanceBufferLength(
      columns: columns,
      rows: rows,
      maximum: device.maxBufferLength
    )
    // Cursor opacity animates every frame; it only touches the cursor row.
    // The text blink phase is a uniform.
    var comparable = options
    comparable.cursorOpacity = lastOptions.cursorOpacity
    comparable.textBlinkVisible = lastOptions.textBlinkVisible
    // A skipped snapshot (no drawable that frame) carried damage these
    // instances never saw.
    let skipped =
      snapshot.sequence != lastSequence
      && snapshot.sequence != lastSequence &+ 1
    var full =
      needsFullRebuild || snapshot.damage.isFull || comparable != lastOptions
      || skipped || atlas.wasReset || lastSource !== snapshot.source
    atlas.wasReset = false
    if gridSize != (columns, rows) || instances == nil {
      if (instances?.length ?? 0) < length {
        guard let replacement = makeInstanceBuffer(length) else {
          throw RendererError.resourceUnavailable("instance buffer")
        }
        instances = replacement
      }
      gridSize = (columns, rows)
      full = true
    }
    if blinkingRows.count != rows {
      blinkingRows = Array(repeating: false, count: rows)
    }
    var cursor = snapshot.cursor
    cursor.isVisible = cursor.isVisible && options.cursorVisible
    // A palette change (OSC 4/10/11) arrives as full damage from the core.
    if snapshot.sequence == lastSequence, !full, lastCursor == cursor,
      options.cursorOpacity == lastOptions.cursorOpacity
    {
      return
    }

    let base = instances!.contents()
      .bindMemory(to: CellInstance.self, capacity: columns * rows)
    let previous = lastCursor
    let rowRecords = snapshot.rows
    let composing = !options.preedit.isEmpty && snapshot.viewportOffset == 0
    for y in 0 ..< rows {
      let cursorRow =
        ((cursor.isVisible || composing) && cursor.y == y)
        || ((previous?.isVisible == true || composing) && previous?.y == y)
      guard full || rowRecords[y].isDirty || cursorRow else { continue }
      buildRow(
        y,
        snapshot: snapshot,
        cursor: cursor,
        palette: palette,
        options: options,
        into: base + y * columns
      )
    }
    lastCursor = cursor
    lastOptions = options
    lastSequence = snapshot.sequence
    lastSource = snapshot.source
    needsFullRebuild = false
  }

  private static func applyCursor(
    style: CursorStyle,
    options: RenderOptions,
    palette: Palette,
    foreground fg: inout UInt32,
    background bg: inout UInt32,
    alpha bgAlpha: inout UInt32,
    flags: inout UInt32
  ) {
    switch options.cursorStyle ?? style {
    case .block where options.hollowCursor || !options.isFocused:
      flags |= Flag.cursorHollow
    case .block:
      // Blend so cursor opacity (and its animations) shows the cell beneath.
      let t = max(0, min(1, options.cursorOpacity))
      let cellBg = bg
      fg = Self.mix(
        fg,
        options.cursorTextColor ?? palette.cursorText ?? cellBg,
        t
      )
      (bg, bgAlpha) = Self.composite(
        options.cursorColor ?? palette.cursor,
        opacity: t,
        over: cellBg,
        alpha: bgAlpha
      )
    case .bar: flags |= Flag.cursorBar
    case .underline: flags |= Flag.cursorUnderline
    }
  }

  private static func preeditSelection(
    _ options: RenderOptions,
    at column: Int
  ) -> Range<Int>? {
    options.preeditSelection.map { range in
      let length = options.preedit.reduce(0) { $0 + $1.utf16.count }
      let start = min(length, max(0, range.location))
      let end = start + min(length - start, max(0, range.length))
      let first = TerminalGeometry.compositionColumn(
        in: options.preedit,
        atUTF16Offset: start
      )
      let last = TerminalGeometry.compositionColumn(
        in: options.preedit,
        atUTF16Offset: end,
        roundUp: end > start
      )
      return (column + first) ..< (column + last)
    }
  }

  private static func underlineColor(
    _ attributes: CellAttributes,
    snapshot: borrowing RenderSnapshot,
    palette: Palette
  ) -> UInt32 {
    var underline: UInt32 = 0
    if attributes.underlineColor != 0,
      Int(attributes.underlineColor) <= snapshot.underlineColors.count
    {
      underline =
        palette.resolve(
          snapshot.underlineColors[Int(attributes.underlineColor) - 1],
          isForeground: true
        ) << 8 | 0xFF
    }
    return underline
  }

  private func buildRow(
    _ y: Int,
    snapshot: RenderSnapshot,
    cursor: CursorState,
    palette: Palette,
    options: RenderOptions,
    into out: UnsafeMutablePointer<CellInstance>,
  ) {
    let cells = snapshot.cells(row: y)
    let backgroundAlpha = Self.backgroundAlpha(options.backgroundOpacity)
    let selection = snapshot.selection
    let matches = snapshot.searchMatches
    let selectedMatch = snapshot.selectedSearchMatch.flatMap {
      matches.indices.contains($0) ? matches[$0] : nil
    }
    let searchHighlights = Self.searchHighlights(
      matches,
      row: y,
      columns: cells.count
    )
    let hasPreedit =
      snapshot.viewportOffset == 0 && y == cursor.y && !options.preedit.isEmpty
    let preedit =
      hasPreedit
      ? Self.layoutPreedit(options.preedit, at: cursor.x, columns: cells.count)
      : [:]
    let preeditSelection =
      hasPreedit ? Self.preeditSelection(options, at: cursor.x) : nil
    // Break at the cursor whatever its blink phase, so ligatures don't flicker.
    let shaped =
      font.shapes
      ? shapeRow(
        cells,
        cursorX: snapshot.cursor.isVisible && cursor.y == y ? cursor.x : -1,
        skip: preedit
      ) : []
    let selectionForeground =
      options.selectionForeground ?? palette.selectionForeground
    let selectionBackground =
      options.selectionBackground ?? palette.selectionBackground
    var blinks = false
    for x in 0 ..< cells.count {
      let originalCell = cells[x]
      var cell = originalCell
      if let p = preedit[x] {
        cell = p.cell
      } else if originalCell.width == 2, preedit[x + 1] != nil {
        // A wide glyph is drawn from its first cell. Hide it when
        // composition starts over its tail, keeping the row intact.
        cell = TerminalState.narrowed(originalCell)
      }
      let attrs = cell.attributes
      var fg = palette.resolve(attrs.foreground, isForeground: true)
      var bg = palette.resolve(attrs.background, isForeground: false)
      // Default backgrounds take the window opacity; explicit ones stay solid.
      var bgAlpha = attrs.background == .default ? backgroundAlpha : 0xFF
      if attrs.flags.contains(.inverse) {
        swap(&fg, &bg)
        bgAlpha = 0xFF
      }
      let isSelectedMatch = selectedMatch?.contains(row: y, column: x) == true
      if isSelectedMatch || (!searchHighlights.isEmpty && searchHighlights[x]) {
        fg = options.searchForeground
        bg =
          isSelectedMatch
          ? options.selectedSearchBackground : options.searchBackground
        bgAlpha = 0xFF
      }
      if Self.isSelected(selection, row: y, column: x, cells: cells)
        || (preedit[x] != nil && preeditSelection?.contains(x) == true)
      {
        if selectionForeground == nil, selectionBackground == nil {
          swap(&fg, &bg)
        } else {
          fg = selectionForeground ?? fg
          bg = selectionBackground ?? bg
        }
        bgAlpha = 0xFF
      }
      if options.minimumContrast > 1 {
        fg = Self.ensureContrast(fg, on: bg, ratio: options.minimumContrast)
      }
      var flags =
        attrs.flags.contains(.invisible) ? 0 : Self.decorationFlags(attrs.flags)
      let underline = Self.underlineColor(
        attrs,
        snapshot: snapshot,
        palette: palette
      )
      blinks = blinks || attrs.flags.contains(.blink)

      Self.applyInteractionFlags(
        attributes: attrs,
        row: y,
        column: x,
        columns: cells.count,
        isPreedit: preedit[x] != nil,
        preeditSelection: preeditSelection,
        options: options,
        flags: &flags
      )
      if cursor.isVisible, !hasPreedit, cursor.y == y, cursor.x == x {
        Self.applyCursor(
          style: cursor.style,
          options: options,
          palette: palette,
          foreground: &fg,
          background: &bg,
          alpha: &bgAlpha,
          flags: &flags
        )
      }

      let entry = glyphEntry(
        for: cell,
        shaped: shaped.isEmpty ? nil : shaped[x],
        preedit: preedit[x],
        snapshot: snapshot,
      )
      if entry.isColor { flags |= Flag.colorGlyph }
      out[x] = CellInstance(
        gridX: UInt32(x),
        gridY: UInt32(y),
        atlasPos: entry.position,
        atlasSize: entry.size,
        offset: entry.offset,
        fg: fg << 8 | 0xFF,
        bg: bg << 8 | bgAlpha,
        flags: flags,
        underline: underline,
      )
    }
    if y < blinkingRows.count { blinkingRows[y] = blinks }
  }
}

extension MetalRenderer {
  private static func applyInteractionFlags(
    attributes: CellAttributes,
    row: Int,
    column: Int,
    columns: Int,
    isPreedit: Bool,
    preeditSelection: Range<Int>?,
    options: RenderOptions,
    flags: inout UInt32
  ) {
    if isPreedit { flags |= Flag.underline }
    if options.hoveredLink != 0, attributes.link == options.hoveredLink {
      flags |= Flag.underline
    }
    if let span = options.underlinedSpan,
      span.contains(row: row, column: column)
    {
      flags |= Flag.underline
    }
    if let range = preeditSelection, range.isEmpty, options.isFocused {
      let caret = min(columns, range.lowerBound)
      if caret == column {
        flags |= Flag.cursorBar
      } else if caret == columns, column == columns - 1 {
        flags |= Flag.cursorRight
      }
    }
  }

  /// Resolve the row's glyph sources in presentation order. Shaped runs
  /// already contain positioned atlas entries; other cells use preedit,
  /// snapshot graphemes, or a single scalar.
  private func glyphEntry(
    for cell: Cell,
    shaped: GlyphAtlas.Entry?,
    preedit: PreeditCell?,
    snapshot: borrowing RenderSnapshot,
  ) -> GlyphAtlas.Entry {
    guard !cell.attributes.flags.contains(.invisible) else { return .empty }
    if let shaped { return shaped }
    guard !cell.isSpacer, cell.glyph != 0 || cell.isGrapheme else {
      return .empty
    }
    let style = FontStyle(cell.attributes.flags)
    if let preedit, !preedit.cluster.isEmpty {
      return atlas.entry(cluster: preedit.cluster, style: style, font: font)
    }
    if cell.isGrapheme {
      let span = snapshot.graphemeScalars(cell)
      return atlas.entry(cluster: span, style: style, font: font)
    }
    guard cell.glyph != 0x20, let scalar = Unicode.Scalar(cell.glyph) else {
      return .empty
    }
    return atlas.entry(
      scalar: scalar,
      style: style,
      font: font,
      manager: fontManager
    )
  }

  /// Selecting either half of a wide character selects both rendered cells.
  private static func isSelected(
    _ selection: HighlightSpan?,
    row: Int,
    column: Int,
    cells: Span<Cell>
  ) -> Bool {
    guard let selection else { return false }
    if selection.contains(row: row, column: column) { return true }
    let cell = cells[column]
    if cell.width == 2, column + 1 < cells.count {
      return selection.contains(row: row, column: column + 1)
    }
    if cell.flags.contains(.spacerTail), column > 0,
      cells[column - 1].width == 2
    {
      return selection.contains(row: row, column: column - 1)
    }
    return false
  }

  /// Search matches arrive ordered by start and end position. Find those
  /// intersecting this row, then paint their union once per cell.
  static func searchHighlights(
    _ matches: [HighlightSpan],
    row: Int,
    columns: Int
  ) -> [Bool] {
    guard columns > 0, !matches.isEmpty else { return [] }
    var lower = 0
    var upper = matches.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if matches[middle].endRow < row {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    guard lower < matches.count, matches[lower].startRow <= row else {
      return []
    }
    var highlights = [Bool](repeating: false, count: columns)
    var paintedThrough = 0
    for i in lower ..< matches.count {
      let match = matches[i]
      if match.startRow > row { break }
      let start = row == match.startRow ? match.startColumn : 0
      let end = min(
        columns - 1,
        row == match.endRow ? match.endColumn : columns - 1
      )
      let first = max(paintedThrough, max(0, start))
      guard first <= end else { continue }
      for x in first ... end { highlights[x] = true }
      paintedThrough = end + 1
      if paintedThrough == columns { break }
    }
    return highlights
  }

  /// Atlas entries for runs of plain single-width cells, shaped together;
  /// nil where the cell takes the per-cell path. Runs break on attribute
  /// changes and at the cursor so a ligature never hides it.
  private func shapeRow(
    _ cells: Span<Cell>,
    cursorX: Int,
    skip: [Int: PreeditCell]
  ) -> [GlyphAtlas.Entry?] {
    var out = [GlyphAtlas.Entry?](repeating: nil, count: cells.count)
    func eligible(_ x: Int) -> Bool {
      let c = cells[x]
      return c.width == 1 && !c.isGrapheme && !c.isSpacer && c.glyph > 0x20
        && x != cursorX && skip[x] == nil && !BoxDrawing.covers(c.glyph)
    }
    var x = 0
    while x < cells.count {
      guard eligible(x) else {
        x += 1;
        continue
      }
      let attrs = cells[x].attributes
      var end = x + 1
      while end < cells.count, eligible(end), cells[end].attributes == attrs {
        end += 1
      }
      if end - x >= 2 {
        var scalars: [UInt32] = []
        scalars.reserveCapacity(end - x)
        for i in x ..< end { scalars.append(cells[i].glyph) }
        for i in x ..< end { out[i] = .empty }
        let style = FontStyle(attrs.flags)
        let glyphs = shaper.shape(scalars, style: style, font: font)
        var first = 0
        while first < glyphs.count {
          var last = first + 1
          while last < glyphs.count, glyphs[last].cell == glyphs[first].cell {
            last += 1
          }
          out[x + glyphs[first].cell] = atlas.entry(
            glyphs: glyphs[first ..< last],
            style: style,
            font: font
          )
          first = last
        }
      }
      x = end
    }
    return out
  }

  /// Shader flags for a cell's SGR decorations.
  static func decorationFlags(_ cellFlags: CellFlags) -> UInt32 {
    var flags: UInt32 = 0
    if cellFlags.contains(.underline) {
      flags |= Flag.underline
      switch (
        cellFlags.contains(.underlineStyleA),
        cellFlags.contains(.underlineStyleB)
      ) {
      case (true, true): flags |= Flag.dashed
      case (true, false): flags |= Flag.curly
      case (false, true): flags |= Flag.dotted
      case (false, false): break
      }
    }
    let simple: [(CellFlags, UInt32)] = [
      (.doubleUnderline, Flag.doubleUnderline), (.strikethrough, Flag.strike),
      (.overline, Flag.overline), (.faint, Flag.faint), (.blink, Flag.blink),
    ]
    for (cell, flag) in simple where cellFlags.contains(cell) { flags |= flag }
    return flags
  }

  /// `fg`, or black or white (whichever contrasts more) when `fg` falls
  /// below `ratio` against `bg`.
  static func ensureContrast(
    _ fg: UInt32,
    on bg: UInt32,
    ratio: Double
  ) -> UInt32 {
    let lb = luminance(bg)
    func contrast(_ l: Double) -> Double {
      (max(l, lb) + 0.05) / (min(l, lb) + 0.05)
    }
    guard contrast(luminance(fg)) < ratio else { return fg }
    return contrast(1) >= contrast(0) ? 0xFFFFFF : 0x000000
  }

  /// WCAG relative luminance of a 0xRRGGBB colour.
  static func luminance(_ rgb: UInt32) -> Double {
    func channel(_ v: UInt32) -> Double {
      let c = Double(v & 0xFF) / 255
      return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722
      * channel(rgb)
  }

  /// An opaque foreground fading over a background with byte alpha.
  /// Weight straight RGB by its share of the resulting alpha to match
  /// premultiplied GPU compositing.
  private static func composite(
    _ foreground: UInt32,
    opacity: Double,
    over background: UInt32,
    alpha: UInt32
  ) -> (UInt32, UInt32) {
    let blendedAlpha = Double(alpha) + (255 - Double(alpha)) * opacity
    let foregroundWeight = blendedAlpha > 0 ? 255 * opacity / blendedAlpha : 0
    return (mix(background, foreground, foregroundWeight), UInt32(blendedAlpha))
  }

  /// Linear blend of two 0xRRGGBB colours.
  static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    guard t < 1 else { return b }
    guard t > 0 else { return a }
    var out: UInt32 = 0
    for shift in [16, 8, 0] as [UInt32] {
      let x = Double(a >> shift & 0xFF)
      let y = Double(b >> shift & 0xFF)
      out |= UInt32((x + (y - x) * t).rounded()) << shift
    }
    return out
  }

  struct PreeditCell {
    var cell: Cell
    /// Composition clusters are independent of the snapshot's grapheme pool.
    var cluster: [UInt32] = []
  }

  /// Preedit graphemes as cells keyed by column, starting at `start`.
  static func layoutPreedit(
    _ scalars: [Unicode.Scalar],
    at start: Int,
    columns: Int
  ) -> [Int: PreeditCell] {
    guard start >= 0, start < columns else { return [:] }
    var cells: [Int: PreeditCell] = [:]
    let values = scalars.map(\.value)
    var x = start
    var offset = 0
    while offset < values.count {
      let (length, width) = GraphemeBreak.graphemeWidth(values[offset...])
      let w = max(1, width)
      guard w <= columns - x else { break }
      cells[x] = PreeditCell(
        cell: Cell(
          glyph: values[offset],
          attributes: .default,
          width: UInt8(w)
        ),
        cluster: length > 1 ? Array(values[offset ..< offset + length]) : [],
      )
      if w == 2 {
        cells[x + 1] = PreeditCell(
          cell: Cell(
            glyph: 0,
            attributes: CellAttributes(flags: .spacerTail),
            width: 0
          )
        )
      }
      x += w
      offset += length
    }
    return cells
  }
}

public enum RendererError: Error, Equatable {
  case setup(String)
  case resourceUnavailable(String)
  case invalidDimensions
}
