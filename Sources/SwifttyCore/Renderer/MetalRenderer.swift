import CoreGraphics
import CoreText
import Dispatch
import Foundation
import Metal
import MetalKit

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

    enum Flag {
        static let colorGlyph: UInt32 = 1 << 0
        static let underline: UInt32 = 1 << 1
        static let doubleUnderline: UInt32 = 1 << 2
        static let strike: UInt32 = 1 << 3
        static let overline: UInt32 = 1 << 4
        static let cursorBar: UInt32 = 1 << 5
        static let cursorUnderline: UInt32 = 1 << 6
        static let faint: UInt32 = 1 << 7
    }

    public let device: MTLDevice
    public private(set) var font: ResolvedFont
    private let fontManager: CoreTextFontManager
    private let queue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let decorationPipeline: MTLRenderPipelineState
    private var atlas: GlyphAtlas

    private var instances: MTLBuffer?
    private var gridSize = (columns: 0, rows: 0)
    private var lastCursor: CursorState?
    private var lastSequence: UInt64 = 0
    private var needsFullRebuild = true
    private let inFlight = DispatchSemaphore(value: 1)

    /// Padding around the grid, in pixels.
    public var padding: CGFloat = 8

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
        needsFullRebuild = true
    }

    /// Grid dimensions that fit a drawable of `size` pixels.
    public func gridSize(for size: CGSize) -> (columns: Int, rows: Int) {
        (
            max(1, Int((size.width - 2 * padding) / font.cellWidth)),
            max(1, Int((size.height - 2 * padding) / font.cellHeight)),
        )
    }

    /// Renders into the view's current drawable and presents it.
    @MainActor
    public func draw(_ snapshot: RenderSnapshot, in view: MTKView) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        let commandBuffer = encode(snapshot, pass: pass, size: view.drawableSize)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders into an arbitrary texture (offscreen, tests, benchmarks).
    @discardableResult
    public func render(_ snapshot: RenderSnapshot, to texture: MTLTexture) -> MTLCommandBuffer {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let commandBuffer = encode(snapshot, pass: pass, size: CGSize(width: texture.width, height: texture.height))
        commandBuffer.commit()
        return commandBuffer
    }

    private func encode(_ snapshot: RenderSnapshot, pass: MTLRenderPassDescriptor, size: CGSize) -> MTLCommandBuffer {
        inFlight.wait() // the instance buffer is about to be mutated
        let palette = effectivePalette(snapshot)
        let bg = palette.background
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg >> 16 & 0xFF) / 255, green: Double(bg >> 8 & 0xFF) / 255,
            blue: Double(bg & 0xFF) / 255, alpha: 1,
        )
        pass.colorAttachments[0].loadAction = .clear

        updateInstances(snapshot, palette: palette)

        let commandBuffer = queue.makeCommandBuffer()!
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        var uniforms = Uniforms(
            cellSize: SIMD2(Float(font.cellWidth), Float(font.cellHeight)),
            viewportSize: SIMD2(Float(size.width), Float(size.height)),
            atlasSize: SIMD2(Float(atlas.size), Float(atlas.size)),
            origin: SIMD2(Float(padding), Float(padding)),
            underlinePosition: Float(font.underlinePosition),
            underlineThickness: Float(font.underlineThickness),
            cursorColor: palette.cursor << 8 | 0xFF,
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
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count * 3)
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

    private func updateInstances(_ snapshot: RenderSnapshot, palette: Palette) {
        let columns = snapshot.columns, rows = snapshot.rowCount
        var full = needsFullRebuild || snapshot.damage.isFull
        if gridSize != (columns, rows) || instances == nil {
            let length = max(1, columns * rows) * MemoryLayout<CellInstance>.stride
            if (instances?.length ?? 0) < length {
                instances = device.makeBuffer(length: length, options: .storageModeShared)
            }
            gridSize = (columns, rows)
            full = true
        }
        // A palette change (OSC 4/10/11) arrives as full damage from the core.
        if snapshot.sequence == lastSequence, !full, lastCursor == snapshot.cursor {
            return
        }

        let base = instances!.contents().bindMemory(to: CellInstance.self, capacity: columns * rows)
        let cursor = snapshot.cursor
        let previous = lastCursor
        let rowRecords = snapshot.rows
        for y in 0 ..< rows {
            let cursorRow = (cursor.isVisible && cursor.y == y) || (previous?.isVisible == true && previous?.y == y)
            guard full || rowRecords[y].isDirty || cursorRow || atlas.wasReset else { continue }
            buildRow(y, snapshot: snapshot, palette: palette, into: base + y * columns)
        }
        if atlas.wasReset {
            // The atlas filled up mid-frame: rebuild everything against the new atlas.
            atlas.wasReset = false
            for y in 0 ..< rows {
                buildRow(y, snapshot: snapshot, palette: palette, into: base + y * columns)
            }
        }
        lastCursor = cursor
        lastSequence = snapshot.sequence
        needsFullRebuild = false
    }

    private func buildRow(_ y: Int, snapshot: RenderSnapshot, palette: Palette, into out: UnsafeMutablePointer<CellInstance>) {
        let cells = snapshot.cells(row: y)
        let cursor = snapshot.cursor
        for x in 0 ..< cells.count {
            let cell = cells[x]
            let attrs = cell.attributes
            var fg = palette.resolve(attrs.foreground, isForeground: true)
            var bg = palette.resolve(attrs.background, isForeground: false)
            if attrs.flags.contains(.inverse) {
                swap(&fg, &bg)
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

            if cursor.isVisible, cursor.y == y, cursor.x == x {
                switch cursor.style {
                case .block:
                    fg = bg
                    bg = palette.cursor
                case .bar: flags |= Flag.cursorBar
                case .underline: flags |= Flag.cursorUnderline
                }
            }

            var entry = GlyphAtlas.Entry.empty
            if !cell.isSpacer, !attrs.flags.contains(.invisible), cell.glyph != 0 || cell.isGrapheme {
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
                bg: bg << 8 | 0xFF,
                flags: flags,
            )
        }
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
        if let lookup = manager.lookup(scalar, style: style, in: font) {
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
