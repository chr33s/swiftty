import Foundation
import SwifttyConfig

extension Configuration {
  func applyShellProfile(
    to session: inout SessionConfiguration,
    nativeShellPath: String?
  ) {
    guard let preferredShell else { return }
    let profile = shellProfiles[preferredShell.rawValue] ?? ShellLaunchProfile()
    switch preferredShell {
    case .system: session.command = nil
    case .bash:
      session.command = [profile.executable ?? "/bin/bash"] + profile.arguments
    case .zsh:
      session.command = [profile.executable ?? "/bin/zsh"] + profile.arguments
    case .swsh:
      session.command =
        [profile.executable ?? nativeShellPath ?? Self.nativeShellExecutable]
        + profile.arguments
    case .custom:
      // With no typed custom profile, retain the existing terminal.shell route.
      if let executable = profile.executable {
        session.command = [executable] + profile.arguments
      }
    }
    session.environment = profile.environment
    if let directory = profile.workingDirectory {
      session.workingDirectory = directory
    }
  }

  private static var nativeShellExecutable: String {
    if Bundle.main.bundleURL.pathExtension == "app" {
      return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/swsh")
        .path
    }
    if let adjacent = Bundle.main.executableURL?.deletingLastPathComponent()
      .appendingPathComponent("swsh"),
      FileManager.default.isExecutableFile(atPath: adjacent.path)
    {
      return adjacent.path
    }
    return "swsh"
  }
}
