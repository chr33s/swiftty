#if os(macOS)
import SwiftMuxGuardian

/// Shared signing policy; process ownership must not depend on the service engine.
public typealias PeerSigningPolicy = GuardianPeerSigningPolicy
#endif
