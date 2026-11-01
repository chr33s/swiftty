import Darwin

/// Completion is non-executing and runs in the driver's current directory context.
/// The first editor supports simple unquoted words; ambiguous lists never become syntax.
struct Completion {
  let state: ShellState

  func suffix(for source: [UInt8], candidates: [[UInt8]]? = nil) -> [UInt8]? {
    // Quoted, escaped and expanded words require a future syntax-aware editing contract.
    guard !source.contains(where: { [39, 34, 92, 36].contains($0) }) else {
      return nil
    }
    let boundary =
      source.lastIndex(where: { [32, 9, 10, 59, 124, 38].contains($0) })
      .map { $0 + 1 } ?? 0
    let token = Array(source[boundary...])
    let previous = source[..<boundary].reversed()
      .drop(while: { $0 == 32 || $0 == 9 }).first
    let commandPosition =
      previous == nil || [59, 124, 38, 10].contains(previous!)
    var matches: Set<[UInt8]> = []
    let command = String(
      decoding: source.prefix { $0 != 32 && $0 != 9 },
      as: UTF8.self
    )
    if !commandPosition, let values = candidates ?? state.completions[command] {
      matches.formUnion(values.filter { $0.starts(with: token) })
    } else if let slash = token.lastIndex(of: 47) {
      let directory = Array(token[...slash])
      let leaf = Array(token[(slash + 1)...])
      for name in names(in: directory) where name.starts(with: leaf) {
        if name.first == 46 && leaf.first != 46 { continue }
        let path = directory + name
        matches.insert(path + (isDirectory(path) ? [47] : []))
      }
    } else {
      for name in names(in: [46]) where name.starts(with: token) {
        if name.first == 46 && token.first != 46 { continue }
        matches.insert(name + (isDirectory(name) ? [47] : []))
      }
      if commandPosition {
        for function in state.functions.keys {
          let name = Array(function.utf8)
          if name.starts(with: token) { matches.insert(name) }
        }
        for builtin in Builtin.allCases {
          let name = Array(builtin.rawValue.utf8)
          if name.starts(with: token) { matches.insert(name) }
        }
        for directory in (state.variables["PATH"] ?? [])
          .split(separator: 58, omittingEmptySubsequences: false)
        {
          let path = directory.isEmpty ? [46] : Array(directory)
          for name in names(in: path) where name.starts(with: token) {
            if executable(path + [47] + name) { matches.insert(name) }
          }
        }
      }
    }
    let valid =
      matches.filter {
        !$0.contains(0) && !$0.contains(10) && !$0.contains(13)
          && String(validating: $0, as: UTF8.self) != nil
      }
      .sorted { $0.lexicographicallyPrecedes($1) }
    guard var common = valid.first else { return nil }
    for match in valid.dropFirst() {
      common = Array(zip(common, match).prefix { $0 == $1 }.map(\.0))
    }
    while String(validating: common, as: UTF8.self) == nil {
      common.removeLast()
    }
    guard common.count >= token.count else { return nil }
    var suffix: [UInt8] = []
    for byte in common.dropFirst(token.count) {
      if [
        32, 9, 10, 59, 124, 38, 60, 62, 36, 39, 34, 92, 42, 63, 96, 40, 41, 123,
        125, 91, 93, 35,
      ]
      .contains(byte) {
        suffix.append(92)
      }
      suffix.append(byte)
    }
    if valid.count == 1 && common.last != 47 { suffix.append(32) }
    return suffix.isEmpty ? nil : suffix
  }

  private func names(in path: [UInt8]) -> [[UInt8]] {
    guard !path.contains(0) else { return [] }
    let directory = (path + [0])
      .withUnsafeBytes {
        opendir($0.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
    guard let directory else { return [] }
    defer { closedir(directory) }
    var result: [[UInt8]] = []
    while let entry = readdir(directory) {
      let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
        Array(bytes.prefix { $0 != 0 })
      }
      if name != [46] && name != [46, 46] { result.append(name) }
    }
    return result
  }

  private func isDirectory(_ path: [UInt8]) -> Bool {
    (path + [0])
      .withUnsafeBytes {
        var info = stat()
        return stat($0.baseAddress!.assumingMemoryBound(to: CChar.self), &info)
          == 0 && (info.st_mode & S_IFMT) == S_IFDIR
      }
  }

  private func executable(_ path: [UInt8]) -> Bool {
    (path + [0])
      .withUnsafeBytes {
        access($0.baseAddress!.assumingMemoryBound(to: CChar.self), X_OK) == 0
      } && !isDirectory(path)
  }
}
