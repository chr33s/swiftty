import TerminalProcess

// Preserve the engine's public process API while sharing its syscall-only
// implementation with the guardian. No engine state enters TerminalProcess.
public typealias POSIXError = TerminalProcess.POSIXError
public typealias FileDescriptor = TerminalProcess.FileDescriptor
package typealias CStringVector = TerminalProcess.CStringVector
#if os(macOS)
package typealias PTYAllocation = TerminalProcess.PTYAllocation
package typealias PTYProcessExit = TerminalProcess.PTYProcessExit
package typealias PTYProcessShutdown = TerminalProcess.PTYProcessShutdown
#endif
