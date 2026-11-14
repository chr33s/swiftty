import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC
import TestSupport
import Testing

struct AgentPlistTests {
  @Test(arguments: [false, true])
  func stringValuesRoundTripThroughXML(bundle: Bool) throws {
    let label = "com.example.<&>\r\nagent🙂"
    let path = "directory\r<&>/executable\t🙂"
    let xml = try AgentPlist.contents(
      label: label,
      program: bundle ? nil : path,
      bundleProgram: bundle ? path : nil
    )
    let object = try PropertyListSerialization.propertyList(
      from: Data(xml.utf8),
      options: [],
      format: nil
    )
    let dictionary = try #require(object as? [String: Any])
    #expect(dictionary["Label"] as? String == label)
    #expect(dictionary[bundle ? "BundleProgram" : "Program"] as? String == path)
    let services = try #require(dictionary["MachServices"] as? [String: Bool])
    #expect(services == [label: true])
  }

  @Test(
    arguments: ["\u{0}", "\u{1}", "\u{B}", "\u{FFFE}", "\u{FFFF}"]
      .map { TestFixture($0) }
  )
  func invalidXMLScalarsAreRefused(fixture: TestFixture<String>) {
    let value = fixture.value
    #expect(throws: MuxError.self) { try AgentPlist.contents(label: value) }
    #expect(throws: MuxError.self) { try AgentPlist.contents(program: value) }
    #expect(throws: MuxError.self) {
      try AgentPlist.contents(bundleProgram: value)
    }
  }
}
