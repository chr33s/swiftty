import Darwin
import Swsh

let arguments = (0 ..< Int(CommandLine.argc))
  .map { index in
    let pointer = CommandLine.unsafeArgv[index]!
    return Array(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
  }
exit(await ShellMain.run(arguments: arguments))
