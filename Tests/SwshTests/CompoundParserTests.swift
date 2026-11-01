import Testing
@testable import Swsh

struct CompoundParserTests {
  @Test(arguments: ["f() {", "(echo x", "echo $(echo x", "echo \"$(echo x)"])
  func incomplete(_ source: String) {
    guard case .incomplete = Parser().parse(source) else {
      Issue.record("expected incomplete source");
      return
    }
  }

  @Test(arguments: [
    "f() { echo x; }; f", "(echo ')'; (true)) | /bin/cat",
    "echo \"$(echo $(pwd))\"", "echo $1 $#",
  ])
  func complete(_ source: String) {
    guard case .complete = Parser().parse(source) else {
      Issue.record("expected complete source");
      return
    }
  }

  @Test(arguments: ["(true) extra", "f() nope", "echo )", "echo $(true && )"])
  func invalid(_ source: String) {
    guard case .invalid = Parser().parse(source) else {
      Issue.record("expected invalid source");
      return
    }
  }

  @Test(arguments: [15, 16])
  func exactNestingBoundary(_ depth: Int) {
    let source =
      String(repeating: "(", count: depth) + "true"
      + String(repeating: ")", count: depth)
    switch Parser().parse(source) {
    case .complete: #expect(depth == 15)
    case .invalid: #expect(depth == 16)
    case .incomplete: Issue.record("balanced source was incomplete")
    }
  }

  @Test
  func nestingIsBounded() {
    let source =
      String(repeating: "(", count: 129) + "true"
      + String(repeating: ")", count: 129)
    guard case .invalid = Parser().parse(source) else {
      Issue.record("expected nesting limit");
      return
    }
  }
}
