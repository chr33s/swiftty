import Darwin
import Foundation
import Security
import SwiftMuxProtocol

/// Shared structural/signature checks for owner-controlled immutable artifacts.
/// Passing validation is not permission to mutate an active installation.
package enum GuardianArtifactValidation {
  package static func validateTree(_ directory: URL) throws {
    try check(directory, directory: true)
    var failed = false
    guard
      let entries = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil,
        errorHandler: { _, _ in
          failed = true;
          return false
        }
      )
    else { throw MuxError(.unauthorized, "cannot enumerate build") }
    var count = 0
    var total: Int64 = 0
    for case let file as URL in entries {
      var info = stat()
      guard lstat(file.path, &info) == 0 else {
        throw MuxError(.unauthorized, "cannot inspect build file")
      }
      let size = try check(file, directory: info.st_mode & S_IFMT == S_IFDIR)
      count += 1
      guard size >= 0, count <= 16384, size <= (1 << 30) - total else {
        throw MuxError(.resourceLimit, "artifact exceeds validation budget")
      }
      total += size
    }
    guard !failed else {
      throw MuxError(.unauthorized, "incomplete build enumeration")
    }
  }

  @discardableResult
  package static func check(
    _ url: URL,
    directory: Bool,
    privateDirectory: Bool = false
  ) throws -> Int64 {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
      info.st_mode & (privateDirectory ? 0o077 : 0o022) == 0,
      directory || info.st_nlink == 1
    else {
      throw MuxError(.unauthorized, "unsafe artifact path or permissions")
    }
    return directory ? 0 : info.st_size
  }
  package static func validateSignature(
    _ path: String,
    requirement: String
  ) throws {
    var code: SecStaticCode?
    var rule: SecRequirement?
    guard
      SecStaticCodeCreateWithPath(
        URL(fileURLWithPath: path) as CFURL,
        [],
        &code
      ) == errSecSuccess,
      SecRequirementCreateWithString(requirement as CFString, [], &rule)
        == errSecSuccess, let code, let rule,
      SecStaticCodeCheckValidity(
        code,
        SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode),
        rule
      ) == errSecSuccess
    else {
      throw MuxError(.unauthorized, "artifact signature validation failed")
    }
  }
}
