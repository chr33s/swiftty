import Darwin
import Foundation
@testable import SwifttyCore
import Testing

struct SessionConfigurationTests {
  @Test
  func
    `CLI shell selection honors an environment override without changing desktop selection`()
  {
    let shell = "/custom/review-shell"
    #expect(
      SessionConfiguration.loginShell(
        environment: ["SHELL": shell],
        fromCommandLine: true
      ) == shell
    )
    let desktop = SessionConfiguration.loginShell(
      environment: [:],
      fromCommandLine: false
    )
    if let record = getpwuid(getuid()),
      let systemShell = record.pointee.pw_shell, systemShell.pointee != 0
    {
      #expect(
        SessionConfiguration.loginShell(
          environment: ["SHELL": shell],
          fromCommandLine: false
        ) == desktop
      )
    }
    #expect(
      SessionConfiguration.loginShell(
        environment: ["SHELL": ""],
        fromCommandLine: true
      ) == desktop
    )
  }

  @Test
  func `an empty executable name reports a missing executable`() {
    let configuration = SessionConfiguration(
      command: [""],
      environment: ["PATH": "/usr/bin:/bin"]
    )
    do {
      _ = try configuration.executablePath()
      Issue.record("empty executable name was resolved")
    } catch { #expect(error.code == ENOENT) }
  }

  @Test(arguments: ["a", "漢"])
  func `oversized PATH candidates fail before a later executable is chosen`(
    _ scalar: String
  ) {
    let oversized =
      "/" + String(repeating: scalar, count: Int(PATH_MAX) / scalar.utf8.count)
    let configuration = SessionConfiguration(
      command: ["sh"],
      environment: ["PATH": oversized + ":/bin"]
    )
    do {
      _ = try configuration.executablePath()
      Issue.record(
        "oversized PATH candidate fell through to another executable"
      )
    } catch { #expect(error.code == ENAMETOOLONG) }
  }

  @Test
  func `PATH candidates below the path limit can fall through`() throws {
    let path = "/" + String(repeating: "a", count: Int(PATH_MAX) - 5)
    let configuration = SessionConfiguration(
      command: ["sh"],
      environment: ["PATH": path + ":/bin"]
    )
    #expect(try configuration.executablePath() == "/bin/sh")
  }

  @Test(arguments: ["\u{300}bin", "bin\u{600}"])
  func `PATH separators preserve Unicode directory names`(
    _ folder: String
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bin = directory.appendingPathComponent(folder)
    try FileManager.default.createDirectory(
      at: bin,
      withIntermediateDirectories: true
    )
    let executable = bin.appendingPathComponent("swiftty-review-command")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    for path in ["missing:" + folder, folder + ":missing"] {
      let configuration = SessionConfiguration(
        command: [executable.lastPathComponent],
        environment: ["PATH": path],
        workingDirectory: directory.path,
      )
      #expect(try configuration.executablePath() == executable.path)
    }
  }

  @Test
  func `explicit executable paths recognize a slash after a prepend scalar`()
    throws
  {
    let path = "\u{600}/command"
    let configuration = SessionConfiguration(
      command: [path],
      environment: ["PATH": "/no-tools"]
    )
    #expect(try configuration.executablePath() == path)
  }

  @Test(arguments: ["bin", ".", ":/usr/bin", "/usr/bin:", ""])
  func `command lookup uses child working directory`(_ path: String) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executableDirectory =
      path == "bin" ? directory.appendingPathComponent("bin") : directory
    try FileManager.default.createDirectory(
      at: executableDirectory,
      withIntermediateDirectories: true
    )
    let executable = executableDirectory.appendingPathComponent(
      "swiftty-review-command"
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let configuration = SessionConfiguration(
      command: [executable.lastPathComponent],
      environment: ["PATH": path],
      workingDirectory: directory.path,
    )
    #expect(
      try URL(fileURLWithPath: configuration.executablePath())
        .standardizedFileURL == executable
    )
  }

  @Test
  func `command lookup skips directories with executable permission`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    try FileManager.default.createDirectory(
      at: first.appendingPathComponent("command"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: second,
      withIntermediateDirectories: true
    )
    let executable = second.appendingPathComponent("command")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let configuration = SessionConfiguration(
      command: ["command"],
      environment: ["PATH": first.path + ":" + second.path]
    )
    #expect(try configuration.executablePath() == executable.path)
  }

  @Test
  func
    `failed PATH lookup does not fall back to an unlisted working directory`()
    throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bin = directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(
      at: bin,
      withIntermediateDirectories: true
    )
    let executable = directory.appendingPathComponent("command")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let configuration = SessionConfiguration(
      command: ["command"],
      environment: ["PATH": bin.path],
      workingDirectory: directory.path
    )
    do {
      _ = try configuration.executablePath()
      Issue.record("command outside PATH was accepted")
    } catch { #expect(error.code == ENOENT) }
    var denied = configuration
    denied.environment["PATH"] = directory.path
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: executable.path
    )
    do {
      _ = try denied.executablePath()
      Issue.record("nonexecutable command was accepted")
    } catch { #expect(error.code == EACCES) }
  }
}
