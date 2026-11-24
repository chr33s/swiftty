import AppKit
import SwiftMuxProtocol
import SwifttyCore
import SwifttyMac

/// Kitty clipboard requests from panes (OSC 5522): reads the user handed
/// over (a paste event's follow-up, a type listing, a remembered password)
/// are served at once; other reads and every write ask first.
extension MuxWorkspaceController {
  /// What native windows ask of the service: the standard set plus
  /// clipboard requests, which they answer with the pasteboard, and pane
  /// programs, which pick tab and header icons.
  static let clientCapabilities = ClientCapabilities.supported.union([
    .clipboardRequests, .paneProgram, .images,
  ])

  func handleClipboardRead(_ request: MuxClipboardRead) {
    guard request.granted || request.mimes.isEmpty else {
      ask(
        "Allow Clipboard Access?",
        KittyClipboardPolicy.readMessage(
          name: request.name,
          mimes: request.mimes
        ),
        canRemember: request.canRemember
      ) { [weak self] answer in self?.answerRead(request, answer) }
      return
    }
    answerRead(request, .allow)
  }

  func handleClipboardWrite(_ request: MuxClipboardWrite) {
    guard !request.granted else {
      answerWrite(request, .allow)
      return
    }
    ask(
      "Allow Clipboard Change?",
      KittyClipboardPolicy.writeMessage(
        name: request.name,
        mimes: request.contents.map(\.mime)
      ),
      canRemember: request.canRemember
    ) { [weak self] answer in self?.answerWrite(request, answer) }
  }

  private func answerRead(
    _ request: MuxClipboardRead,
    _ answer: KittyClipboardPolicy.Answer
  ) {
    let result: MuxClipboardReadResult
    if answer == .deny {
      result = .denied
    } else {
      let pasteboard = NSPasteboard.general
      result = .success(
        available: TerminalView.mimeTypes(on: pasteboard),
        contents: request.mimes.compactMap {
          TerminalView.content($0, on: pasteboard)
            .map { MuxClipboardContent(mime: $0.mime, data: Data($0.data)) }
        },
        remember: answer == .allowAlways && request.canRemember
      )
    }
    execute(
      .clipboardReadResult(pane: request.pane, token: request.token, result)
    )
  }

  private func answerWrite(
    _ request: MuxClipboardWrite,
    _ answer: KittyClipboardPolicy.Answer
  ) {
    let result: MuxClipboardWriteResult
    if answer == .deny {
      result = .denied
    } else {
      TerminalView.write(
        request.contents.map {
          KittyClipboard.Content(mime: $0.mime, data: Array($0.data))
        },
        to: .general
      )
      result = .success(remember: answer == .allowAlways && request.canRemember)
    }
    execute(
      .clipboardWriteResult(pane: request.pane, token: request.token, result)
    )
  }

  private func execute(_ command: MuxCommand) {
    let connection = connection
    Task { _ = try? await connection.execute(command) }
  }

  /// A sheet on the workspace window (a modal alert without one).
  private func ask(
    _ title: String,
    _ message: String,
    canRemember: Bool,
    _ answer: @escaping @MainActor (KittyClipboardPolicy.Answer) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Deny")
    alert.addButton(withTitle: "Allow")
    if canRemember { alert.addButton(withTitle: "Always Allow") }
    let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
      switch response {
      case .alertSecondButtonReturn: answer(.allow)
      case .alertThirdButtonReturn: answer(.allowAlways)
      default: answer(.deny)
      }
    }
    if let window {
      alert.beginSheetModal(for: window) { finish($0) }
    } else {
      finish(alert.runModal())
    }
  }
}
