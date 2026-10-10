import Testing
import TestSupport

struct TestOutputSafetyTests {
  @Test(
    arguments: (Array(0 ... 0x1F) + Array(0x7F ... 0x9F))
      .map { TestFixture(String(Unicode.Scalar(UInt32($0))!)) }
  )
  func
    `fixture descriptions escape every terminal control without changing its value`(
      _ fixture: TestFixture<String>
    ) throws
  {
    let scalar = try #require(fixture.value.unicodeScalars.first)
    #expect(fixture.value.utf8.count == scalar.utf8.count)
    let description = String(describingForTest: fixture)
    let safe = description.unicodeScalars.allSatisfy {
      $0.value >= 0x20 && !(0x7F ... 0x9F).contains($0.value)
    }
    #expect(safe)
    let reflected = Mirror(reflecting: fixture).children
      .map { String(describingForTest: $0.value) }.joined()
    let reflectedSafe = reflected.unicodeScalars.allSatisfy {
      $0.value >= 0x20 && !(0x7F ... 0x9F).contains($0.value)
    }
    #expect(reflectedSafe)
    #expect(description.contains("\\u{"))
  }

  @Test
  func `nested fixture descriptions escape control sequences`() {
    let fixture = TestFixture(
      ("\u{1B}(0q", ["\u{1B}]52;c;YQ==\u{07}", "a\0b", "\u{9B}31m"])
    )
    let description = String(describingForTest: fixture)
    let safe = description.unicodeScalars.allSatisfy {
      $0.value >= 0x20 && !(0x7F ... 0x9F).contains($0.value)
    }
    #expect(safe)
    #expect(description.contains("(0q"))
    #expect(fixture.value.0.utf8.first == 0x1B)
    #expect(fixture.value.1[1].utf8.elementsEqual([0x61, 0, 0x62]))
  }
}
