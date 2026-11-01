import Foundation
import Testing
@testable import Swsh

@Suite
struct LanguageFixtureTests {
  private struct Fixture: Decodable {
    let source: String
    let variables: [String: String]
    let argv: [String]
  }

  @Test
  func versionOneArgumentBoundaries() throws {
    let path = try #require(
      Bundle.module.url(
        forResource: "language-v1",
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    )
    let fixtures = try JSONDecoder()
      .decode([Fixture].self, from: Data(contentsOf: path))
    #expect(!fixtures.isEmpty)
    for fixture in fixtures {
      guard case .complete(let program) = Parser().parse(fixture.source) else {
        Issue.record("fixture failed to parse: \(fixture.source)")
        continue
      }
      let state = ShellState(
        variables: fixture.variables.mapValues { Array($0.utf8) }
      )
      let prepared = try Expander(state: state)
        .prepare(program.commands[0].pipeline[0])
      #expect(
        prepared.arguments == fixture.argv.map { Array($0.utf8) },
        "\(fixture.source)"
      )
    }
  }
}
