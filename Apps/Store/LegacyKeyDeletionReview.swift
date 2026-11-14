import Foundation

/// A prepared, non-secret review of a matching key in the current account.
/// Confirmation rejects changes to either the account context or the journal.
package struct LegacyKeyDeletionReview: Identifiable, Hashable, Sendable {
  package let intent: IdentityIntent
  package let account: String
  package let generation: Int
  package let metadataAccount: String?
  package let fingerprint: String

  package init(
    intent: IdentityIntent,
    account: String,
    generation: Int,
    metadataAccount: String?,
    fingerprint: String
  ) {
    self.intent = intent
    self.account = account
    self.generation = generation
    self.metadataAccount = metadataAccount
    self.fingerprint = fingerprint
  }

  package var id: UUID { intent.id }
  package var name: String { intent.name }
}
