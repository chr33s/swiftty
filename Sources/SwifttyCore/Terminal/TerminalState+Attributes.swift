/// SGR pen attributes and extended-color parameter decoding.
extension TerminalState {
  // MARK: SGR

  mutating func selectGraphicRendition(_ csi: borrowing CSISequence) {
    if csi.count == 0 {
      // SGR leaves hyperlinks and protection alone.
      cursor.pen = CellAttributes(
        flags: cursor.pen.flags.intersection(.protected),
        link: cursor.pen.link
      )
      return
    }
    var pen = cursor.pen
    var i = 0
    while i < csi.count {
      let p = csi.value(i)
      if csi.colonMask != 0, csi.isSubparameter(i + 1), p != 4, p != 38,
        p != 48, p != 58
      {
        // Unsupported colon groups are one unknown attribute, not a
        // list of independent SGRs that could reset or recolor the pen.
        i = Self.endOfSGRGroup(csi, startingAt: i) + 1
        continue
      }
      switch p {
      case 0:
        pen = CellAttributes(
          flags: pen.flags.intersection(.protected),
          link: pen.link
        )
      case 1: pen.flags.insert(.bold)
      case 2: pen.flags.insert(.faint)
      case 3: pen.flags.insert(.italic)
      case 4:
        if csi.isSubparameter(i + 1) {
          let end = Self.endOfSGRGroup(csi, startingAt: i)
          let subparameters = end - i
          i = end
          if subparameters != 1 {
            break  // Underline accepts exactly one subparameter.
          }
          pen.flags.subtract(.anyUnderline)
          switch csi.value(i) {
          case 0: break
          case 2: pen.flags.insert(.doubleUnderline)
          case 3: pen.flags.formUnion([.underline, .underlineStyleA])
          case 4: pen.flags.formUnion([.underline, .underlineStyleB])
          case 5:
            pen.flags.formUnion([
              .underline, .underlineStyleA, .underlineStyleB,
            ])
          default: pen.flags.insert(.underline)
          }
        } else {
          pen.flags.subtract(.anyUnderline)
          pen.flags.insert(.underline)
        }
      case 5, 6: pen.flags.insert(.blink)
      case 7: pen.flags.insert(.inverse)
      case 8: pen.flags.insert(.invisible)
      case 9: pen.flags.insert(.strikethrough)
      case 21:
        pen.flags.subtract(.anyUnderline);
        pen.flags.insert(.doubleUnderline)
      case 22: pen.flags.remove([.bold, .faint])
      case 23: pen.flags.remove(.italic)
      case 24: pen.flags.subtract(.anyUnderline)
      case 25: pen.flags.remove(.blink)
      case 27: pen.flags.remove(.inverse)
      case 28: pen.flags.remove(.invisible)
      case 29: pen.flags.remove(.strikethrough)
      case 30 ... 37: pen.foreground = .palette(UInt8(p - 30))
      case 38: if let c = extendedColor(csi, &i) { pen.foreground = c }
      case 39: pen.foreground = .default
      case 40 ... 47: pen.background = .palette(UInt8(p - 40))
      case 48: if let c = extendedColor(csi, &i) { pen.background = c }
      case 49: pen.background = .default
      case 53: pen.flags.insert(.overline)
      case 55: pen.flags.remove(.overline)
      case 58:
        if let c = extendedColor(csi, &i) {
          pen.underlineColor = internUnderlineColor(c)
        }
      case 59: pen.underlineColor = 0
      case 90 ... 97: pen.foreground = .palette(UInt8(p - 90 + 8))
      case 100 ... 107: pen.background = .palette(UInt8(p - 100 + 8))
      default: break
      }
      i += 1
    }
    cursor.pen = pen
  }

  /// The last parameter in a colon group; semicolons start a new group.
  private static func endOfSGRGroup(
    _ csi: borrowing CSISequence,
    startingAt start: Int
  ) -> Int {
    var end = start
    while csi.isSubparameter(end + 1) { end += 1 }
    return end
  }

  /// Parses `38;5;n`, `38;2;r;g;b` and their colon forms; leaves `i` on
  /// the last consumed parameter.
  private func extendedColor(
    _ csi: borrowing CSISequence,
    _ i: inout Int
  ) -> TerminalColor? {
    if csi.isSubparameter(i + 1) {
      let end = Self.endOfSGRGroup(csi, startingAt: i)
      defer { i = end }
      let kind = csi.value(i + 1)
      let args = end - (i + 1)
      if kind == 5, args >= 1 {
        return .palette(UInt8(clamping: csi.value(i + 2)))
      }
      if kind == 2, args == 3 || args == 4 {
        // last three are r, g, b (optional colorspace id first)
        let base = end - 2
        return .rgb(
          UInt8(clamping: csi.value(base)),
          UInt8(clamping: csi.value(base + 1)),
          UInt8(clamping: csi.value(base + 2)),
        )
      }
      return nil
    }
    switch csi.value(i + 1) {
    case 5:
      defer { i += 2 }
      return i + 2 < csi.count
        ? .palette(UInt8(clamping: csi.value(i + 2))) : nil
    case 2:
      defer { i += 4 }
      guard i + 4 < csi.count else { return nil }
      return .rgb(
        UInt8(clamping: csi.value(i + 2)),
        UInt8(clamping: csi.value(i + 3)),
        UInt8(clamping: csi.value(i + 4)),
      )
    default:
      // An unknown color mode does not consume the next semicolon
      // parameter: it may be a valid independent attribute.
      return nil
    }
  }
}
