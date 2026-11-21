/// Kitty clipboard protocol (OSC 5522) packets and paste events, served
/// through `kittyClipboardReader` and `kittyClipboardWriter`. Responses
/// echo the request's terminator, as Ghostty does.
extension TerminalState {
  typealias Clip = KittyClipboard

  /// `OSC 5522 ; metadata [; payload]`.
  mutating func kittyClipboard(
    _ rest: UnsafeBufferPointer<UInt8>,
    terminator: String
  ) {
    let bytes = Array(rest)
    let split = bytes.firstIndex(of: 0x3B)
    let raw = bytes[..<(split ?? bytes.endIndex)]
    let payload = split.map { bytes[($0 + 1)...] } ?? []
    let meta: Clip.Metadata
    do throws(Clip.InvalidValue) {
      guard let parsed = try Clip.Metadata.parse(raw) else { return }
      meta = parsed
    } catch {
      // An invalid value aborts only a transaction it belongs to.
      if kittyClipboardWrite != nil, let op = Clip.Metadata.operation(raw),
        op == .wdata || op == .walias
      {
        finishKittyClipboardWrite(.EINVAL, terminator: terminator)
      }
      return
    }
    switch meta.op {
    case .read: kittyClipboardRead(meta, payload, terminator: terminator)
    case .write:
      // A new write replaces any transaction in flight, silently.
      kittyClipboardWrite = nil
      guard kittyClipboardWriter != nil else {
        // A commit could never succeed: fail now and ignore the rest.
        replyKittyClipboard(
          Clip.response(.write, .ENOSYS, id: meta.id, terminator: terminator)
        )
        return
      }
      kittyClipboardWrite = Clip.WriteTransaction(
        meta,
        maxBytes: kittyClipboardWriteLimit
      )
    case .wdata:
      guard kittyClipboardWrite != nil else { return }
      guard !meta.mime.isEmpty else {
        commitKittyClipboardWrite(terminator: terminator)
        return
      }
      do throws(Clip.WriteFailure) {
        try kittyClipboardWrite!.data(mime: meta.mime, payload: payload)
      } catch {
        finishKittyClipboardWrite(
          error == .tooLarge ? .EFBIG : .EINVAL,
          terminator: terminator
        )
      }
    case .walias:
      guard kittyClipboardWrite != nil else { return }
      do throws(Clip.WriteFailure) {
        guard !meta.mime.isEmpty else { throw .invalid }
        try kittyClipboardWrite!.alias(target: meta.mime, payload: payload)
      } catch { finishKittyClipboardWrite(.EINVAL, terminator: terminator) }
    }
  }

  private mutating func kittyClipboardRead(
    _ meta: Clip.Metadata,
    _ payload: ArraySlice<UInt8>,
    terminator: String
  ) {
    // An undecodable type list has no error status: drop it.
    guard let decoded = Base64.decode(payload),
      let text = String(validating: decoded, as: UTF8.self)
    else { return }
    guard let reader = kittyClipboardReader else {
      replyKittyClipboard(
        Clip.response(.read, .EPERM, id: meta.id, terminator: terminator)
      )
      return
    }
    var mimes: [String] = []
    var list = false
    for mime in Clip.mimeList(text) {
      if mime == "." {
        list = true
      } else if mimes.count < Clip.maxReadMimes {
        mimes.append(mime)
      }
    }
    // A password without a name is no password. A listing alone needs no
    // prompt, so it never consumes a grant (a paste event's one-time
    // password must survive for the follow-up data read).
    let pw = meta.name.isEmpty ? [] : meta.pw
    let granted = !mimes.isEmpty && kittyClipboardGrants.use(pw, .read)
    kittyClipboardReadToken &+= 1
    let read = Clip.PendingRead(
      token: kittyClipboardReadToken,
      primary: meta.primary,
      id: meta.id,
      pw: pw,
      mimes: mimes,
      list: list,
      terminator: terminator
    )
    let result = reader(
      Clip.ReadRequest(
        primary: meta.primary,
        mimes: mimes,
        list: list,
        name: meta.name,
        granted: granted,
        canRemember: !pw.isEmpty,
        token: read.token
      )
    )
    if result == .deferred {
      // Answered by `completeKittyClipboardRead`; the oldest is refused
      // once too many wait.
      if pendingKittyClipboardReads.count >= Clip.maxPendingReads {
        answerKittyClipboardRead(
          pendingKittyClipboardReads.removeFirst(),
          .busy
        )
      }
      pendingKittyClipboardReads.append(read)
      return
    }
    answerKittyClipboardRead(read, result)
  }

  /// Answers a read the reader deferred, for example after asking the
  /// user. Unknown or already answered tokens are ignored.
  public mutating func completeKittyClipboardRead(
    _ token: UInt64,
    with result: KittyClipboard.ReadResult
  ) {
    guard result != .deferred,
      let index = pendingKittyClipboardReads.firstIndex(where: {
        $0.token == token
      })
    else { return }
    answerKittyClipboardRead(
      pendingKittyClipboardReads.remove(at: index),
      result
    )
  }

  private mutating func answerKittyClipboardRead(
    _ read: Clip.PendingRead,
    _ result: KittyClipboard.ReadResult?
  ) {
    let status: Clip.Status
    switch result {
    case let .success(available, contents, remember)?:
      if remember, !read.pw.isEmpty {
        kittyClipboardGrants.grant(read.pw, .read, oneTime: false)
      }
      // Only requested types, in request order.
      let served = read.mimes.compactMap { mime in
        contents.first { $0.mime == mime }
      }
      replyKittyClipboard(
        Clip.readSuccess(
          primary: read.primary,
          id: read.id,
          pw: nil,
          list: read.list,
          available: available,
          contents: served,
          terminator: read.terminator
        )
      )
      return
    case .denied?, .deferred?, nil: status = .EPERM
    case .unsupported?: status = .ENOSYS
    case .busy?: status = .EBUSY
    case .ioError?: status = .EIO
    }
    replyKittyClipboard(
      Clip.response(.read, status, id: read.id, terminator: read.terminator)
    )
  }

  private mutating func commitKittyClipboardWrite(terminator: String) {
    let contents: [Clip.Content]
    do throws(Clip.WriteFailure) {
      contents = try kittyClipboardWrite!.commit()
    } catch {
      finishKittyClipboardWrite(.EINVAL, terminator: terminator)
      return
    }
    guard let writer = kittyClipboardWriter,
      let transaction = kittyClipboardWrite
    else {
      finishKittyClipboardWrite(.ENOSYS, terminator: terminator)
      return
    }
    let pw = transaction.name.isEmpty ? [] : transaction.pw
    let granted = kittyClipboardGrants.use(pw, .write)
    kittyClipboardWriteToken &+= 1
    let token = kittyClipboardWriteToken
    let result = writer(
      Clip.WriteRequest(
        primary: transaction.primary,
        contents: contents,
        name: transaction.name,
        granted: granted,
        canRemember: !pw.isEmpty,
        token: token
      )
    )
    kittyClipboardWrite = nil
    let pending = Clip.PendingWrite(
      token: token,
      id: transaction.id,
      pw: pw,
      terminator: terminator
    )
    if result == .deferred {
      // Answered by `completeKittyClipboardWrite`.
      if pendingKittyClipboardWrites.count >= Clip.maxPendingReads {
        answerKittyClipboardWrite(
          pendingKittyClipboardWrites.removeFirst(),
          .busy
        )
      }
      pendingKittyClipboardWrites.append(pending)
      return
    }
    answerKittyClipboardWrite(pending, result)
  }

  /// A planned replacement's cut (spec.durability.md §6): every request the
  /// app has not answered is answered busy, the existing overflow answer,
  /// so nothing waits across the cut. A late app answer is then ignored.
  public mutating func settleKittyClipboardForCut() {
    for read in pendingKittyClipboardReads {
      answerKittyClipboardRead(read, .busy)
    }
    pendingKittyClipboardReads.removeAll()
    for write in pendingKittyClipboardWrites {
      answerKittyClipboardWrite(write, .busy)
    }
    pendingKittyClipboardWrites.removeAll()
  }

  /// Answers a write the writer deferred. Unknown or already answered
  /// tokens are ignored.
  public mutating func completeKittyClipboardWrite(
    _ token: UInt64,
    with result: KittyClipboard.WriteResult
  ) {
    guard result != .deferred,
      let index = pendingKittyClipboardWrites.firstIndex(where: {
        $0.token == token
      })
    else { return }
    answerKittyClipboardWrite(
      pendingKittyClipboardWrites.remove(at: index),
      result
    )
  }

  private mutating func answerKittyClipboardWrite(
    _ write: Clip.PendingWrite,
    _ result: KittyClipboard.WriteResult?
  ) {
    if case let .success(remember)? = result, remember, !write.pw.isEmpty {
      kittyClipboardGrants.grant(write.pw, .write, oneTime: false)
    }
    let status: Clip.Status =
      switch result {
      case .success?: .DONE
      case .denied?, .deferred?, nil: .EPERM
      case .unsupported?: .ENOSYS
      case .busy?: .EBUSY
      case .invalidData?: .EINVAL
      case .ioError?: .EIO
      }
    replyKittyClipboard(
      Clip.response(.write, status, id: write.id, terminator: write.terminator)
    )
  }

  /// Answers the transaction with its opening packet's id and drops it.
  private mutating func finishKittyClipboardWrite(
    _ status: Clip.Status,
    terminator: String
  ) {
    guard let transaction = kittyClipboardWrite else { return }
    kittyClipboardWrite = nil
    replyKittyClipboard(
      Clip.response(.write, status, id: transaction.id, terminator: terminator)
    )
  }

  private mutating func replyKittyClipboard(_ bytes: [UInt8]) {
    guard !discardsReplies else { return }
    output.append(contentsOf: bytes)
  }

  /// With mode 5522 and a reader, the bytes reporting a clipboard paste:
  /// the available types and a one-time password the program reads with.
  /// The contents themselves are never sent. Nil: paste text instead.
  /// `primary` marks a paste from the selection rather than the clipboard.
  public mutating func kittyPasteEvent(
    available: [String],
    primary: Bool = false
  ) -> [UInt8]? {
    guard modes.contains(.kittyPasteEvents), kittyClipboardReader != nil else {
      return nil
    }
    let pw = Clip.oneTimePassword()
    // Granted before the program can see the event.
    kittyClipboardGrants.grant(pw, .read, oneTime: true)
    return Clip.readSuccess(
      primary: primary,
      id: [],
      pw: pw,
      list: true,
      available: Array(available.prefix(Clip.maxListingMimes)),
      contents: [],
      terminator: "\u{1B}\\"
    )
  }
}
