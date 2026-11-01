import Darwin

struct ExecutableLookup {
  enum Result {
    case executable([UInt8])
    case failure(Int32)
  }

  func resolve(
    _ name: [UInt8],
    state: ShellState,
    overlay: [String: [UInt8]]
  ) -> Result {
    guard !name.isEmpty, !name.contains(0) else { return .failure(127) }
    if name.contains(47) { return candidate(name) }
    let path =
      overlay["PATH"] ?? state.variables["PATH"] ?? Array("/usr/bin:/bin".utf8)
    guard !path.contains(0) else { return .failure(126) }
    var denied = false
    for directory in path.split(separator: 58, omittingEmptySubsequences: false)
    {
      let candidatePath =
        directory.isEmpty ? name : Array(directory) + [47] + name
      switch candidate(candidatePath) {
      case .executable: return .executable(candidatePath)
      case .failure(let status): if status == 126 { denied = true }
      }
    }
    return .failure(denied ? 126 : 127)
  }

  private func candidate(_ path: [UInt8]) -> Result {
    (path + [0])
      .withUnsafeBytes { buffer in
        let pointer = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        var info = stat()
        if stat(pointer, &info) != 0 {
          return .failure(errno == ENOENT || errno == ENOTDIR ? 127 : 126)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, access(pointer, X_OK) == 0
        else { return .failure(126) }
        return .executable(path)
      }
  }
}
