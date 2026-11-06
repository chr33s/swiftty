import CSwshSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import Swsh

struct DescriptorHandoffTests {
  @Test
  func receivedDescriptorsAreIndependentCloseOnExecOwners() throws {
    let channel = try OwnedFD.descriptorChannel()
    try channel.withEnds {
      (input: consuming OwnedFD, output: consuming OwnedFD) in
      #expect(output.withDescriptor { swsh_send_standard_descriptors($0) } == 0)
      let received = try input.withDescriptor {
        try OwnedFD.receiveStandardIO(from: $0)
      }
      for descriptor in [received.builtinIO.output, received.builtinIO.error] {
        #expect(descriptor >= 10)
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
      }
      #expect(received.builtinIO.output != STDOUT_FILENO)
      #expect(received.builtinIO.error != STDERR_FILENO)
    }
    #expect(fcntl(STDOUT_FILENO, F_GETFD) >= 0)
    #expect(fcntl(STDERR_FILENO, F_GETFD) >= 0)
  }

  @Test(arguments: [UInt8(0), 7, 255])
  func validatesDescriptorMask(_ mask: UInt8) throws {
    let channel = try OwnedFD.descriptorChannel()
    try channel.withEnds {
      (input: consuming OwnedFD, output: consuming OwnedFD) in
      try output.withDescriptor { try writeBytes([mask], to: $0) }
      if mask == 0 {
        let received = try input.withDescriptor {
          try OwnedFD.receiveStandardIO(from: $0)
        }
        #expect(received.builtinIO.output == -1)
        #expect(received.builtinIO.error == -1)
      } else {
        #expect(throws: SystemFailure.self) {
          _ = try input.withDescriptor {
            try OwnedFD.receiveStandardIO(from: $0)
          }
        }
      }
    }
  }

  @Test
  func missingMessageNeverBlocksReceiver() throws {
    let channel = try OwnedFD.descriptorChannel()
    #expect(throws: SystemFailure.self) {
      _ = try channel.input.withDescriptor {
        try OwnedFD.receiveStandardIO(from: $0)
      }
    }
  }

  @Test(arguments: [false, true])
  func privateChannelCannotBeRedirectedOrUsedByOtherPayloadKinds(
    _ wrongKind: Bool
  ) throws {
    var payload = LauncherPayload(
      build: "test",
      executable: [47, 120],
      arguments: [[58]],
      environment: [],
      redirects: wrongKind ? [] : [.duplicate(descriptor: 1, source: 64)]
    )
    payload.kind = wrongKind ? .external : .descriptors
    payload.replyDescriptor = 64
    let file = try payload.write()
    #expect(throws: SystemFailure.self) {
      _ = try file.withDescriptor {
        try LauncherPayload.read(descriptor: $0, build: "test")
      }
    }
  }
}
