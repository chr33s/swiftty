import CSwshSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(Darwin)
/// The only child-notification source. Kernel status, not notification counts, is authoritative.
struct ChildEvents: ~Copyable {
  private let queue: OwnedFD
  private let inputDescriptor: Int32?

  init(inputDescriptor: Int32? = nil) throws {
    let owner = try OwnedFD.eventQueue()
    try owner.withDescriptor { fd in
      for number in [SIGCHLD, SIGINT, SIGTERM, SIGHUP] {
        var event = kevent(
          ident: UInt(number),
          filter: Int16(EVFILT_SIGNAL),
          flags: UInt16(EV_ADD | EV_ENABLE),
          fflags: 0,
          data: 0,
          udata: nil
        )
        guard kevent(fd, &event, 1, nil, 0, nil) == 0 else {
          throw SystemFailure("register signal event")
        }
        guard swsh_observe_signal(number) == 0 else {
          throw SystemFailure("install signal notification")
        }
      }
    }
    self.inputDescriptor = inputDescriptor
    queue = consume owner
  }

  struct Ready {
    var signals: [Int32] = [];
    var input = false
  }

  borrowing func wait(
    milliseconds: Int,
    watchInput: Bool = false
  ) throws -> Ready {
    try queue.withDescriptor { fd in
      if let inputDescriptor {
        var event = kevent(
          ident: UInt(inputDescriptor),
          filter: Int16(EVFILT_READ),
          flags: UInt16(EV_ADD | (watchInput ? EV_ENABLE : EV_DISABLE)),
          fflags: 0,
          data: 0,
          udata: nil
        )
        guard kevent(fd, &event, 1, nil, 0, nil) == 0 else {
          throw SystemFailure("watch terminal input")
        }
      }
      var events: [Darwin.kevent] = Array(repeating: Darwin.kevent(), count: 5)
      var timeout = timespec(
        tv_sec: milliseconds / 1000,
        tv_nsec: (milliseconds % 1000) * 1_000_000
      )
      let count = kevent(fd, nil, 0, &events, Int32(events.count), &timeout)
      if count < 0 && errno == EINTR { return Ready() }
      guard count >= 0 else { throw SystemFailure("wait for child events") }
      var ready = Ready()
      for event in events.prefix(Int(count)) {
        if event.filter == Int16(EVFILT_SIGNAL) {
          ready.signals.append(Int32(event.ident))
        } else if watchInput && event.filter == Int16(EVFILT_READ) {
          ready.input = true
        }
      }
      return ready
    }
  }
}
#else
/// The only child-notification source. Kernel status, not notification counts, is authoritative.
/// Without kqueue, signal numbers arrive through a process-wide pipe written by
/// the handler, so delivery on any thread is observed.
struct ChildEvents: ~Copyable {
  private let signalDescriptor: Int32
  private let inputDescriptor: Int32?

  init(inputDescriptor: Int32? = nil) throws {
    signalDescriptor = swsh_signal_pipe()
    guard signalDescriptor >= 0 else {
      throw SystemFailure("create signal pipe")
    }
    for number in [SIGCHLD, SIGINT, SIGTERM, SIGHUP] {
      guard swsh_observe_signal(number) == 0 else {
        throw SystemFailure("install signal notification")
      }
    }
    self.inputDescriptor = inputDescriptor
  }

  struct Ready {
    var signals: [Int32] = [];
    var input = false
  }

  borrowing func wait(
    milliseconds: Int,
    watchInput: Bool = false
  ) throws -> Ready {
    var descriptors = [
      pollfd(fd: signalDescriptor, events: Int16(POLLIN), revents: 0)
    ]
    if watchInput, let inputDescriptor {
      descriptors.append(
        pollfd(fd: inputDescriptor, events: Int16(POLLIN), revents: 0)
      )
    }
    let count = poll(
      &descriptors,
      nfds_t(descriptors.count),
      Int32(milliseconds)
    )
    if count < 0 && errno == EINTR { return Ready() }
    guard count >= 0 else { throw SystemFailure("wait for child events") }
    var ready = Ready()
    if descriptors[0].revents != 0 {
      var buffer = [UInt8](repeating: 0, count: 64)
      var seen = Set<UInt8>()
      while true {
        let received = read(signalDescriptor, &buffer, buffer.count)
        guard received > 0 else { break }
        seen.formUnion(buffer.prefix(received))
      }
      for number in seen { ready.signals.append(Int32(number)) }
    }
    if descriptors.count > 1, descriptors[1].revents != 0 { ready.input = true }
    return ready
  }
}
#endif
