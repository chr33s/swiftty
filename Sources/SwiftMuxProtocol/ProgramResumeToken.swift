import Foundation
import Security

/// `OSC7577_TOKEN`: a fresh per-pane secret for OSC 7577. The launcher
/// installs it for the first process and strips any token that arrived
/// from a snapshot, the service, or another pane.
public enum ProgramResumeToken {
  public static let name = "OSC7577_TOKEN"

  /// 22...64 characters of `[A-Za-z0-9_-]`.
  public static func isValid(_ token: String) -> Bool {
    let count = token.utf8.count
    guard (22 ... 64).contains(count) else { return false }
    return token.utf8.allSatisfy { byte in
      byte &- 0x30 < 10 || (byte | 0x20) &- 0x61 < 26 || byte == 0x2D
        || byte == 0x5F
    }
  }

  /// 32 bytes from `SecRandomCopyBytes`, base64url without padding (43
  /// characters). A failed system call uses the Swift random generator.
  public static func generate() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      != errSecSuccess
    {
      for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
