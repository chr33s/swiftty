import Darwin
import Dispatch
import Foundation
import RoamingKit
import ScreenProtocol
import SessionCore
import SwifttyEngine
import TTYKit

/// Shows one roaming session in the outer terminal, mosh-style: the host
/// sends complete screens, this draws them with a cell diff, and input
/// travels as semantic operations. Network changes and sleep are the
/// client's problem; this frontend only reports them.
///
/// The escape prefix is Ctrl-^ (0x1E): `.` detaches and leaves the host
/// session running, `k` terminates it, and a second Ctrl-^ sends one.
@MainActor
public final class RoamingTerminalClient {
  public enum Outcome: Equatable, Sendable {
    /// Left with the host session retained; resume with this ID.
    case detached(SessionID?)
    /// The remote program exited.
    case exited(Int32?)
    /// The host no longer has the session.
    case lost(String)
    /// The user terminated the session.
    case terminated
  }

  public static let escapeByte: UInt8 = 0x1E

  let client: RoamingClient
  let sink: TTYPresentationSink
  let tty: RawTTY
  private var decoder = InputDecoder(maxPasteBytes: RSTLimits.maxPasteBytes)
  private var renderer = DiffRenderer()
  /// Kitty graphics in the outer terminal (spec.graphics.md §16.5).
  public let graphics: TTYGraphics
  /// The outer terminal's kitty support is being probed.
  private var detectingGraphics = false
  private var size: (columns: Int, rows: Int)
  private var frame: PresentationFrame?
  private var status = RoamingStatus()
  private var notice: String?
  private var noticeTimer: DispatchWorkItem?
  private var escapeTimer: DispatchWorkItem?
  private var prefixPending = false
  private var pump: OrderedInputPump?
  private var sources: [any DispatchSourceProtocol] = []
  private var signalDispositions: [(Int32, sigaction)] = []
  private var rawMode = false
  private var outcome: Outcome?
  private var finished = false
  private var continuation: CheckedContinuation<Outcome, Never>?

  /// Stops the process after an external SIGTSTP; replaced in tests.
  package var stopProcess: () -> Void = { _ = kill(getpid(), SIGSTOP) }

  /// Called once the SSH bootstrap succeeded, just before raw mode: the
  /// last moment a prompt on the terminal can be answered.
  public var willEnterRawMode: (() -> Void)?

  /// `client` must have been built with `sink` as its presentation sink.
  /// `graphics` nil probes the outer terminal for kitty graphics.
  public init(
    client: RoamingClient,
    sink: TTYPresentationSink,
    tty: RawTTY,
    graphics requested: TTYGraphics.Mode? = nil
  ) {
    self.client = client
    self.sink = sink
    self.tty = tty
    size = tty.size
    graphics = TTYGraphics(requested: requested)
    detectingGraphics = requested == nil
  }

  /// The grid to request from the host: the whole outer terminal.
  public var grid: GridSize { GridSize(columns: size.columns, rows: size.rows) }

  /// Bootstraps over SSH in cooked mode, so host-key and credential
  /// prompts work, then enters raw mode and runs until the session ends
  /// or the user detaches.
  public func run(
    _ target: RoamingTarget
  ) async throws(RoamingClientError) -> Outcome {
    let client = self.client
    sink.setFrameHandler { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.frameAvailable() }
      }
    }
    await client.setStatusHandler { [weak self] status in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.statusChanged(status) }
      }
    }
    await client.proposeGrid(columns: size.columns, rows: size.rows)
    if let cell = tty.cellPixelSize {
      await client.setCellPixelSize(width: cell.width, height: cell.height)
    }
    if graphics.mode == .off, !detectingGraphics {
      await client.setImageVariant(.off)
    }
    do { try await client.start(target) } catch {
      sink.close()
      await client.setStatusHandler(nil)
      throw error
    }
    // A status handler may already have finished the run while `start`
    // was suspended; never enter raw mode or install sources after that.
    if outcome != nil { return await settled() }
    pump = OrderedInputPump(
      submit: { await client.submit($0) },
      onResult: { [weak self] _, result in
        guard case let .refused(refusal) = result else { return }
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.refused(refusal) }
        }
      }
    )
    willEnterRawMode?()
    do {
      try tty.enter()
      rawMode = true
      try installSources()
    } catch { return await finish(.lost("\(error)"), close: .detach) }
    if detectingGraphics { probeGraphics() }
    redraw()
    return await settled()
  }

  /// The outcome once teardown has completed.
  private func settled() async -> Outcome {
    if finished, let outcome { return outcome }
    return await withCheckedContinuation { continuation = $0 }
  }

  /// Forwards a network path change so the client probes at once
  /// instead of waiting for its liveness deadline.
  public func pathChanged() {
    let client = client
    Task { await client.pathChanged() }
  }

  // MARK: Events

  private func frameAvailable() {
    guard outcome == nil, let next = sink.take() else { return }
    frame = next
    redraw()
  }

  private func statusChanged(_ next: RoamingStatus) {
    guard outcome == nil else { return }
    status = next
    switch next.state {
    case .sessionExited: finishInBackground(.exited(next.exitStatus))
    case .sessionLost:
      finishInBackground(
        .lost(Self.describe(next.lastFailure) ?? "session lost")
      )
    case .userClosed: finishInBackground(.detached(next.sessionID))
    default: redraw()
    }
  }

  private func refused(_ refusal: InputRefusal) {
    switch refusal {
    case .notActive: show("not connected; input was not sent")
    case .backpressure: show("input queue full; input was not sent")
    case .invalid: show("input too large; it was not sent")
    case .closed: break
    }
  }

  // MARK: Input

  private func readInput() {
    guard outcome == nil else { return }
    guard let bytes = tty.read() else {
      finishInBackground(.detached(status.sessionID))
      return
    }
    guard !bytes.isEmpty else { return }
    feed(bytes)
  }

  func feed(_ bytes: [UInt8]) {
    var pass: [UInt8] = []
    for byte in bytes {
      guard outcome == nil else { return }
      if prefixPending {
        prefixPending = false
        switch byte {
        case UInt8(ascii: "."):
          deliver(&pass)
          finishInBackground(.detached(status.sessionID))
          return
        case UInt8(ascii: "k"):
          deliver(&pass)
          finishInBackground(.terminated, close: .terminate)
          return
        case Self.escapeByte: pass.append(byte)
        default: pass += [Self.escapeByte, byte]
        }
      } else if byte == Self.escapeByte {
        prefixPending = true
      } else {
        pass.append(byte)
      }
    }
    deliver(&pass)
    if prefixPending { show("Ctrl-^ .  detach    Ctrl-^ k  terminate") }
  }

  private func deliver(_ bytes: inout [UInt8]) {
    defer { bytes = [] }
    for event in decoder.feed(bytes) { submit(event) }
    escapeTimer?.cancel()
    guard decoder.hasPending else { return }
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        for event in self.decoder.flushPending() { self.submit(event) }
      }
    }
    escapeTimer = work
    DispatchQueue.main.asyncAfter(
      deadline: .now()
        + .milliseconds(InputDecoder.defaultEscapeDelayMilliseconds),
      execute: work
    )
  }

  /// Asks the outer terminal whether it draws kitty images; no answer
  /// within 500 ms means half-blocks.
  private func probeGraphics() {
    _ = tty.write(graphics.probe)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
      [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.detectingGraphics else { return }
        self.detectingGraphics = false
        if self.graphics.mode == .off { self.graphics.mode = .halfBlocks }
        if self.graphics.tmux, self.graphics.mode != .kitty {
          self.show(
            "images as half-blocks; for kitty images: set -g allow-passthrough on"
          )
        }
        self.redraw()
      }
    }
  }

  private func submit(_ event: DecodedInput) {
    if case let .reply(reply) = event {
      if detectingGraphics, graphics.detect(reply) {
        detectingGraphics = false
        redraw()
      }
      return
    }
    guard let input = SurfaceInput(event) else {
      if case .paste(_, truncated: true) = event {
        show("paste too large; it was not sent")
      }
      return
    }
    pump?.enqueue(input)
  }

  // MARK: Drawing

  private func redraw() {
    guard rawMode, outcome == nil else { return }
    var screen =
      frame.map { ScreenBuffer($0, columns: size.columns, rows: size.rows) }
      ?? ScreenBuffer(columns: size.columns, rows: size.rows)
    if let banner = banner() {
      let style = OuterStyle(foreground: .palette(0), background: .palette(3))
      screen.write(
        String(repeating: " ", count: screen.columns),
        x: 0,
        y: 0,
        style: style
      )
      screen.write(" swroam: " + banner, x: 0, y: 0, style: style)
      screen.rowKeys[0] = nil
    }
    var images: [UInt8] = []
    if let frame, !frame.images.isEmpty {
      images = graphics.compose(
        frame.images,
        hostCell: frame.imageCellSize,
        into: &screen
      )
    }
    let bytes = images + renderer.update(to: screen)
    if tty.write(bytes) {
      renderer.commit(screen)
    } else {
      renderer.invalidate()
      graphics.invalidate()
    }
  }

  /// Connection trouble or a transient notice, shown over the top row.
  private func banner() -> String? {
    if let notice { return notice }
    switch status.state {
    case .active: return nil
    case .idle, .sshBootstrap: return "connecting…"
    case .attaching: return frame == nil ? "attaching…" : "reattaching…"
    case .suspect:
      let since = status.lastScreenAt.map {
        " (last contact \(Int(-$0.timeIntervalSinceNow))s ago)"
      }
      return "no reply from host" + (since ?? "")
    case .reconnecting:
      let why = Self.describe(status.lastFailure).map { ": \($0)" } ?? ""
      return "reconnecting, attempt \(status.reconnectAttempt)\(why)"
    case .backgroundDetached: return "detached"
    case .sessionExited, .sessionLost, .userClosed: return nil
    }
  }

  private func show(_ message: String) {
    notice = message
    noticeTimer?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.notice = nil
        self?.redraw()
      }
    }
    noticeTimer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    redraw()
  }

  static func describe(_ failure: RoamingFailure?) -> String? {
    switch failure {
    case nil: nil
    case .unreachable: "host unreachable over SSH"
    case .endpointUnreachable: "roaming endpoint unreachable"
    case .hostKeyRejected: "SSH host key not trusted"
    case .authenticationFailed: "SSH authentication failed"
    case .credentialUnavailable: "SSH key unavailable"
    case .protocolViolation: "protocol error"
    case let .attachRejected(code): "attach rejected (\(code))"
    case let .bootstrapRejected(code): "bootstrap rejected (\(code))"
    case .attachTimedOut: "attach timed out"
    case .connectionLost: "connection lost"
    case .stale: "session state stale"
    case .snapshotRejected: "invalid screen from host"
    case .resizeUnavailable: "resize unavailable"
    case let .pendingInputAbandoned(count):
      "\(count) unsent input operation(s) dropped"
    }
  }

  // MARK: Sources

  private func installSources() throws {
    let read = DispatchSource.makeReadSource(
      fileDescriptor: tty.input,
      queue: .main
    )
    read.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.readInput() }
    }
    start(read)
    // Signal handlers only notify normal execution code.
    for sig in [SIGWINCH, SIGTERM, SIGHUP, SIGCONT, SIGINT, SIGQUIT, SIGTSTP] {
      var ignored = sigaction()
      ignored.__sigaction_u.__sa_handler = SIG_IGN
      sigemptyset(&ignored.sa_mask)
      var previous = sigaction()
      guard sigaction(sig, &ignored, &previous) == 0 else {
        throw POSIXFailure("sigaction")
      }
      signalDispositions.append((sig, previous))
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.handleSignal(sig) }
      }
      start(source)
    }
  }

  private func start(_ source: any DispatchSourceProtocol) {
    source.resume()
    sources.append(source)
  }

  /// Delivered by the signal sources; tests call it directly, since a real
  /// SIGTSTP reaches every client in the process.
  package func handleSignal(_ sig: Int32) {
    guard outcome == nil else { return }
    switch sig {
    case SIGWINCH:
      size = tty.size
      renderer.invalidate()
      graphics.invalidate()
      let (columns, rows) = size
      let client = client
      Task { await client.proposeGrid(columns: columns, rows: rows) }
      redraw()
    case SIGTSTP:
      // An external stop (Ctrl-Z itself reaches the remote session as a
      // byte): leave the outer terminal usable while stopped. SIGSTOP,
      // not SIGTSTP, so the stop cannot re-trigger this source.
      tty.restore()
      stopProcess()
    case SIGCONT:
      try? tty.enter()
      renderer.invalidate()
      graphics.invalidate()
      redraw()
    default: finishInBackground(.detached(status.sessionID))
    }
  }

  // MARK: Teardown

  private func finishInBackground(
    _ result: Outcome,
    close mode: RoamingCloseMode = .detach
  ) { Task { _ = await finish(result, close: mode) } }

  @discardableResult
  private func finish(
    _ result: Outcome,
    close mode: RoamingCloseMode
  ) async -> Outcome {
    if let outcome { return outcome }
    outcome = result
    escapeTimer?.cancel()
    noticeTimer?.cancel()
    pump?.close()
    sink.close()
    for source in sources { source.cancel() }
    sources = []
    if rawMode {
      tty.restore()
      rawMode = false
    }
    for (sig, previous) in signalDispositions {
      var disposition = previous
      _ = sigaction(sig, &disposition, nil)
    }
    signalDispositions = []
    await client.setStatusHandler(nil)
    if !(status.state.isTerminal) { await client.close(mode) }
    finished = true
    continuation?.resume(returning: result)
    continuation = nil
    return result
  }
}
