#if os(macOS)
import Foundation
import Testing
import TestSupport

private final class NativeTestProductsTestBundle: NSObject {}

struct NativeTestProductsTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-products-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  private func executable(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 97\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }

  @Test
  func loadedTestImageSelectsItsSiblingLauncherWithoutAnOverride() throws {
    let expected = Bundle(for: NativeTestProductsTestBundle.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("swmux-launcher").path
    #expect(try NativeTestProducts.launcherPath(environment: [:]) == expected)
  }

  @Test(arguments: ["Debug", "Release", "Custom build products"])
  func selectedBundleBeatsAnExecutableFromAnotherConfiguration(
    _ configuration: String
  ) throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let decoy = root.appendingPathComponent(".build/debug/swmux-launcher")
    try executable(decoy)
    let products = root.appendingPathComponent(configuration)
    let launcher = products.appendingPathComponent("swmux-launcher")
    try executable(launcher)
    let bundle = products.appendingPathComponent("ExampleTests.xctest")
    #expect(
      try NativeTestProducts.launcherPath(environment: [:], bundleURL: bundle)
        == launcher.path
    )
  }

  @Test
  func explicitOverrideWinsOverTheSelectedBundle() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let launcher = root.appendingPathComponent("explicit launcher")
    try executable(launcher)
    let products = root.appendingPathComponent("Release")
    try executable(products.appendingPathComponent("swmux-launcher"))
    #expect(
      try NativeTestProducts.launcherPath(
        environment: ["SWMUX_LAUNCHER": launcher.path],
        bundleURL: products.appendingPathComponent("ExampleTests.xctest")
      ) == launcher.path
    )
  }

  @Test
  func missingSelectedLauncherDoesNotUseADifferentBuild() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try executable(root.appendingPathComponent(".build/debug/swmux-launcher"))
    let products = root.appendingPathComponent("Release")
    let expected = products.appendingPathComponent("swmux-launcher").path
    #expect(throws: NativeTestProducts.Failure.launcherUnavailable(expected)) {
      try NativeTestProducts.launcherPath(
        environment: [:],
        bundleURL: products.appendingPathComponent("ExampleTests.xctest")
      )
    }
  }

  @Test(arguments: ["missing", "empty", "directory", "nonexecutable"])
  func invalidExplicitOverrideDoesNotUseTheBundleLauncher(_ kind: String) throws
  {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let products = root.appendingPathComponent("Release")
    try executable(products.appendingPathComponent("swmux-launcher"))
    let override = root.appendingPathComponent(kind)
    if kind == "directory" {
      try FileManager.default.createDirectory(
        at: override,
        withIntermediateDirectories: true
      )
    } else if kind == "nonexecutable" {
      try Data().write(to: override)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: override.path
      )
    }
    let path = kind == "empty" ? "" : override.path
    #expect(throws: NativeTestProducts.Failure.launcherUnavailable(path)) {
      try NativeTestProducts.launcherPath(
        environment: ["SWMUX_LAUNCHER": path],
        bundleURL: products.appendingPathComponent("ExampleTests.xctest")
      )
    }
  }
}
#endif
