/// A fixed set of shell choices, not an interpreter plugin registry.
public enum ShellKind: String, Codable, CaseIterable, Sendable {
  case system, bash, zsh, swsh, custom
}

/// Exact argv tail and launch context. Login/interactive flags belong in arguments;
/// selecting a profile never inserts startup flags or interprets its argument strings.
public struct ShellLaunchProfile: Codable, Equatable, Sendable {
  public var executable: String?
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectory: String?

  public init(
    executable: String? = nil,
    arguments: [String] = [],
    environment: [String: String] = [:],
    workingDirectory: String? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
  }

  enum CodingKeys: String, CodingKey {
    case executable, arguments, environment
    case workingDirectory = "working_directory"
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    executable = try values.decodeIfPresent(String.self, forKey: .executable)
    arguments =
      try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
    environment =
      try values.decodeIfPresent([String: String].self, forKey: .environment)
      ?? [:]
    workingDirectory = try values.decodeIfPresent(
      String.self,
      forKey: .workingDirectory
    )
  }
}
