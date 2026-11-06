#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Swsh
import SwshAgent

let arguments = (0 ..< Int(CommandLine.argc))
  .map { index in
    let pointer = CommandLine.unsafeArgv[index]!
    return Array(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
  }
// Agent mode is selected before any shell state exists and never creates it.
if arguments.dropFirst().first == Array("--agent".utf8) {
  guard arguments.count == 2 else {
    let usage = Array("swsh: usage: swsh --agent\n".utf8)
    _ = usage.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
    exit(2)
  }
  exit(AgentMain.run())
}
#if canImport(Darwin)
exit(await ShellMain.run(arguments: arguments))
#else
ShellMain.runAndExit(arguments: arguments)
#endif
