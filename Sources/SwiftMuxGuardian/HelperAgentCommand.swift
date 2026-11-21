import Darwin
import Foundation
import ServiceManagement
import Synchronization

/// `register`, `unregister` and `status` for a durable helper bundle's own
/// LaunchAgent (spec.durability.md §9). The bundle names its agent with
/// `SwiftMuxAgentLabel`; the plist is `Contents/Library/LaunchAgents/<label>.plist`.
package enum HelperAgentCommand {
  package static func run(_ command: String) -> Int32 {
    guard
      let label = Bundle.main.object(forInfoDictionaryKey: "SwiftMuxAgentLabel")
        as? String, !label.isEmpty, label.utf8.count <= 255,
      !label.contains("/")
    else {
      FileHandle.standardError.write(Data("helper: no agent label\n".utf8))
      return 78
    }
    let plist = label + ".plist"
    let done = DispatchSemaphore(value: 0)
    let status = Mutex<Int32>(0)
    Task.detached {
      let service = SMAppService.agent(plistName: plist)
      do {
        switch command {
        case "register": try service.register()
        case "unregister": try await service.unregister()
        default: break
        }
        print(service.status.rawValue)
      } catch {
        FileHandle.standardError.write(Data("helper: \(error)\n".utf8))
        status.withLock { $0 = 75 }
      }
      done.signal()
    }
    done.wait()
    return status.withLock { $0 }
  }

  /// The owner's home from the account database, not the environment.
  package static func accountHome() -> String? {
    var record = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 4096)
    guard getpwuid_r(getuid(), &record, &buffer, buffer.count, &result) == 0,
      result != nil, let directory = record.pw_dir
    else { return nil }
    let home = String(cString: directory)
    return home.hasPrefix("/") ? home : nil
  }
}
