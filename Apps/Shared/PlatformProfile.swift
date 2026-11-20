import SwifttyCore

/// The direct-client product a build represents (spec.roaming.md §2.1).
///
/// Mac Catalyst is its own product, not a flavour of iOS or macOS; the
/// watch companion is not a direct client and has no profile here.
public enum PlatformKind: String, Hashable, Sendable, CaseIterable {
  /// iPhone and iPad (iOS/iPadOS 27).
  case mobile
  /// UIKit-derived Mac Catalyst app.
  case catalyst
  /// Windowed visionOS app.
  case vision
  /// Focus-first tvOS app.
  case tv

  /// The product this binary was compiled as. Native macOS builds exist
  /// only for the SwiftPM test host and behave as the desktop client.
  public static var current: PlatformKind {
    #if os(macOS) || targetEnvironment(macCatalyst)
      .catalyst
    #elseif os(visionOS)
      .vision
    #elseif os(tvOS)
      .tv
    #else
      .mobile
    #endif
  }
}

/// Per-platform capability profile (spec §2.1, §2.3, §A.6.2).
///
/// UI shows only what the profile enables; unavailable actions are hidden
/// rather than presented as nonfunctional controls.
public struct PlatformProfile: Hashable, Sendable {
  public enum Tier: String, Hashable, Sendable {
    /// SSH shell/exec, roaming terminal and SFTP.
    case fullClient
    /// SSH shell/exec and roaming terminal only (tvOS v1).
    case terminalOnly
  }

  public let kind: PlatformKind
  public let tier: Tier
  /// Ordinary SSH shell/exec sessions.
  public let sshShell: Bool
  /// RST/1 roaming terminal attachments (one active per client app).
  public let roamingTerminal: Bool
  /// SFTP browsing and regular-file transfer (full clients only).
  public let sftp: Bool
  /// Local copy/paste through the system pasteboard.
  public let clipboard: Bool
  /// Platform document import/export for SFTP.
  public let documentAccess: Bool
  /// Navigation is driven by focus (remote/keyboard) rather than touch.
  public let focusFirst: Bool
  /// May host the watch companion bridge. On iOS this is still subject to
  /// a runtime check: only an iPhone can pair with a watch.
  public let companionBridge: Bool
  /// Browses for Macs advertising `_swiftty._tcp` (Nearby Macs). Initial
  /// scope: iPhone and iPad (spec.connection-setup.md §1).
  public var nearbyDiscovery: Bool { kind == .mobile }
  /// Scans a Mac's connection code with the camera (MobileClient only,
  /// the one target declaring camera use).
  public var codeScanning: Bool { kind == .mobile }
  /// Accepts a pasted connection code; needs no camera or network.
  public var codeImport: Bool { !focusFirst }
  /// Imports OpenSSH private keys from a file or an explicit paste
  /// (spec.ssh-identity.md §3.2: not on tvOS in the first release).
  public var keyImport: Bool { kind != .tv }
  /// iCloud Keychain identities and CloudKit profile/metadata sync
  /// (spec.ssh-identity.md §3.2: not on tvOS in the first release).
  public var cloudSync: Bool { kind != .tv }

  /// What a terminal surface may offer for a roaming session here.
  public var roamingSurface: SurfaceCapabilities {
    var caps = SurfaceCapabilities.roaming
    caps.localCopy = clipboard
    caps.paste = clipboard
    return caps
  }

  /// What a terminal surface may offer for an ordinary SSH session here.
  /// Remote clipboard writes and URL opening stay off for remote content
  /// (spec §12), and there is no local process to act on.
  public var sshSurface: SurfaceCapabilities {
    var caps = SurfaceCapabilities.full
    caps.remoteClipboardWrites = false
    caps.openURLs = false
    caps.localProcess = false
    caps.mouseReporting = false
    caps.localCopy = clipboard
    caps.paste = clipboard
    return caps
  }

  public static func profile(for kind: PlatformKind) -> PlatformProfile {
    switch kind {
    case .mobile:
      PlatformProfile(
        kind: kind, tier: .fullClient, sshShell: true, roamingTerminal: true,
        sftp: true, clipboard: true, documentAccess: true,
        focusFirst: false, companionBridge: true
      )
    case .catalyst:
      PlatformProfile(
        kind: kind, tier: .fullClient, sshShell: true, roamingTerminal: true,
        sftp: true, clipboard: true, documentAccess: true,
        focusFirst: false, companionBridge: false
      )
    case .vision:
      PlatformProfile(
        kind: kind, tier: .fullClient, sshShell: true, roamingTerminal: true,
        sftp: true, clipboard: true, documentAccess: true,
        focusFirst: false, companionBridge: false
      )
    case .tv:
      PlatformProfile(
        kind: kind, tier: .terminalOnly, sshShell: true, roamingTerminal: true,
        sftp: false, clipboard: false, documentAccess: false,
        focusFirst: true, companionBridge: false
      )
    }
  }

  public static var current: PlatformProfile { profile(for: .current) }
}
