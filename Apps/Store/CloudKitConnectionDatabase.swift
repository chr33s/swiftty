import Crypto
import Foundation

#if canImport(CloudKit) && !os(watchOS)
import CloudKit

/// The user's private CloudKit database, custom zone
/// `SwifttyConnectionsV1` (spec.ssh-identity.md §8.1). Never Shell's
/// container. Only used when the build declares a container in
/// `SwifttyCloudKitContainer` (written with the entitlement by
/// Scripts/configure-links.sh), so an unprovisioned build never touches
/// CloudKit and never falls back to plaintext files.
public final class CloudKitConnectionDatabase: ConnectionCloudDatabase {
  package static let zoneName = "SwifttyConnectionsV1"

  private let containerIdentifier: String
  private let zoneID = CKRecordZone.ID(
    zoneName: CloudKitConnectionDatabase.zoneName,
    ownerName: CKCurrentUserDefaultName
  )

  public init(containerIdentifier: String) {
    self.containerIdentifier = containerIdentifier
  }

  private var container: CKContainer {
    CKContainer(identifier: containerIdentifier)
  }

  private var database: CKDatabase { container.privateCloudDatabase }

  /// The configured container, if this build has the capability.
  package static func configured() -> (any ConnectionCloudDatabase)? {
    guard
      let identifier = Bundle.main.object(
        forInfoDictionaryKey: "SwifttyCloudKitContainer"
      ) as? String, identifier.hasPrefix("iCloud."), !identifier.contains("$("),
      identifier != "iCloud.dev.chr33s.shell"
    else { return nil }
    return CloudKitConnectionDatabase(containerIdentifier: identifier)
  }

  public func accountID() async throws(CloudSyncError) -> String {
    do {
      switch try await container.accountStatus() {
      case .available: break
      case .temporarilyUnavailable, .couldNotDetermine:
        throw CloudSyncError.accountTemporarilyUnavailable
      default: throw CloudSyncError.accountRequired
      }
      let record = try await container.userRecordID()
      // An opaque per-container value; the record name itself is not kept.
      let digest = SHA256.hash(data: Data(record.recordName.utf8))
      return "acct-"
        + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    } catch let error as CloudSyncError { throw error } catch {
      throw Self.map(error)
    }
  }

  public func createZone() async throws(CloudSyncError) {
    do {
      // The single-zone API throws that zone's failure. A batch request can
      // succeed while its per-zone save result contains an error.
      _ = try await database.save(CKRecordZone(zoneID: zoneID))
    } catch { throw Self.map(error) }
  }

  public func fetchChanges(
    since token: Data?
  ) async throws(CloudSyncError) -> CloudChangePage {
    let serverToken = token.flatMap {
      try? NSKeyedUnarchiver.unarchivedObject(
        ofClass: CKServerChangeToken.self,
        from: $0
      )
    }
    do {
      let changes = try await database.recordZoneChanges(
        inZoneWith: zoneID,
        since: serverToken,
        desiredKeys: nil,
        resultsLimit: 200
      )
      var changed: [CloudRecord] = []
      for (_, result) in changes.modificationResultsByID {
        switch result {
        case .success(let modification):
          changed.append(Self.record(modification.record))
        case .failure(let error): throw Self.map(error)
        }
      }
      let next = try? NSKeyedArchiver.archivedData(
        withRootObject: changes.changeToken,
        requiringSecureCoding: true
      )
      return CloudChangePage(
        changed: changed,
        deleted: changes.deletions.map(\.recordID.recordName),
        token: next,
        moreComing: changes.moreComing
      )
    } catch let error as CloudSyncError { throw error } catch {
      throw Self.map(error)
    }
  }

  public func save(
    _ records: [CloudRecord]
  ) async throws(CloudSyncError) -> [String: Result<
    CloudRecord, CloudSyncError
  >] {
    let ckRecords = records.map(ckRecord)
    do {
      let results = try await database.modifyRecords(
        saving: ckRecords,
        deleting: [],
        savePolicy: .ifServerRecordUnchanged,
        atomically: false
      )
      var out: [String: Result<CloudRecord, CloudSyncError>] = [:]
      for (id, result) in results.saveResults {
        out[id.recordName] = result.map(Self.record).mapError(Self.map)
      }
      return out
    } catch { throw Self.map(error) }
  }

  // MARK: Conversion

  private func ckRecord(_ record: CloudRecord) -> CKRecord {
    let ck: CKRecord
    if let fields = record.systemFields,
      let coder = try? NSKeyedUnarchiver(forReadingFrom: fields),
      let decoded = CKRecord(coder: coder)
    {
      ck = decoded
    } else {
      ck = CKRecord(
        recordType: record.type,
        recordID: CKRecord.ID(recordName: record.name, zoneID: zoneID)
      )
    }
    // A record rebuilt from system fields has no values loaded, so clear
    // every schema field the new version omits (tombstones keep only
    // identity and revision).
    let stale = Set(ck.allKeys())
      .union(ConnectionRecords.fieldNames(record.type))
    for key in stale where record.fields[key] == nil { ck[key] = nil }
    for (key, value) in record.fields {
      switch value {
      case .string(let text): ck[key] = text as NSString
      case .int(let number): ck[key] = NSNumber(value: number)
      case .date(let date): ck[key] = date as NSDate
      case .bytes(let data): ck[key] = data as NSData
      }
    }
    return ck
  }

  package static func record(_ ck: CKRecord) -> CloudRecord {
    var fields: [String: CloudValue] = [:]
    for key in ck.allKeys() {
      switch ck[key] {
      case let text as String: fields[key] = .string(text)
      case let date as Date: fields[key] = .date(date)
      case let data as Data: fields[key] = .bytes(data)
      case let number as NSNumber: fields[key] = .int(number.int64Value)
      default: break
      }
    }
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    ck.encodeSystemFields(with: coder)
    coder.finishEncoding()
    return CloudRecord(
      name: ck.recordID.recordName,
      type: ck.recordType,
      fields: fields,
      systemFields: coder.encodedData
    )
  }

  package static func map(_ error: any Error) -> CloudSyncError {
    guard let error = error as? CKError else { return .other(-1) }
    switch error.code {
    case .networkUnavailable, .networkFailure: return .networkUnavailable
    case .serviceUnavailable, .requestRateLimited, .zoneBusy:
      return .retryAfter(error.retryAfterSeconds)
    case .serverRecordChanged:
      guard let server = error.serverRecord else { return .retryAfter(nil) }
      return .conflict(record(server))
    case .quotaExceeded: return .quotaExceeded
    case .zoneNotFound, .userDeletedZone: return .zoneNotFound
    case .changeTokenExpired: return .changeTokenExpired
    case .notAuthenticated: return .accountRequired
    case .accountTemporarilyUnavailable: return .accountTemporarilyUnavailable
    case .permissionFailure, .missingEntitlement, .badContainer:
      return .permissionFailure
    case .unknownItem: return .recordMissing
    case .batchRequestFailed: return .retryAfter(nil)
    case .invalidArguments, .constraintViolation, .serverRejectedRequest:
      return .invalidRecord(reason(error))
    default: return .other(error.code.rawValue)
    }
  }

  /// The code and CloudKit's own explanation (such as a record type
  /// missing from the production schema), on one bounded line. It names
  /// schema elements only, never field values.
  package static func reason(_ error: CKError) -> String {
    let code = String(error.code.rawValue)
    var detail =
      (error.userInfo[NSLocalizedDescriptionKey] as? String)?
      .split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces) ?? ""
    // Drop the "Error saving record <CKRecordID …> to server:" preamble so
    // the bound keeps the server's explanation, not the record ID.
    if let range = detail.range(of: " to server: ") {
      detail = String(detail[range.upperBound...])
    }
    guard !detail.isEmpty else { return code }
    return code + ": " + String(detail.prefix(160))
  }
}
#else
package enum CloudKitConnectionDatabase {
  package static func configured() -> (any ConnectionCloudDatabase)? { nil }
}
#endif
