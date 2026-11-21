/// Program-reported text shown in native chrome (tab and pane titles).
public enum DisplayText {
  public static let maxTitleCharacters = 120

  /// Most scalars one shown character keeps (joined emoji, stacked
  /// marks); past it the character shows as U+FFFD, which joins nothing.
  public static let maxCharacterScalars = 32

  /// Drops controls, bidi overrides and other invisible scalars, folds
  /// whitespace runs to one space and bounds the length, so a program
  /// cannot inject layout or spoof chrome through OSC titles. Joiners,
  /// emoji presentation selectors and flag tags stay where they shape an
  /// emoji or a joining script.
  public static func sanitize(
    _ text: String,
    limit: Int = maxTitleCharacters
  ) -> String {
    let scalars = text.unicodeScalars
    var out = String.UnicodeScalarView()
    var space = false
    // The scalar just before, if it was kept.
    var previous: Unicode.Scalar?
    // Tags before this index complete a flag sequence.
    var flagEnd = scalars.startIndex
    var i = scalars.startIndex
    while i != scalars.endIndex {
      let scalar = scalars[i]
      let next = scalars.index(after: i)
      defer { i = next }
      let kept: Bool
      switch scalar {
      case "\u{200C}", "\u{200D}":
        kept =
          previous.map(joins) == true && next != scalars.endIndex
          && shows(scalars[next]) && joins(scalars[next])
      case "\u{FE0E}", "\u{FE0F}":
        // After an emoji; after a digit, # or * only in a keycap.
        kept =
          previous.map { emoji in
            emoji.properties.isEmoji
              && (!emoji.isASCII
                || (next != scalars.endIndex && scalars[next] == "\u{20E3}"))
          } == true
      case "\u{E0020}" ... "\u{E007F}": kept = i < flagEnd
      case "\u{1F3F4}":
        kept = true
        var end = next
        while end != scalars.endIndex,
          ("\u{E0020}" ... "\u{E007E}").contains(scalars[end])
        { end = scalars.index(after: end) }
        if end != next, end != scalars.endIndex, scalars[end] == "\u{E007F}" {
          flagEnd = scalars.index(after: end)
        }
      default: kept = shows(scalar)
      }
      previous = kept ? scalar : nil
      if !kept {
        space = space || scalar.properties.isWhitespace
        continue
      }
      if scalar.properties.generalCategory == .spaceSeparator {
        space = true
        continue
      }
      if space, !out.isEmpty { out.append(" ") }
      space = false
      out.append(scalar)
    }
    return bounded(head(String(out), width: limit))
  }

  /// `text` with each character that joins more than `maxCharacterScalars`
  /// scalars shown as U+FFFD, which joins nothing around it.
  public static func bounded(_ text: String) -> String {
    guard
      text.contains(where: { $0.unicodeScalars.count > maxCharacterScalars })
    else { return text }
    return String(
      text.map { character in
        character.unicodeScalars.count > maxCharacterScalars
          ? "\u{FFFD}" : character
      }
    )
  }

  /// A name a client may give a workspace or tab: text that `sanitize`
  /// keeps as it is (any length), so every client shows it, and it can be
  /// typed back, as given.
  public static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && sanitize(name, limit: .max) == name
  }

  /// A workspace's shown name: sanitized, and a service default (a bare
  /// number) reads as "Workspace 0" rather than "0". A name a person gave
  /// shows as given.
  public static func workspaceName(_ name: String) -> String {
    let shown = sanitize(name)
    guard !shown.isEmpty, shown.allSatisfy(\.isASCII),
      shown.allSatisfy(\.isNumber)
    else { return shown }
    return "Workspace \(shown)"
  }

  /// The plain name a person typed or pasted means: spacing folded and
  /// invisibles dropped, whole; nil when nothing is left.
  public static func plainName(_ typed: String) -> String? {
    let name = sanitize(typed, limit: .max)
    return name.isEmpty ? nil : name
  }

  /// `character` draws as itself in chrome: every scalar shows, shapes
  /// what it joins, or is a private-use glyph (icon fonts), and it joins
  /// no more than `maxCharacterScalars`. Unlike `sanitize`, this does not
  /// judge where a shaping scalar sits and keeps private-use glyphs, which
  /// names and titles drop.
  public static func draws(_ character: Character) -> Bool {
    // Nearly all chrome text is printable ASCII.
    if let ascii = character.asciiValue {
      return ascii >= 0x20 && ascii != 0x7F
    }
    return character.unicodeScalars.count <= maxCharacterScalars
      && character.unicodeScalars.allSatisfy(draws)
  }

  /// `scalar` shows, shapes what it joins, or is a private-use glyph
  /// (icon fonts), which names and titles drop but typed text may hold.
  private static func draws(_ scalar: Unicode.Scalar) -> Bool {
    shows(scalar) || shapes(scalar)
      || scalar.properties.generalCategory == .privateUse
  }

  /// Joiners, emoji presentation selectors and flag tags: invisible
  /// alone, they shape the scalars around them.
  private static func shapes(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "\u{200C}", "\u{200D}", "\u{FE0E}", "\u{FE0F}",
      "\u{E0020}" ... "\u{E007F}":
      true
    default: false
    }
  }

  /// Controls, separators, format scalars and default-ignorable scalars
  /// (fillers, variation selectors, reserved ranges) draw nothing or only
  /// reorder text. Other unassigned scalars may be newer emoji and show.
  private static func shows(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse,
      .surrogate:
      false
    default: !scalar.properties.isDefaultIgnorableCodePoint
    }
  }

  /// A joiner shapes emoji and joining scripts, never ASCII: elsewhere it
  /// only hides text.
  private static func joins(_ scalar: Unicode.Scalar) -> Bool {
    !scalar.isASCII && !scalar.properties.isWhitespace
  }

  /// `text` within `width` characters, keeping its start; an ellipsis
  /// marks the cut.
  public static func head(_ text: String, width: Int) -> String {
    guard text.count > width else { return text }
    guard width > 0 else { return "" }
    return String(text.prefix(width - 1)) + "…"
  }

  /// `text` within `width` characters, keeping its end; an ellipsis marks
  /// the cut.
  public static func tail(_ text: String, width: Int) -> String {
    guard text.count > width else { return text }
    guard width > 0 else { return "" }
    return "…" + String(text.suffix(width - 1))
  }
}

extension LayoutGeometry {
  /// The smallest extent along `axis` that keeps every pane in `node` at
  /// least `pane` units, with `divider` between siblings.
  public static func minimumExtent(
    _ node: LayoutNode,
    axis: SplitAxis,
    pane: Int,
    divider: Int
  ) -> Int {
    switch node {
    case .pane: return pane
    case let .split(ax, _, a, b):
      let ma = minimumExtent(a, axis: axis, pane: pane, divider: divider)
      let mb = minimumExtent(b, axis: axis, pane: pane, divider: divider)
      return ax == axis ? ma + mb + divider : max(ma, mb)
    }
  }

  /// `ratio` for the split at `path` clamped so both children keep their
  /// minimum extents inside `rect`. When the area is too small for both,
  /// the space is shared in proportion to the minimums.
  public static func clampedRatio(
    _ ratio: Double,
    at path: [Bool],
    of root: LayoutNode,
    in rect: LayoutRect,
    minimum: (columns: Int, rows: Int),
    divider: Int
  ) -> Double {
    var node = root
    var area = rect
    for step in path {
      guard case let .split(axis, r, a, b) = node else { return ratio }
      let length = axis == .leftRight ? area.width : area.height
      let (first, second) = partition(length, ratio: r, divider: divider)
      switch (axis, step) {
      case (.leftRight, false): area.width = first
      case (.leftRight, true):
        area.x += first + divider
        area.width = second
      case (.topBottom, false): area.height = first
      case (.topBottom, true):
        area.y += first + divider
        area.height = second
      }
      node = step ? b : a
    }
    guard case let .split(axis, _, a, b) = node else { return ratio }
    let unit = axis == .leftRight ? minimum.columns : minimum.rows
    let length = axis == .leftRight ? area.width : area.height
    let usable = Double(max(1, length - divider))
    let ma = Double(minimumExtent(a, axis: axis, pane: unit, divider: divider))
    let mb = Double(minimumExtent(b, axis: axis, pane: unit, divider: divider))
    let lower = ma / usable
    let upper = 1 - mb / usable
    let bounded =
      lower <= upper ? min(upper, max(lower, ratio)) : ma / max(1, ma + mb)
    return min(0.95, max(0.05, bounded))
  }
}
