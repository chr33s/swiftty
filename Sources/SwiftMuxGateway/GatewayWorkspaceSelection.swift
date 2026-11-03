import Foundation
import SwiftMuxProtocol

extension GatewayWorkspaceDirectory {
  /// Resolves against one immutable inventory view. Never skips an unavailable
  /// candidate in favor of a healthy but different workspace.
  package static func select(
    _ selector: WorkspaceSelector,
    from records: [Record]
  ) throws -> Record {
    if case let .id(id) = selector {
      guard
        let record = records.first(where: {
          $0.inventory.authority.workspace == id
        })
      else { throw MuxError(.notFound, "workspace not found") }
      return record
    }
    // An empty worker has definitively published no workspace. All other
    // unknown metadata could conceal a duplicate name or a newer workspace.
    guard
      records.allSatisfy({ $0.state == .empty || $0.lastKnownSummary != nil })
    else {
      throw MuxError(
        .quiescing,
        "workspace names and creation order are incomplete; use an explicit ID"
      )
    }
    let published = records.filter { $0.lastKnownSummary != nil }
    let matches: [Record]
    switch selector {
    case .id: preconditionFailure("handled above")
    case .latest:
      guard
        let newest = published.compactMap({ $0.lastKnownSummary?.createdAt })
          .max()
      else { throw MuxError(.notFound, "no published workspace") }
      matches = published.filter { $0.lastKnownSummary?.createdAt == newest }
    case let .name(name):
      guard !name.isEmpty else {
        throw MuxError(.notFound, "workspace not found")
      }
      let named = published.filter { $0.lastKnownSummary?.name == name }
      if !named.isEmpty {
        matches = named
      } else {
        let prefix = name.uppercased()
        let digits = prefix.unicodeScalars.filter { $0 != "-" }
        guard digits.count >= 8, digits.allSatisfy(\.properties.isASCIIHexDigit)
        else { throw MuxError(.notFound, "workspace not found") }
        matches = records.filter {
          $0.inventory.authority.workspace.description.uppercased()
            .hasPrefix(prefix)
        }
      }
    }
    guard matches.count == 1 else {
      throw MuxError(
        matches.isEmpty ? .notFound : .invalidRequest,
        matches.isEmpty
          ? "workspace not found"
          : "workspace selector is ambiguous; use an explicit ID"
      )
    }
    return matches[0]
  }
}
