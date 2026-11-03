import Foundation

/// Portable original files, not an installation authorization or a Sony signature. No device address,
/// serial request field, local path or update journal is added. Sony metadata is retained verbatim.
struct GuidancePackageBackup: Codable, Equatable, Sendable {
    struct Context: Codable, Equatable, Sendable {
        let model, firmwareAtDiscovery, category, service, packageVersion: String
        let language: GuidanceLanguage
    }
    struct File: Codable, Equatable, Sendable {
        let data: Data
        let sha256: String
        init(_ data: Data) { self.data = data; sha256 = GuidanceDownloads.sha256(data) }
        func validate(limit: Int) throws {
            guard !data.isEmpty, data.count <= limit, GuidanceDownloads.sha256(data) == sha256 else {
                throw FirmwareError.invalid("A voice-package backup file failed its size or SHA-256 check.")
            }
        }
    }

    static let encodedLimit = 48_000_000
    static let directory = FirmwareJournalStore.url.deletingLastPathComponent().appendingPathComponent("VoiceGuidanceImports", isDirectory: true)
    let format: String
    let version: Int
    let context: Context
    let metadata, package, packageProvenance: File
    let notice, noticeProvenance: File?

    init(assets: GuidanceInstallationAssets) throws {
        // Reopen everything: a previous preparation result cannot authorize exporting changed files.
        let checked = try GuidanceInstallationAssets(source: assets.source, archive: assets.archive, notice: assets.notice)
        guard let offer = checked.source.metadata.offer else { throw FirmwareError.invalid("No voice-package offer.") }
        let request = checked.source.request
        format = "OpenXM voice package"; version = 1
        context = .init(model: request.model, firmwareAtDiscovery: request.firmware, category: request.category,
            service: request.service, packageVersion: offer.version, language: request.language)
        metadata = File(checked.source.data)
        package = File(Data(checked.bytes))
        packageProvenance = File(try GuidanceDownloads.boundedRead(checked.archive.directory.appendingPathComponent("provenance.json"), limit: 16_384))
        if let saved = checked.notice {
            let data = try GuidanceDownloads.boundedRead(saved.noticeURL, limit: 1_048_576)
            guard GuidanceDownloads.sha256(data) == saved.sha256 else { throw FirmwareError.invalid("The notice changed during export.") }
            notice = File(data)
            noticeProvenance = File(try GuidanceDownloads.boundedRead(saved.directory.appendingPathComponent("provenance.json"), limit: 16_384))
        } else { notice = nil; noticeProvenance = nil }
        try validate()
    }

    static func read(_ url: URL) throws -> Self {
        try Task.checkCancellation()
        return try decode(GuidanceDownloads.boundedRead(url, limit: encodedLimit))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= encodedLimit else { throw FirmwareError.invalid("The voice-package backup exceeds 48 MB.") }
        let saved = try JSONDecoder().decode(Self.self, from: data)
        try saved.validate()
        return saved
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.encodedLimit else { throw FirmwareError.invalid("The voice-package backup exceeds 48 MB.") }
        return data
    }

    func validate() throws {
        try Task.checkCancellation()
        func label(_ text: String, limit: Int) -> Bool {
            !text.isEmpty && text.utf8.count <= limit && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard format == "OpenXM voice package", version == 1, context.language.isKnown,
              label(context.model, limit: 128), label(context.firmwareAtDiscovery, limit: 128),
              label(context.packageVersion, limit: 64), GuidancePackageRequest.validIdentifier(context.category),
              GuidancePackageRequest.validIdentifier(context.service), (notice == nil) == (noticeProvenance == nil) else {
            throw FirmwareError.invalid("Unsupported or incomplete voice-package backup.")
        }
        try metadata.validate(limit: 1_048_576); try package.validate(limit: 32_000_000)
        try packageProvenance.validate(limit: 16_384)
        try notice?.validate(limit: 1_048_576); try noticeProvenance?.validate(limit: 16_384)
        _ = try SonyMetadataEnvelope.decode(metadata.data, category: context.category, service: context.service)
        try Task.checkCancellation()
    }

    /// The caller obtains this request from a fresh regional/service read. Import uses the saved
    /// metadata's eligibility rules with the current firmware and serial, not the export-time labels.
    func restore(for request: GuidancePackageRequest, directory: URL = directory) throws -> GuidanceInstallationAssets {
        try Task.checkCancellation()
        try validate(); try request.validate()
        guard request.model == context.model, request.category == context.category,
              request.service == context.service, request.language == context.language else {
            throw FirmwareError.invalid("This saved package does not match the headphones' model, language or reported service.")
        }
        let source = try GuidanceMetadataDownload(data: metadata.data, request: request)
        guard let offer = source.metadata.offer, offer.version == context.packageVersion else {
            throw FirmwareError.invalid("The original metadata does not offer this saved package for the connected headphones.")
        }
        _ = try GuidanceDownloads.verify(package.data, source: source)
        if offer.notice != nil {
            guard let notice else { throw FirmwareError.invalid("The saved package is missing Sony's required notice.") }
            _ = try GuidanceNoticeDownloads.verify(notice.data, source: source)
        } else if notice != nil { throw FirmwareError.invalid("The saved notice is not referenced by this package's metadata.") }

        let original = try encoded()
        // Preserve the original export, including its provenance, alongside newly validated archives.
        // A different eligible firmware gets its own derived record; no earlier discovery is rewritten.
        let binding = Data([request.model, request.firmware, String(request.language.rawValue)].joined(separator: "\0").utf8)
        let target = directory.appendingPathComponent(GuidanceDownloads.sha256(original + binding), isDirectory: true)
        func readPublished() throws -> GuidanceInstallationAssets {
            guard try GuidanceDownloads.boundedRead(target.appendingPathComponent("original-backup.json"), limit: Self.encodedLimit) == original else {
                throw FirmwareError.invalid("An existing imported voice-package backup changed. It was preserved.")
            }
            let packagePath = GuidanceDownloads.destination(for: source, in: target.appendingPathComponent("packages"))
            let archive = try GuidanceDownloads.readArchive(at: packagePath, source: source)
            let noticePath = GuidanceDownloads.destination(for: source, in: target.appendingPathComponent("notices"))
            let notice = try offer.notice.map { _ in try GuidanceNoticeDownloads.readArchive(at: noticePath, source: source) }
            return try .init(source: source, archive: archive, notice: notice)
        }
        if FileManager.default.fileExists(atPath: target.path) { return try readPublished() }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try original.write(to: staging.appendingPathComponent("original-backup.json"))
        _ = try GuidanceDownloads.preserve(package.data, source: source, directory: staging.appendingPathComponent("packages"))
        if let notice { _ = try GuidanceNoticeDownloads.preserve(notice.data, source: source, directory: staging.appendingPathComponent("notices")) }
        try Task.checkCancellation()
        do { try FileManager.default.moveItem(at: staging, to: target) }
        catch { guard FileManager.default.fileExists(atPath: target.path) else { throw error } }
        return try readPublished()
    }
}
