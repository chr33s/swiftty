import Foundation
import Testing
@testable import SwifttyJS

struct JavaScriptJSONCTests {
  @Test
  func parsesDataWithoutExecutingIt() throws {
    let runtime = JavaScriptRuntime(environment: [:])
    try runtime.evaluate(
      #"""
      const options = swiftty.jsonc.parse(`{
        // Automation settings, independent of the terminal schema.
        "prefix": "https://example.com/*literal*/",
        "script": "globalThis.executed = true",
        "items": [1, 2,],
      }`);
      if (globalThis.executed !== undefined) throw Error('data was executed');
      if (options.items.length !== 2) throw Error('trailing comma failed');
      if (swiftty.jsonc.parse('null') !== null) throw Error('null failed');
      if (swiftty.jsonc.parse('/* comment */ 42') !== 42) throw Error('scalar failed');
      swiftty.filter.onStdout(text => options.prefix + ':' + text);
      """#
    )
    #expect(
      runtime.filter(Data("hello".utf8), stream: .stdout)
        == Data("https://example.com/*literal*/:hello".utf8)
    )
  }

  @Test
  func caughtErrorsPreserveRuntimeAndReportOriginalPositions() throws {
    let runtime = JavaScriptRuntime(environment: [:])
    try runtime.evaluate(
      #"""
      let rejected = 0;
      for (const input of ['{,}', '[,]', '{} /* unfinished', '{"a":1,"a":2}']) {
        try { swiftty.jsonc.parse(input); }
        catch (e) { if (!(e instanceof SyntaxError)) throw e; rejected++; }
      }
      if (rejected !== 4) throw Error('invalid JSONC accepted');
      try { swiftty.jsonc.parse('/* 🦊\ncomment */\n{"value": }'); }
      catch (e) {
        if (e.line !== 3 || e.column !== 11) throw Error('wrong source position: ' + e);
        rejected++;
      }
      try { swiftty.jsonc.parse({}); }
      catch (e) { if (!(e instanceof TypeError)) throw e; rejected++; }
      if (rejected !== 6) throw Error('missing errors');
      swiftty.filter.onStdout(text => text.toUpperCase());
      """#
    )
    #expect(
      runtime.filter(Data("working".utf8), stream: .stdout)
        == Data("WORKING".utf8)
    )
    #expect(throws: JavaScriptRuntime.ScriptError.self) {
      try runtime.evaluate("swiftty.jsonc.parse('{,}')")
    }
  }

  @Test
  func readsFilesRelativeToScriptDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("automation.jsonc")
    try Data("{/* settings */\"replacement\":\"configured\",}".utf8)
      .write(to: file)
    let runtime = JavaScriptRuntime(
      environment: ["FILE": file.path],
      configurationDirectory: directory
    )
    try runtime.evaluate(
      """
      const relative = swiftty.jsonc.read('automation.jsonc');
      const absolute = swiftty.jsonc.read(swiftty.env('FILE'));
      if (relative.replacement !== absolute.replacement) throw Error('path mismatch');
      let missing = false;
      try { swiftty.jsonc.read('missing.jsonc'); } catch (e) { missing = true; }
      if (!missing) throw Error('missing file accepted');
      swiftty.filter.onStdout(() => relative.replacement);
      """
    )
    #expect(runtime.filter(Data(), stream: .stdout) == Data("configured".utf8))
    try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: file)
    #expect(throws: JavaScriptRuntime.ScriptError.self) {
      try runtime.evaluate("swiftty.jsonc.read('automation.jsonc')")
    }
  }
}
