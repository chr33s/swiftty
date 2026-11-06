#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension PrivateLauncher {
  func launch(
    command: PreparedCommand,
    executable: [UInt8],
    target: [UInt8],
    build: String,
    environment: [[UInt8]],
    state: ShellState,
    group: DarwinSpawn.Group,
    wiring initialWiring: [DarwinSpawn.Wiring],
    pipeDescriptors: [Int32],
    replySocket: Int32?,
    lookupFailure: Int32? = nil,
    supervisorPipe: Int32? = nil
  ) throws -> pid_t {
    var payload = LauncherPayload(
      build: build,
      executable: target,
      arguments: command.arguments,
      environment: environment,
      redirects: command.redirects
    )
    payload.lookupFailure = lookupFailure
    if let builtin = command.builtin {
      payload.kind = .builtin
      payload.builtinContext = BuiltinWorkerContext(
        builtin: builtin,
        arguments: command.arguments,
        state: state
      )
    }
    if let source = command.source {
      payload.kind = .source
      payload.builtinContext = nil
      var snapshot = state
      if let arguments = command.functionArguments {
        snapshot.setArguments(arguments)
      }
      payload.sourceContext = SourceWorkerContext(
        source: source,
        state: snapshot,
        functionArguments: command.functionArguments
      )
    }
    var forbidden = Set<Int32>([0, 1, 2] + pipeDescriptors)
    for wiring in initialWiring {
      switch wiring {
      case .duplicate(let source, let destination):
        forbidden.insert(source)
        forbidden.insert(destination)
      case .close(let destination): forbidden.insert(destination)
      }
    }
    for action in command.redirects {
      switch action {
      case .open(let fd, _, _), .close(let fd), .data(let fd, _):
        forbidden.insert(fd)
      case .duplicate(let fd, let source):
        forbidden.insert(fd);
        forbidden.insert(source)
      }
    }
    if let replySocket {
      forbidden.insert(replySocket)
      var reply: Int32 = 64
      while forbidden.contains(reply) { reply += 1 }
      forbidden.insert(reply)
      payload.kind = .descriptors
      payload.builtinContext = nil
      payload.replyDescriptor = reply
    }
    if let supervisorPipe {
      forbidden.insert(supervisorPipe)
      var lease: Int32 = 64
      while forbidden.contains(lease) { lease += 1 }
      forbidden.insert(lease)
      payload.supervisorDescriptor = lease
    }
    let file = try payload.write()
    forbidden.insert(file.withDescriptor { $0 })
    var inherited: Int32 = 64
    while forbidden.contains(inherited) { inherited += 1 }
    var wiring = initialWiring
    wiring.append(
      .duplicate(source: file.withDescriptor { $0 }, destination: inherited)
    )
    if let supervisorPipe, let lease = payload.supervisorDescriptor {
      wiring.append(.duplicate(source: supervisorPipe, destination: lease))
    }
    if let replySocket, let reply = payload.replyDescriptor {
      wiring.append(.duplicate(source: replySocket, destination: reply))
    }
    let option: String
    switch payload.kind {
    case .source: option = "--swsh-source"
    case .external: option = "--swsh-external"
    case .builtin: option = "--swsh-builtin"
    case .descriptors: option = "--swsh-descriptors"
    }
    return try DarwinSpawn()
      .launch(
        path: executable,
        arguments: [
          executable, Array(option.utf8), Array(String(inherited).utf8),
        ],
        environment: [],
        group: group,
        wiring: wiring,
        parentBuiltinSetup: replySocket != nil
      )
  }
}
