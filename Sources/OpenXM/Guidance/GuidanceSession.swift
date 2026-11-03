import Foundation
import CryptoKit

/// Revalidated original assets. This type does not assert a Sony signature or hardware-tested compatibility.
struct GuidanceInstallationAssets: Sendable {
    let source: GuidanceMetadataDownload
    let archive: GuidancePackageArchive
    let notice: GuidanceNoticeArchive?
    let bytes: [UInt8]
    var syncID: [UInt8] { Array(Insecure.MD5.hash(data: Data(bytes)).suffix(4)) }

    init(source: GuidanceMetadataDownload, archive: GuidancePackageArchive, notice: GuidanceNoticeArchive?) throws {
        guard source.metadata.offer != nil,
              try GuidanceDownloads.readArchive(at: archive.directory, source: source) == archive else {
            throw FirmwareError.invalid("The saved voice package changed or has no eligible offer. Its archive was preserved.")
        }
        if source.metadata.offer?.notice != nil {
            guard let notice, try GuidanceNoticeDownloads.readArchive(at: notice.directory, source: source) == notice else {
                throw FirmwareError.invalid("Sony's package notice must be downloaded and verified before installation.")
            }
        } else if notice != nil { throw FirmwareError.invalid("This notice does not belong to the selected package.") }
        // Hash the exact bytes that will be streamed, including after an archive has been reopened.
        let data = try GuidanceDownloads.boundedRead(archive.packageURL, limit: archive.size)
        guard try GuidanceDownloads.verify(data, source: source) == archive.sha256 else {
            throw FirmwareError.invalid("The voice package changed while it was being read.")
        }
        self.source = source; self.archive = archive; self.notice = notice; bytes = Array(data)
    }

    static func load(journal: GuidanceJournal, snapshot: GuidanceDeviceSnapshot) throws -> Self {
        try journal.check(snapshot)
        let data = try GuidanceDownloads.boundedRead(journal.packageDirectory.appendingPathComponent("metadata.enc"), limit: 1_048_576)
        guard GuidanceDownloads.sha256(data) == journal.metadataSHA256 else {
            throw FirmwareError.invalid("The saved language-session metadata changed. Session retained.")
        }
        let source = try GuidanceMetadataDownload(data: data, request: snapshot.request)
        let archive = try GuidanceDownloads.readArchive(at: journal.packageDirectory, source: source)
        let notice = try journal.noticeDirectory.map { try GuidanceNoticeDownloads.readArchive(at: $0, source: source) }
        let result = try Self(source: source, archive: archive, notice: notice)
        try journal.check(result)
        return result
    }
}

/// Kept separately from ordinary firmware sessions. No raw serial is saved in this private journal.
struct GuidanceJournal: Codable, Equatable {
    let formatVersion: Int
    let id: UUID
    let address: String
    let firmware: String
    let category: String
    let service: String
    let serialSHA256: String
    let sourceLanguage: GuidanceLanguage
    let targetLanguage: GuidanceLanguage
    let method: GuidanceUpdateMethod
    let packageDirectory: URL
    let noticeDirectory: URL?
    let metadataSHA256: String
    let packageSHA256: String
    let noticeSHA256: String?
    let started: Date
    /// Persist before enabling language mode. False means no GAIA session could have started.
    var transferStarted = false
    var phase: VMUTransfer.Phase = .preparing

    /// This is only preparation cleanup, never an abort of a possibly started transfer.
    var canCancelPreparation: Bool { !transferStarted && phase == .preparing }

    init(snapshot: GuidanceDeviceSnapshot, assets: GuidanceInstallationAssets, now: Date = Date()) throws {
        formatVersion = 1; id = UUID(); address = snapshot.address; firmware = snapshot.request.firmware
        category = snapshot.request.category; service = snapshot.request.service
        serialSHA256 = GuidanceDownloads.sha256(Data(snapshot.request.serial.utf8))
        sourceLanguage = snapshot.currentLanguage; targetLanguage = snapshot.request.language; method = snapshot.method
        packageDirectory = assets.archive.directory; noticeDirectory = assets.notice?.directory
        metadataSHA256 = GuidanceDownloads.sha256(assets.source.data)
        packageSHA256 = assets.archive.sha256; noticeSHA256 = assets.notice?.sha256; started = now
        try validate(); try check(snapshot); try check(assets)
    }

    func validate() throws {
        func digest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        func directory(_ value: URL) -> Bool {
            value.isFileURL && value.host == nil && value.query == nil && value.fragment == nil && value.path.hasPrefix("/")
                && value.standardizedFileURL == value
        }
        guard formatVersion == 1, address == FirmwareDeviceAccess.normalizedAddress(address),
              address.split(separator: ":").count == 6,
              address.split(separator: ":").allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }),
              !firmware.isEmpty, firmware.count <= 128,
              GuidancePackageRequest.validIdentifier(category), GuidancePackageRequest.validIdentifier(service),
              sourceLanguage.isKnown, targetLanguage.isKnown, sourceLanguage != targetLanguage,
              digest(serialSHA256), digest(metadataSHA256), digest(packageSHA256),
              directory(packageDirectory), noticeDirectory.map(directory) ?? true,
              (noticeDirectory == nil) == (noticeSHA256 == nil), noticeSHA256.map(digest) ?? true,
              transferStarted || phase == .preparing else {
            throw FirmwareError.invalid("The saved language session is invalid. It was preserved for diagnosis.")
        }
        _ = try GuidancePreflight.minimumBattery(for: method)
    }

    func check(_ snapshot: GuidanceDeviceSnapshot) throws {
        try validate()
        guard snapshot.address == address, snapshot.request.model == "WH-1000XM3",
              snapshot.request.firmware == firmware, snapshot.request.category == category,
              snapshot.request.service == service, snapshot.request.language == targetLanguage,
              GuidanceDownloads.sha256(Data(snapshot.request.serial.utf8)) == serialSHA256, snapshot.method == method,
              [sourceLanguage, targetLanguage].contains(snapshot.currentLanguage) else {
            throw FirmwareError.invalid("This language session does not match the connected headset, firmware or language service. Session retained.")
        }
    }

    func check(_ assets: GuidanceInstallationAssets) throws {
        let request = assets.source.request
        guard request.model == "WH-1000XM3", request.firmware == firmware,
              request.category == category, request.service == service, request.language == targetLanguage,
              GuidanceDownloads.sha256(Data(request.serial.utf8)) == serialSHA256,
              assets.archive.directory == packageDirectory, assets.notice?.directory == noticeDirectory,
              assets.archive.sha256 == packageSHA256, assets.notice?.sha256 == noticeSHA256,
              GuidanceDownloads.sha256(assets.source.data) == metadataSHA256 else {
            throw FirmwareError.invalid("The assets do not match the saved language session. No replacement package was selected.")
        }
    }
}

enum GuidanceJournalStore {
    static let url = FirmwareJournalStore.url.deletingLastPathComponent().appendingPathComponent("voice-language-session.json")
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func read(from url: URL = url) throws -> GuidanceJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let journal = try JSONDecoder().decode(GuidanceJournal.self, from: GuidanceDownloads.boundedRead(url, limit: 16_384))
        try journal.validate()
        return journal
    }

    static func save(_ journal: GuidanceJournal, to url: URL = url) throws {
        try journal.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum GuidanceInstallPlan: Equatable {
    case start, resume(allowData: Bool), verifyCompleted

    static func make(snapshot: GuidanceDeviceSnapshot, assets: GuidanceInstallationAssets,
                     discoveryAddress: String, journal: GuidanceJournal?) throws -> Self {
        guard let journal else {
            _ = try GuidancePreflight.check(snapshot: snapshot, discoveryAddress: discoveryAddress,
                source: assets.source, archive: assets.archive, notice: assets.notice)
            return .start
        }
        try journal.check(snapshot); try journal.check(assets)
        if journal.phase == .complete {
            guard snapshot.currentLanguage == journal.targetLanguage else {
                throw FirmwareError.invalid("The committed session's target language was not read back. Session retained.")
            }
            return .verifyCompleted
        }
        try GuidancePreflight.checkPower(snapshot)
        if !journal.transferStarted {
            guard snapshot.currentLanguage == journal.sourceLanguage else {
                throw FirmwareError.invalid("The language changed before this saved transfer started. Session retained.")
            }
            return .start
        }
        guard journal.method.code == 0x11 else {
            throw FirmwareError.invalid("This headset did not advertise language-transfer resume. The interrupted session is preserved; OpenXM cannot safely restart it.")
        }
        return .resume(allowData: snapshot.currentLanguage == journal.sourceLanguage)
    }
}
