import Darwin

/// The execution driver alone may change the process cwd. The handle pins its identity.
struct WorkingDirectory: ~Copyable {
  private var handle: OwnedFD

  init() throws {
    handle = try OwnedFD.open([46], flags: O_RDONLY | O_DIRECTORY)
  }

  mutating func change(to path: [UInt8]) throws {
    let next = try OwnedFD.open(path, flags: O_RDONLY | O_DIRECTORY)
    try next.withDescriptor { descriptor in
      guard fchdir(descriptor) == 0 else { throw SystemFailure("chdir") }
    }
    handle = consume next
  }

  borrowing func physicalPath() throws -> [UInt8] {
    guard let path = getcwd(nil, 0) else { throw SystemFailure("getcwd") }
    defer { free(path) }
    return Array(UnsafeRawBufferPointer(start: path, count: strlen(path)))
  }
}
