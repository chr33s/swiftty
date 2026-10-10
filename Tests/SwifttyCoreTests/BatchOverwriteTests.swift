@testable import SwifttyCore
import Testing
import TestSupport

struct BatchOverwriteTests {
  @Test
  func `wide ideographs have independent two-column cells`() {
    for scalar in UInt32(0x4E00) ... 0x9FFF {
      #expect(ScalarInfoTable.shared.lookup(scalar) == 2 << 5)
    }
  }

  @Test(
    arguments: [1, 3, 15, 16, 17, 31, 32, 33, 65],
    [(false, false), (false, true), (true, false), (true, true)]
  )
  func `long wide batches match scalar writes`(
    _ columns: Int,
    _ modes: (Bool, Bool)
  ) {
    let (wrapping, clustering) = modes
    let seeds = ["", "abcdef", "漢字123", "a\u{600}"]
    let alphabet = Array("\u{4E00}\u{9FFF}漢字".unicodeScalars)
    let texts =
      [0, 1, 7, 8, 9, 15, 16, 17, 33]
      .map { length in
        String(
          String.UnicodeScalarView(
            (0 ..< length).map { alphabet[$0 % alphabet.count] }
          )
        )
      } + [
        String(repeating: "漢", count: 8) + "\u{301}abc漢字",
        String(repeating: "漢", count: 8) + "\u{FE0F}漢字",
        String(repeating: "漢", count: 8) + "\u{200D}👩‍💻字",
        String(repeating: "漢", count: 8) + "\u{4DFF}\u{A000}字",
        String(repeating: "日本語中文한국어", count: 3),
        String(repeating: "ᄀᄁᄂᄃ", count: 3), String(repeating: "ᄀ가각ᄂ", count: 3),
        String(repeating: "漢字가각", count: 3) + "\u{11A8}\u{301}𠀀😀",
        String(repeating: "𠀀😀🚀😃", count: 3) + "\u{FE0F}\u{200D}🧑",
        String(repeating: "漢字", count: 8) + "\u{600}漢字",
      ]
    for seed in seeds {
      for start in 0 ..< columns {
        for text in texts {
          var actual = VT(columns, 3, scrollback: 4096)
          var reference = VT(columns, 3, scrollback: 4096)
          let setup =
            "\u{1B}[?7\(wrapping ? "h" : "l")\u{1B}[?2027\(clustering ? "h" : "l")"
            + seed
            + "\u{1B}[1;\(start + 1)H\u{1B}[1;3;4;7;38;2;12;34;56;48;5;123m"
          actual.feed(setup)
          reference.feed(setup)
          _ = actual.state.takeDamage()
          _ = reference.state.takeDamage()
          actual.feed(text)
          for scalar in text.unicodeScalars {
            reference.state.print(scalar.value)
          }
          let cells = (0 ..< 3)
            .flatMap { row in (0 ..< columns).map { actual.cell($0, row) } }
          let expected = (0 ..< 3)
            .flatMap { row in (0 ..< columns).map { reference.cell($0, row) } }
          #expect(cells == expected)
          #expect(actual.state.cursor == reference.state.cursor)
          #expect(actual.state.lastPrinted == reference.state.lastPrinted)
          #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
          let damage = actual.state.takeDamage()
          let expectedDamage = reference.state.takeDamage()
          #expect(damage == expectedDamage)
          for row in 0 ..< 3 {
            let extent = actual.state.grid.extent(row)
            let expectedExtent = reference.state.grid.extent(row)
            let wrapped = actual.state.grid.isWrapped(row)
            let expectedWrapped = reference.state.grid.isWrapped(row)
            #expect(extent == expectedExtent)
            #expect(wrapped == expectedWrapped)
          }
          let history = (0 ..< actual.state.scrollbackCount)
            .map { actual.state.scrollbackText($0) }
          let expectedHistory = (0 ..< reference.state.scrollbackCount)
            .map { reference.state.scrollbackText($0) }
          #expect(history == expectedHistory)
        }
      }
    }
  }

  @Test(
    arguments: [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33],
    [false, true]
  )
  func `ASCII batches match scalar writes across row boundaries`(
    _ columns: Int,
    _ wrapping: Bool
  ) {
    let seeds = ["", "漢字123", "abcdef"]
    for seed in seeds {
      for start in 0 ..< columns {
        for length in [0, 1, 2, 3, 4, 5, 7, 8, 9, columns, columns * 2 + 3, 95]
        {
          var actual = VT(columns, 3, scrollback: 4096)
          var reference = VT(columns, 3, scrollback: 4096)
          let setup =
            "\u{1B}[?7\(wrapping ? "h" : "l")" + seed
            + "\u{1B}[1;\(start + 1)H\u{1B}[1;3;4;7;38;2;12;34;56;48;5;123m"
          actual.feed(setup)
          reference.feed(setup)
          let text = String(
            decoding: (0 ..< length).map { UInt8(0x20 + $0 % 95) },
            as: UTF8.self
          )
          actual.feed(text)
          for scalar in text.unicodeScalars {
            reference.state.print(scalar.value)
          }
          let cells = (0 ..< 3)
            .flatMap { row in (0 ..< columns).map { actual.cell($0, row) } }
          let expected = (0 ..< 3)
            .flatMap { row in (0 ..< columns).map { reference.cell($0, row) } }
          #expect(cells == expected)
          #expect(actual.state.cursor == reference.state.cursor)
          #expect(actual.state.lastPrinted == reference.state.lastPrinted)
          #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
          for row in 0 ..< 3 {
            let extent = actual.state.grid.extent(row)
            let expectedExtent = reference.state.grid.extent(row)
            let wrapped = actual.state.grid.isWrapped(row)
            let expectedWrapped = reference.state.grid.isWrapped(row)
            #expect(extent == expectedExtent)
            #expect(wrapped == expectedWrapped)
          }
          let history = (0 ..< actual.state.scrollbackCount)
            .map { actual.state.scrollbackText($0) }
          let expectedHistory = (0 ..< reference.state.scrollbackCount)
            .map { reference.state.scrollbackText($0) }
          #expect(history == expectedHistory)
        }
      }
    }
  }

  @Test(
    arguments: [1, 2, 3, 5, 8],
    [(false, false), (false, true), (true, false), (true, true)]
  )
  func `batched overwrites match scalar writes`(
    _ columns: Int,
    _ modes: (Bool, Bool)
  ) {
    let (wrapping, clustering) = modes
    let seeds = [
      "", "abc", "漢字", "abc漢", "é漢a字", "a\u{301}漢字", "👩‍💻abc", "\u{600}a漢",
    ]
    let writes = [
      "éabc", "漢字", "é漢a", "漢é字", "é\u{301}漢", "\u{301}漢a", "👩‍💻x", "\u{600}é字",
      "é\u{FE0F}x", "漢abc漢",
    ]
    for seed in seeds {
      for text in writes {
        for y in 0 ..< 3 {
          for x in 0 ..< columns {
            var actual = VT(columns, 3, scrollback: 4096)
            var reference = VT(columns, 3, scrollback: 4096)
            let setup =
              "\u{1B}[?7\(wrapping ? "h" : "l")\u{1B}[?2027\(clustering ? "h" : "l")"
              + seed + "\u{1B}[\(y + 1);\(x + 1)H"
            actual.feed(setup)
            reference.feed(setup)
            actual.feed(text)
            for scalar in text.unicodeScalars {
              reference.state.print(scalar.value)
            }
            let cells = (0 ..< 3)
              .flatMap { row in (0 ..< columns).map { actual.cell($0, row) } }
            let expected = (0 ..< 3)
              .flatMap { row in (0 ..< columns).map { reference.cell($0, row) }
              }
            let extents = (0 ..< 3).map { actual.state.grid.extent($0) }
            let expectedExtents = (0 ..< 3)
              .map { reference.state.grid.extent($0) }
            let wrapped = (0 ..< 3).map { actual.state.grid.isWrapped($0) }
            let expectedWrapped = (0 ..< 3)
              .map { reference.state.grid.isWrapped($0) }
            let history = (0 ..< actual.state.scrollbackCount)
              .map { actual.state.scrollbackText($0) }
            let expectedHistory = (0 ..< reference.state.scrollbackCount)
              .map { reference.state.scrollbackText($0) }
            if cells != expected
              || actual.state.cursor != reference.state.cursor
              || actual.lines != reference.lines || extents != expectedExtents
              || wrapped != expectedWrapped || history != expectedHistory
              || actual.state.lastPrinted != reference.state.lastPrinted
            {
              let context =
                "columns=\(columns) wrapping=\(wrapping) clustering=\(clustering)"
                + " seed=\(seed.debugDescription) text=\(text.debugDescription) cursor=(\(x),\(y))"
              #expect(
                cells == expected,
                Comment(rawValue: escapedTestText("\(context)"))
              )
              #expect(
                actual.state.cursor == reference.state.cursor,
                Comment(rawValue: escapedTestText("\(context)"))
              )
              #expect(
                TestFixture(actual.lines) == TestFixture(reference.lines),
                Comment(rawValue: escapedTestText("\(context)")),
              )
              #expect(
                extents == expectedExtents,
                Comment(rawValue: escapedTestText("\(context)"))
              )
              #expect(
                wrapped == expectedWrapped,
                Comment(rawValue: escapedTestText("\(context)"))
              )
              #expect(
                history == expectedHistory,
                Comment(rawValue: escapedTestText("\(context)"))
              )
              #expect(
                actual.state.lastPrinted == reference.state.lastPrinted,
                Comment(rawValue: escapedTestText("\(context)")),
              )
              return
            }
          }
        }
      }
    }
  }
}
