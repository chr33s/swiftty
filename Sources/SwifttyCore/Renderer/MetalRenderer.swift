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
    /// Alpha of the default background (window transparency).
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
    /// IME composition text, drawn underlined from the cursor.
    public var preedit: [Unicode.Scalar] = []

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
        var grid: SIMD2<UInt16>
        var atlasPos: SIMD2<UInt16>
        var atlasSize: SIMD2<UInt16>
        var offset: SIMD2<Int16>
        var fg: UInt32
        var bg: UInt32
        var flags: UInt32
    }

    struct Uniforms {
        var cellSize: SIMD2<Float>
        var viewportSize: SIMD2<Float>
        var atlasSize: SIMD2<Float>
        var origin: SIMD2<Float>
        var underlinePosition: Float
        var underlineThickness: Float
        var cursorColor: UInt32
        var pad: UInt32 = 0
    }

    /// Decoration quads per cell: underline, strike/overline, cursor, and
    /// three more edges for a hollow cursor.
    static let decorationSlots = 6

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

    private var instances: MTLBuffer?
    private var gridSize = (columns: 0, rows: 0)
    private var lastCursor: CursorState?
    private var lastOptions = RenderOptions()
    private var lastSequence: UInt64 = 0
    private var needsFullRebuild = true
    private let inFlight = DispatchSemaphore(value: 1)

    /// Padding around the grid, in pixels (`RenderOptions` overrides it).
    public var padding: CGFloat = 8 {
        didSet { options.paddingX = padding; options.paddingY = padding }
    }

    /// Settings used by the `draw`/`render` calls without explicit options.
    public var options = RenderOptions()

    /// Pixel size of one cell.
    public var cellSize: CGSize {
        CGSize(width: font.cellWidth, height: font.cellHeight)
    }

    public init(device: MTLDevice, fontManager: CoreTextFontManager, font descriptor: FontDescriptor) throws {
        self.device = device
        self.fontManager = fontManager
        font = fontManager.resolve(descriptor)
        guard let queue = device.makeCommandQueue() else { throw RendererError.setup("command queue") }
        self.queue = queue

        guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal") else {
            throw RendererError.setup("Shaders.metal missing from bundle")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = d.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        backgroundPipeline = try pipeline("background_vertex", "solid_fragment")
        glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
        decorationPipeline = try pipeline("decoration_vertex", "solid_fragment")
        atlas = try GlyphAtlas(device: device)
    }

    public func setFont(_ descriptor: FontDescriptor) {
        font = fontManager.resolve(descriptor)
        atlas.reset()
        shaper = Shaper()
        needsFullRebuild = true
    }

    /// Grid dimensions that fit a drawable of `size` pixels.
    public func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        (
            max(1, Int((size.width - 2 * options.paddingX) / font.cellWidth)),
            max(1, Int((size.height - 2 * options.paddingY) / font.cellHeight)),
        )
    }

    /// Renders into the view's current drawable and presents it.
    @MainActor
    public func draw(_ snapshot: RenderSnapshot, in view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        let commandBuffer = encode(snapshot, options: options, pass: pass, size: view.drawableSize)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders into the layer's next drawable and presents it. Returns false
    /// when no drawable was available.
    @discardableResult
    public func draw(_ snapshot: RenderSnapshot, options: RenderOptions, layer: CAMetalLayer) -> Bool {
        guard let drawable = layer.nextDrawable() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].storeAction = .store
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let commandBuffer = encode(snapshot, options: options, pass: pass, size: size)
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

    /// Renders into an arbitrary texture (offscreen, tests, benchmarks).
    @discardableResult
    public func render(_ snapshot: RenderSnapshot, to texture: MTLTexture) -> MTLCommandBuffer {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commandBuffer = encode(snapshot, options: options, pass: pass, size: CGSize(width: texture.width, height: texture.height))
        commandBuffer.commit()
        return commandBuffer
    }

    private func encode(
        _ snapshot: RenderSnapshot,
        options: RenderOptions,
        pass: MTLRenderPassDescriptor,
        size: CGSize,
    ) -> MTLCommandBuffer {
        inFlight.wait() // the instance buffer is about to be mutated
        let palette = effectivePalette(snapshot)
        let bg = palette.background
        let alpha = options.backgroundOpacity
        // Premultiplied, matching the blend state.
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg >> 16 & 0xFF) / 255 * alpha, green: Double(bg >> 8 & 0xFF) / 255 * alpha,
            blue: Double(bg & 0xFF) / 255 * alpha, alpha: alpha,
        )
        pass.colorAttachments[0].loadAction = .clear

        updateInstances(snapshot, palette: palette, options: options)
        let cursorColor = options.cursorColor ?? palette.cursor
        let cursorAlpha = UInt32(max(0, min(1, options.cursorOpacity)) * 255)

        let commandBuffer = queue.makeCommandBuffer()!
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        var uniforms = Uniforms(
            cellSize: SIMD2(Float(font.cellWidth), Float(font.cellHeight)),
            viewportSize: SIMD2(Float(size.width), Float(size.height)),
            atlasSize: SIMD2(Float(atlas.size), Float(atlas.size)),
            origin: SIMD2(Float(options.paddingX), Float(options.paddingY - options.scrollOffset)),
            underlinePosition: Float(font.underlinePosition),
            underlineThickness: Float(font.underlineThickness),
            cursorColor: cursorColor << 8 | cursorAlpha,
        )
        let count = snapshot.columns * snapshot.rowCount
        if let instances, count > 0 {
            encoder.setVertexBuffer(instances, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            encoder.setRenderPipelineState(decorationPipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count * Self.decorationSlots)
        }
        encoder.endEncoding()
        return commandBuffer
    }

    private func effectivePalette(_ snapshot: RenderSnapshot) -> Palette {
        var palette = snapshot.palette
        if snapshot.modes.contains(.reverseVideo) {
            swap(&palette.foreground, &palette.background)
        }
        return palette
    }

    // MARK: Instances

    private func updateInstances(_ snapshot: RenderSnapshot, palette: Palette, options: RenderOptions) {
        let columns = snapshot.columns, rows = snapshot.rowCount
        // Cursor opacity animates every frame; it only touches the cursor row.
        var comparable = options
        comparable.cursorOpacity = lastOptions.cursorOpacity
        var full = needsFullRebuild || snapshot.damage.isFull || comparable != lastOptions
        if gridSize != (columns, rows) || instances == nil {
            let length = max(1, columns * rows) * MemoryLayout<CellInstance>.stride
            if (instances?.length ?? 0) < length {
                instances = device.makeBuffer(length: length, options: .storageModeShared)
            }
            gridSize = (columns, rows)
            full = true
        }
        var cursor = snapshot.cursor
        cursor.isVisible = cursor.isVisible && options.cursorVisible
        // A palette change (OSC 4/10/11) arrives as full damage from the core.
        if snapshot.sequence == lastSequence, !full, lastCursor == cursor,
           options.cursorOpacity == lastOptions.cursorOpacity {
            return
        }

        let base = instances!.contents().bindMemory(to: CellInstance.self, capacity: columns * rows)
        let previous = lastCursor
        let rowRecords = snapshot.rows
        for y in 0 ..< rows {
            let cursorRow = (cursor.isVisible && cursor.y == y) || (previous?.isVisible == true && previous?.y == y)
            guard full || rowRecords[y].isDirty || cursorRow || atlas.wasReset else { continue }
            buildRow(y, snapshot: snapshot, cursor: cursor, palette: palette, options: options, into: base + y * columns)
        }
        if atlas.wasReset {
            // The atlas filled up mid-frame: rebuild everything against the new atlas.
            atlas.wasReset = false
            for y in 0 ..< rows {
                buildRow(y, snapshot: snapshot, cursor: cursor, palette: palette, options: options, into: base + y * columns)
            }
        }
        lastCursor = cursor
        lastOptions = options
        lastSequence = snapshot.sequence
        needsFullRebuild = false
    }

    private func buildRow(
        _ y: Int, snapshot: RenderSnapshot, cursor: CursorState, palette: Palette, options: RenderOptions,
        into out: UnsafeMutablePointer<CellInstance>,
    ) {
        let cells = snapshot.cells(row: y)
        let backgroundAlpha = UInt32(max(0, min(1, options.backgroundOpacity)) * 255)
        let selection = snapshot.selection
        let matches = snapshot.searchMatches
        let preedit = y == cursor.y && !options.preedit.isEmpty ? Self
            .layoutPreedit(options.preedit, at: cursor.x, columns: cells.count) : [:]
        // Break at the cursor whatever its blink phase, so ligatures don't flicker.
        let shaped = font.shapes ? shapeRow(cells, cursorX: snapshot.cursor.isVisible && cursor.y == y ? cursor.x : -1, skip: preedit) : []
        for x in 0 ..< cells.count {
            var cell = cells[x]
            if let p = preedit[x] {
                cell = p
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
            if !matches.isEmpty, let i = matches.firstIndex(where: { $0.contains(row: y, column: x) }) {
                fg = options.searchForeground
                bg = i == snapshot.selectedSearchMatch ? options.selectedSearchBackground : options.searchBackground
                bgAlpha = 0xFF
            }
            if let selection, selection.contains(row: y, column: x) {
                if options.selectionForeground == nil, options.selectionBackground == nil {
                    swap(&fg, &bg)
                } else {
                    fg = options.selectionForeground ?? fg
                    bg = options.selectionBackground ?? bg
                }
                bgAlpha = 0xFF
            }
            var flags: UInt32 = 0
            if attrs.flags.contains(.underline) {
                flags |= Flag.underline
            }
            if attrs.flags.contains(.doubleUnderline) {
                flags |= Flag.doubleUnderline
            }
            if attrs.flags.contains(.strikethrough) {
                flags |= Flag.strike
            }
            if attrs.flags.contains(.overline) {
                flags |= Flag.overline
            }
            if attrs.flags.contains(.faint) {
                flags |= Flag.faint
            }

            if !preedit.isEmpty, preedit[x] != nil {
                flags |= Flag.underline
            }
            if options.hoveredLink != 0, attrs.link == options.hoveredLink {
                flags |= Flag.underline
            }
            if cursor.isVisible, preedit.isEmpty, cursor.y == y, cursor.x == x {
                switch options.cursorStyle ?? cursor.style {
                case .block where options.hollowCursor || !options.isFocused:
                    flags |= Flag.cursorHollow
                case .block:
                    // Blend so cursor opacity (and its animations) shows the cell beneath.
                    let t = max(0, min(1, options.cursorOpacity))
                    let cellBg = bg
                    fg = Self.mix(fg, options.cursorTextColor ?? cellBg, t)
                    bg = Self.mix(cellBg, options.cursorColor ?? palette.cursor, t)
                    bgAlpha = UInt32(Double(bgAlpha) + (255 - Double(bgAlpha)) * t)
                case .bar: flags |= Flag.cursorBar
                case .underline: flags |= Flag.cursorUnderline
                }
            }

            var entry = GlyphAtlas.Entry.empty
            if !shaped.isEmpty, let shapedEntry = shaped[x] {
                if !attrs.flags.contains(.invisible) {
                    entry = shapedEntry
                }
            } else if !cell.isSpacer, !attrs.flags.contains(.invisible), cell.glyph != 0 || cell.isGrapheme {
                let style = FontStyle(attrs.flags)
                if cell.isGrapheme {
                    let span = snapshot.graphemeScalars(cell)
                    var scalars: [UInt32] = []
                    scalars.reserveCapacity(span.count)
                    for i in 0 ..< span.count {
                        scalars.append(span[i])
                    }
                    entry = atlas.entry(cluster: scalars, style: style, font: font)
                } else if cell.glyph != 0x20, let scalar = Unicode.Scalar(cell.glyph) {
                    entry = atlas.entry(scalar: scalar, style: style, font: font, manager: fontManager)
                }
            }
            if entry.isColor {
                flags |= Flag.colorGlyph
            }
            out[x] = CellInstance(
                grid: SIMD2(UInt16(x), UInt16(y)),
                atlasPos: entry.position,
                atlasSize: entry.size,
                offset: entry.offset,
                fg: fg << 8 | 0xFF,
                bg: bg << 8 | bgAlpha,
                flags: flags,
            )
        }
    }
}

extension MetalRenderer {
    /// Atlas entries for runs of plain single-width cells, shaped together;
    /// nil where the cell takes the per-cell path. Runs break on attribute
    /// changes and at the cursor so a ligature never hides it.
    private func shapeRow(_ cells: Span<Cell>, cursorX: Int, skip: [Int: Cell]) -> [GlyphAtlas.Entry?] {
        var out = [GlyphAtlas.Entry?](repeating: nil, count: cells.count)
        func eligible(_ x: Int) -> Bool {
            let c = cells[x]
            return c.width == 1 && !c.isGrapheme && !c.isSpacer && c.glyph > 0x20 && x != cursorX
                && skip[x] == nil && !BoxDrawing.covers(c.glyph)
        }
        var x = 0
        while x < cells.count {
            guard eligible(x) else { x += 1; continue }
            let attrs = cells[x].attributes
            var end = x + 1
            while end < cells.count, eligible(end), cells[end].attributes == attrs {
                end += 1
            }
            if end - x >= 2 {
                var scalars: [UInt32] = []
                scalars.reserveCapacity(end - x)
                for i in x ..< end {
                    scalars.append(cells[i].glyph)
                }
                for i in x ..< end {
                    out[i] = .empty
                }
                for g in shaper.shape(scalars, style: FontStyle(attrs.flags), font: font) {
                    out[x + g.cell] = atlas.entry(glyph: g.glyph, in: g.font, isColor: g.isColor, font: font)
                }
            }
            x = end
        }
        return out
    }

    /// Linear blend of two 0xRRGGBB colours.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        guard t < 1 else { return b }
        guard t > 0 else { return a }
        var out: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let x = Double(a >> shift & 0xFF), y = Double(b >> shift & 0xFF)
            out |= UInt32((x + (y - x) * t).rounded()) << shift
        }
        return out
    }

    /// Preedit scalars as cells keyed by column, starting at `start`.
    static func layoutPreedit(_ scalars: [Unicode.Scalar], at start: Int, columns: Int) -> [Int: Cell] {
        var cells: [Int: Cell] = [:]
        var x = start
        for s in scalars {
            let w = max(1, UnicodeWidth.width(s.value))
            guard x + w <= columns else { break }
            cells[x] = Cell(glyph: s.value, attributes: .default, width: UInt8(w))
            if w == 2 {
                cells[x + 1] = Cell(glyph: 0, attributes: CellAttributes(flags: .spacerTail), width: 0)
            }
            x += w
        }
        return cells
    }
}

public enum RendererError: Error {
    case setup(String)
}

/// Shelf-packed RGBA glyph atlas filled by CoreText rasterization.
final class GlyphAtlas {
    struct Entry {
        var position: SIMD2<UInt16>
        var size: SIMD2<UInt16>
        var offset: SIMD2<Int16>
        var isColor: Bool
        static let empty = Entry(position: .zero, size: .zero, offset: .zero, isColor: false)
    }

    struct ClusterKey: Hashable {
        var scalars: [UInt32]
        var style: UInt8
    }

    let size = 2048
    let texture: MTLTexture
    private var entries: [UInt64: Entry] = [:]
    private var clusters: [ClusterKey: Entry] = [:]
    private var glyphs: [GlyphKey: Entry] = [:]

    /// A glyph in a specific CTFont; fonts compare with CFEqual, which
    /// covers the matrix, so a synthetic oblique never collides with upright.
    struct GlyphKey: Hashable {
        var font: CTFont
        var glyph: CGGlyph

        static func == (a: GlyphKey, b: GlyphKey) -> Bool {
            a.glyph == b.glyph && CFEqual(a.font, b.font)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(glyph)
            hasher.combine(CFHash(font))
        }
    }

    private var cursorX = 0, cursorY = 0, shelfHeight = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Set when the atlas was cleared; cached instances are stale.
    var wasReset = false

    init(device: MTLDevice) throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { throw RendererError.setup("atlas texture") }
        self.texture = texture
    }

    func reset() {
        entries.removeAll(keepingCapacity: true)
        clusters.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        cursorX = 0
        cursorY = 0
        shelfHeight = 0
        wasReset = true
    }

    func entry(scalar: Unicode.Scalar, style: FontStyle, font: ResolvedFont, manager: CoreTextFontManager) -> Entry {
        let key = UInt64(scalar.value) | UInt64(style.rawValue) << 32
        if let entry = entries[key] {
            return entry
        }
        var entry = Entry.empty
        if BoxDrawing.covers(scalar.value) {
            entry = rasterizeCell(font: font) { ctx, w, h in BoxDrawing.draw(scalar.value, in: ctx, width: w, height: h) }
        } else if let lookup = manager.lookup(scalar, style: style, in: font) {
            var glyph = lookup.glyph
            var rect = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(lookup.font, .horizontal, &glyph, &rect, 1)
            entry = rasterize(bounds: rect, isColor: lookup.isColor, font: font) { context, origin in
                var position = origin
                CTFontDrawGlyphs(lookup.font, &glyph, &position, 1, context)
            }
        }
        entries[key] = entry
        return entry
    }

    /// A shaped glyph, keyed by its font and glyph id.
    func entry(glyph: CGGlyph, in glyphFont: CTFont, isColor: Bool, font: ResolvedFont) -> Entry {
        let key = GlyphKey(font: glyphFont, glyph: glyph)
        if let entry = glyphs[key] {
            return entry
        }
        var g = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(glyphFont, .horizontal, &g, &rect, 1)
        let entry = rasterize(bounds: rect, isColor: isColor, font: font) { context, origin in
            var position = origin
            CTFontDrawGlyphs(glyphFont, &g, &position, 1, context)
        }
        glyphs[key] = entry
        return entry
    }

    func entry(cluster scalars: [UInt32], style: FontStyle, font: ResolvedFont) -> Entry {
        let key = ClusterKey(scalars: scalars, style: style.rawValue)
        if let entry = clusters[key] {
            return entry
        }
        var string = String.UnicodeScalarView()
        for v in scalars {
            if let s = Unicode.Scalar(v) {
                string.append(s)
            }
        }
        let attributed = NSAttributedString(string: String(string), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font.face(style),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let isColor = runs.contains { run in
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName] as! CTFont
            return CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs)
        }
        let entry = rasterize(bounds: bounds, isColor: isColor, font: font) { context, origin in
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        clusters[key] = entry
        return entry
    }

    /// Draws a bitmap exactly one cell in size, placed at the cell's origin.
    private func rasterizeCell(font: ResolvedFont, draw: (CGContext, CGFloat, CGFloat) -> Void) -> Entry {
        let width = Int(font.cellWidth), height = Int(font.cellHeight)
        guard width > 0, height > 0, width < size, height < size else { return .empty }
        if cursorX + width > size {
            cursorX = 0
            cursorY += shelfHeight
            shelfHeight = 0
        }
        if cursorY + height > size {
            reset()
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return .empty }
        context.setShouldAntialias(true)
        draw(context, CGFloat(width), CGFloat(height))
        guard let data = context.data else { return .empty }
        texture.replace(region: MTLRegionMake2D(cursorX, cursorY, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        let entry = Entry(
            position: SIMD2(UInt16(cursorX), UInt16(cursorY)),
            size: SIMD2(UInt16(width), UInt16(height)),
            offset: .zero,
            isColor: false,
        )
        cursorX += width
        shelfHeight = max(shelfHeight, height)
        return entry
    }

    /// Draws into a scratch bitmap sized to `bounds` and uploads it.
    private func rasterize(
        bounds: CGRect, isColor: Bool, font: ResolvedFont,
        draw: (CGContext, CGPoint) -> Void,
    ) -> Entry {
        let pad = 1
        let width = Int(ceil(bounds.width)) + 2 * pad
        let height = Int(ceil(bounds.height)) + 2 * pad
        guard bounds.width > 0, bounds.height > 0, width < size, height < size else { return .empty }
        if cursorX + width > size {
            cursorX = 0
            cursorY += shelfHeight
            shelfHeight = 0
        }
        if cursorY + height > size {
            reset()
        }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return .empty }
        context.setAllowsFontSmoothing(false)
        context.setShouldAntialias(true)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let originX = -floor(bounds.minX) + CGFloat(pad)
        let originY = -floor(bounds.minY) + CGFloat(pad)
        draw(context, CGPoint(x: originX, y: originY))
        guard let data = context.data else { return .empty }
        texture.replace(
            region: MTLRegionMake2D(cursorX, cursorY, width, height),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4,
        )
        let entry = Entry(
            position: SIMD2(UInt16(cursorX), UInt16(cursorY)),
            size: SIMD2(UInt16(width), UInt16(height)),
            // Bitmap top-left relative to the cell's top-left.
            offset: SIMD2(Int16(-originX), Int16(font.ascent - (CGFloat(height) - originY))),
            isColor: isColor,
        )
        cursorX += width
        shelfHeight = max(shelfHeight, height)
        return entry
    }
}
