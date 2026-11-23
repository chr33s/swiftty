/// The name of the program a pane runs, as the service reports it for the
/// pane's icon: a bare executable name, never a path or arguments.
public enum ProgramName {
  public static let maxLength = 64

  /// `raw` reduced to a bare name: the last path component, without a
  /// login shell's leading "-", or nil when nothing usable remains or it
  /// holds anything beyond letters, digits and `.`, `_`, `+`, `-`.
  public static func sanitize(_ raw: Substring) -> String? {
    var name = raw.split(separator: "/").last ?? ""
    if name.first == "-" { name = name.dropFirst() }
    guard !name.isEmpty, name.utf8.count <= maxLength,
      name.unicodeScalars.allSatisfy({
        $0.isASCII
          && ($0.properties.isAlphabetic || ("0" ... "9").contains($0)
            || "._+-".unicodeScalars.contains($0))
      })
    else { return nil }
    return String(name)
  }

  public static func sanitize(_ raw: String) -> String? { sanitize(raw[...]) }

  /// The program a shell command line runs: its first word after
  /// environment assignments and wrappers that run the next word
  /// (`sudo`, `env`, `time`, `nohup`, `exec`, `command`, `nice`).
  public static func command(_ line: String) -> String? {
    let wrappers: Set<Substring> = [
      "sudo", "env", "time", "nohup", "exec", "command", "nice", "builtin",
    ]
    for word in line.split(whereSeparator: \.isWhitespace) {
      if word.contains("=") || word.hasPrefix("-") || wrappers.contains(word) {
        continue
      }
      return sanitize(word)
    }
    return nil
  }

  /// Programs that pass the terminal to another host, where the remote
  /// shell's command (OSC 133) says more than the local process.
  public static let remoteShells: Set<String> = [
    "ssh", "mosh-client", "mosh", "et", "autossh",
  ]
}
