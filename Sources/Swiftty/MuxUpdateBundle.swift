import Darwin
import Foundation
import SwiftMuxProtocol

/// Structural preflight for the packaged app, independent of registration.
/// This does not establish signature trust or make the selected files immutable.
enum MuxUpdateBundle {
  struct Invalid: Error, CustomStringConvertible { let description: String }

  static func validate(
    _ staged: URL,
    replacing current: URL,
    beforeMetadataOpenForTesting: @Sendable (URL) throws -> Void = { _ in }
  ) throws {
    guard staged.isFileURL, current.isFileURL else {
      throw Invalid(description: "Choose a local app bundle.")
    }
    // Replacement operates on the supplied directory entries, so a
    // symlink root cannot stand in for the directory validated below.
    // A final dot component follows that link and cannot be replaced as
    // a directory entry, even though its attributes describe a directory.
    for root in [staged, current] {
      guard root.lastPathComponent != ".", root.lastPathComponent != "..",
        try FileManager.default.attributesOfItem(atPath: root.path)[.type]
          as? FileAttributeType == .typeDirectory
      else {
        throw Invalid(
          description:
            "The update and installed app must be actual directories."
        )
      }
    }
    let source = staged.standardizedFileURL.resolvingSymlinksInPath()
    let destination = current.standardizedFileURL.resolvingSymlinksInPath()
    guard source.isFileURL, destination.isFileURL,
      !source.pathComponents.starts(with: destination.pathComponents),
      !destination.pathComponents.starts(with: source.pathComponents)
    else {
      throw Invalid(
        description: "Choose a separate copy of the updated Swiftty app."
      )
    }
    let sourceAttributes = try FileManager.default.attributesOfItem(
      atPath: source.path
    )
    let destinationAttributes = try FileManager.default.attributesOfItem(
      atPath: destination.path
    )
    if let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
      let sourceFile = sourceAttributes[.systemFileNumber] as? NSNumber,
      sourceDevice == destinationAttributes[.systemNumber] as? NSNumber,
      sourceFile == destinationAttributes[.systemFileNumber] as? NSNumber
    {
      throw Invalid(
        description: "Choose a separate copy of the updated Swiftty app."
      )
    }
    let installed = try plist(
      destination.appendingPathComponent("Contents/Info.plist"),
      inside: destination,
      beforeOpen: beforeMetadataOpenForTesting
    )
    let candidate = try plist(
      source.appendingPathComponent("Contents/Info.plist"),
      inside: source,
      beforeOpen: beforeMetadataOpenForTesting
    )
    guard let identifier = installed["CFBundleIdentifier"] as? String,
      !identifier.isEmpty,
      candidate["CFBundleIdentifier"] as? String == identifier,
      candidate["CFBundlePackageType"] as? String == "APPL",
      candidate["CFBundleExecutable"] as? String == "swiftty"
    else {
      throw Invalid(
        description:
          "The selected bundle is not an update for this Swiftty app."
      )
    }
    for name in [
      "swiftty", "swiftmux-agent", "swmux-launcher", "swmux", "swsh",
    ] {
      let file = source.appendingPathComponent("Contents/MacOS/\(name)")
        .resolvingSymlinksInPath()
      guard file.pathComponents.starts(with: source.pathComponents),
        FileManager.default.isExecutableFile(atPath: file.path),
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.type])
          as? FileAttributeType == .typeRegular
      else {
        throw Invalid(
          description:
            "The selected app is missing its bundled \(name) executable."
        )
      }
    }
    let agent = try plist(
      source.appendingPathComponent(
        "Contents/Library/LaunchAgents/\(SMX.agentPlistName)"
      ),
      inside: source,
      beforeOpen: beforeMetadataOpenForTesting
    )
    guard agent["Label"] as? String == SMX.defaultMachService,
      agent["BundleProgram"] as? String == "Contents/MacOS/swiftmux-agent",
      (agent["AssociatedBundleIdentifiers"] as? [String])?.contains(identifier)
        == true,
      (agent["MachServices"] as? [String: Any])?[SMX.defaultMachService]
        as? Bool == true
    else {
      throw Invalid(
        description:
          "The selected app has an incompatible SwiftMux helper configuration."
      )
    }
  }

  private static func plist(
    _ input: URL,
    inside root: URL,
    beforeOpen: @Sendable (URL) throws -> Void
  ) throws -> [String: Any] {
    let file = input.resolvingSymlinksInPath()
    guard file.pathComponents.starts(with: root.pathComponents) else {
      throw Invalid(
        description: "The app metadata must be contained in its bundle."
      )
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw Invalid(description: "The app metadata must be a regular file.")
    }
    let physicalRoot = try canonicalPath(root)
    let physicalFile = try canonicalPath(file)
    guard
      (physicalFile as NSString).pathComponents
        .starts(with: (physicalRoot as NSString).pathComponents)
    else {
      throw Invalid(
        description: "The app metadata must be contained in its bundle."
      )
    }
    try beforeOpen(file)
    let descriptor = try openMetadata(physicalFile)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw Invalid(description: "The app metadata must be a regular file.")
    }
    let limit = 256 * 1024
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit,
      let value = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any]
    else {
      throw Invalid(description: "The app metadata is invalid or too large.")
    }
    return value
  }

  /// The path was resolved and checked above. Walk that exact path with
  /// directory descriptors so a replaced ancestor cannot redirect the open.
  private static func openMetadata(_ path: String) throws -> Int32 {
    let components = (path as NSString).pathComponents
    guard components.first == "/", components.count > 1,
      let name = components.last
    else {
      throw Invalid(description: "The app metadata must have an absolute path.")
    }
    let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    // Traversal needs search permission, not permission to list the directory.
    let directoryFlags = O_SEARCH | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    var directory = Darwin.open("/", directoryFlags)
    guard directory >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = Darwin.close(directory) }
    for component in components.dropFirst().dropLast() {
      let next = Darwin.openat(directory, component, directoryFlags)
      guard next >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      _ = Darwin.close(directory)
      directory = next
    }
    let descriptor = Darwin.openat(directory, name, flags)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
  }

  private static func canonicalPath(_ file: URL) throws -> String {
    guard let path = Darwin.realpath(file.path, nil) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(path) }
    return String(cString: path)
  }
}
