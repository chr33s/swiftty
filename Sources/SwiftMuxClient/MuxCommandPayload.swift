import SwiftMuxProtocol

/// Bounds retained payload before dispatch or JSON encoding. Charges count
/// UTF-8 text and logical container storage, not process heap allocations.
private struct MuxCommandPayload {
  private let limit: Int
  private var bytes = 256  // Fixed command fields and container headers.

  static func bytes(_ command: MuxCommand, limit: Int) throws(MuxError) -> Int {
    var payload = MuxCommandPayload(limit: limit)
    guard limit >= payload.bytes else { throw tooLarge }
    try payload.count(command)
    return payload.bytes
  }

  private static var tooLarge: MuxError {
    MuxError(.resourceLimit, "client command payload is too large")
  }

  private mutating func add(_ amount: Int) throws(MuxError) {
    guard amount >= 0, amount <= limit - bytes else { throw Self.tooLarge }
    bytes += amount
  }

  private mutating func add(count: Int, stride: Int) throws(MuxError) {
    guard count <= (limit - bytes) / stride else { throw Self.tooLarge }
    bytes += count * stride
  }

  private mutating func text(_ value: String?) throws(MuxError) {
    if let value { try add(value.utf8.count) }
  }

  private mutating func selector(_ selector: WorkspaceSelector) throws(MuxError)
  { if case let .name(name) = selector { try text(name) } }

  private mutating func launch(_ launch: LaunchSpec?) throws(MuxError) {
    guard let launch else { return }
    try add(MemoryLayout<LaunchSpec>.stride)
    try text(launch.workingDirectory)
    if let arguments = launch.command {
      try add(count: arguments.count, stride: MemoryLayout<String>.stride)
      for argument in arguments { try text(argument) }
    }
    try add(
      count: launch.environment.count,
      stride: MemoryLayout<(String, String)>.stride,
    )
    for (key, value) in launch.environment {
      try text(key)
      try text(value)
    }
  }

  private mutating func clipboard(
    _ contents: [MuxClipboardContent]
  ) throws(MuxError) {
    try add(
      count: contents.count,
      stride: MemoryLayout<MuxClipboardContent>.stride
    )
    for content in contents {
      try text(content.mime)
      try add(content.data.count)
    }
  }

  private mutating func count(_ command: MuxCommand) throws(MuxError) {
    // Exhaustive: a new command case must explicitly account for its payload.
    switch command {
    case let .newWorkspace(request):
      try text(request.name)
      try launch(request.launch)
    case let .endWorkspace(value), let .switchWorkspace(value),
      let .takeover(value, _):
      try selector(value)
    case let .attach(request): try selector(request.selector)
    case let .renameWorkspace(value, name):
      try selector(value)
      try text(name)
    case let .setTheme(theme):
      try add(
        count: theme.palette.colors.count,
        stride: MemoryLayout<UInt32>.stride,
      )
    case let .inbox(query): try text(query.cursor)
    case let .locateAttention(reference), let .markSeen(reference),
      let .markReviewed(reference), let .snooze(reference, _):
      try text(reference.source.recordPath)
    case let .newTab(name, spec):
      try text(name)
      try launch(spec)
    case let .split(_, _, spec): try launch(spec)
    case let .renameTab(_, name): try text(name)
    case let .setSplitRatio(_, path, _):
      try add(count: path.count, stride: MemoryLayout<Bool>.stride)
    case let .setGeometry(batch):
      try add(
        count: batch.entries.count,
        stride: MemoryLayout<GeometryBatch.Entry>.stride,
      )
    case let .setSubscriptions(panes):
      try add(count: panes.count, stride: MemoryLayout<PaneID>.stride)
    case .setViewport: try add(MemoryLayout<ViewportRequest>.stride)
    case let .automationKey(_, shortcut): try text(shortcut)
    case .subscribeAutomation, .automationFocus: break
    case let .search(_, query): try text(query)
    case let .clipboardReadResult(_, _, .success(available, contents, _)):
      try add(count: available.count, stride: MemoryLayout<String>.stride)
      for mime in available { try text(mime) }
      try clipboard(contents)
    case .clipboardReadResult, .clipboardWriteResult: break
    case .status, .listWorkspaces, .detachActive, .endAllWorkspaces, .quiesce,
      .detach, .observeWorkspaces, .subscribeInbox, .selectTab, .endTab,
      .focusPane, .toggleZoom, .endPane, .scroll, .searchStep, .endSearch,
      .clearScreen, .resetTerminal, .link, .commandOutput:
      break
    }
  }
}

extension MuxCommandAdmission {
  static func bytes(_ command: MuxCommand) throws(MuxError) -> Int {
    try MuxCommandPayload.bytes(command, limit: maxBytes)
  }
}
