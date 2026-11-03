import Foundation
import CryptoKit

/// Retains the original Sony response alongside its interpretation. This is not an installable image.
struct GuidanceMetadataDownload: Sendable {
    let request: GuidancePackageRequest
    let data: Data
    let metadata: GuidancePackageMetadata

    init(data: Data, request: GuidancePackageRequest) throws {
        self.request = request
        self.data = data
        metadata = try GuidancePackageMetadata.decode(data, for: request)
    }
}

struct GuidancePackageArchive: Equatable, Sendable {
    let directory: URL
    let size: Int
    let sha256: String
    var packageURL: URL { directory.appendingPathComponent("package.bin") }
}

enum GuidanceDownloads {
    static let directory = FirmwareJournalStore.url.deletingLastPathComponent().appendingPathComponent("VoiceGuidance", isDirectory: true)

    static func metadata(for request: GuidancePackageRequest) async throws -> GuidanceMetadataDownload {
        try request.validate()
        let data = try await FirmwareDownloads.fetch(request.metadataURL, limit: 1_048_576,
                                                     allowedURL: { request.permits($0) })
        try Task.checkCancellation()
        return try GuidanceMetadataDownload(data: data, request: request)
    }

    static func package(_ source: GuidanceMetadataDownload, directory: URL = directory,
                        progress: @escaping @MainActor (Int, Int?) -> Void) async throws -> GuidancePackageArchive {
        try Task.checkCancellation()
        guard let offer = source.metadata.offer else { throw FirmwareError.invalid("No eligible voice package was offered.") }
        let target = destination(for: source, in: directory)
        if FileManager.default.fileExists(atPath: target.path) { return try readArchive(at: target, source: source) }
        let data = try await FirmwareDownloads.fetch(offer.url, limit: offer.size, expectedSize: offer.size,
                                                     allowedURL: { source.request.permits($0) }, progress: progress)
        try Task.checkCancellation()
        return try preserve(data, source: source, directory: directory)
    }

    /// A service/metadata/device-state-specific directory keeps distinct discovery records separate.
    /// Stage every file before publishing. Never replace an existing archive, including an invalid one.
    static func preserve(_ data: Data, source: GuidanceMetadataDownload, directory: URL) throws -> GuidancePackageArchive {
        let digest = try verify(data, source: source)
        try Task.checkCancellation()
        let target = destination(for: source, in: directory)
        if FileManager.default.fileExists(atPath: target.path) { return try readArchive(at: target, source: source) }
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("package.bin"))
        try source.data.write(to: staging.appendingPathComponent("metadata.enc"))
        let provenance = try provenance(for: source, sha256: digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(provenance).write(to: staging.appendingPathComponent("provenance.json"))
        try Task.checkCancellation()
        do { try FileManager.default.moveItem(at: staging, to: target) }
        catch {
            // Another download may have published the same offer while this one was in flight.
            guard FileManager.default.fileExists(atPath: target.path) else { throw error }
            return try readArchive(at: target, source: source)
        }
        return .init(directory: target, size: data.count, sha256: digest)
    }

    static func verify(_ data: Data, source: GuidanceMetadataDownload) throws -> String {
        guard let offer = source.metadata.offer, data.count == offer.size,
              Insecure.SHA1.hash(data: data).map({ String(format: "%02x", $0) }).joined() == offer.sha1 else {
            throw FirmwareError.invalid("The voice package does not match Sony's metadata size and SHA-1. It was not saved.")
        }
        return sha256(data)
    }

    static func destination(for source: GuidanceMetadataDownload, in root: URL) -> URL {
        let context = Data([source.request.model, source.request.firmware, String(source.request.language.rawValue)]
            .joined(separator: "\0").utf8)
        return root.appendingPathComponent(source.request.category, isDirectory: true)
            .appendingPathComponent(source.request.service, isDirectory: true)
            .appendingPathComponent(sha256(source.data + context), isDirectory: true)
    }

    static func readArchive(at target: URL, source: GuidanceMetadataDownload) throws -> GuidancePackageArchive {
        do {
            guard let offer = source.metadata.offer else { throw FirmwareError.invalid("No offer") }
            let bytes = try boundedRead(target.appendingPathComponent("package.bin"), limit: offer.size)
            let digest = try verify(bytes, source: source)
            guard try boundedRead(target.appendingPathComponent("metadata.enc"), limit: 1_048_576) == source.data else {
                throw FirmwareError.invalid("Metadata differs")
            }
            let saved = try JSONDecoder().decode(Provenance.self, from: boundedRead(target.appendingPathComponent("provenance.json"), limit: 16_384))
            guard saved == (try provenance(for: source, sha256: digest)) else { throw FirmwareError.invalid("Provenance differs") }
            return .init(directory: target, size: bytes.count, sha256: digest)
        } catch {
            throw FirmwareError.invalid("An existing voice-package archive could not be validated. It was preserved at \(target.path).")
        }
    }

    static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size <= limit else { throw FirmwareError.invalid("Invalid archive file") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw FirmwareError.invalid("Archive size exceeded") }
        return data
    }

    private struct Provenance: Codable, Equatable {
        let formatVersion: Int
        let model, firmwareAtDiscovery, category, service, language, packageVersion: String
        let languageCode: UInt8
        let metadataURL, downloadURL, metadataSHA256, sha1, sha256: String
        let size: Int
        let verification: String
    }

    private static func provenance(for source: GuidanceMetadataDownload, sha256: String) throws -> Provenance {
        guard let offer = source.metadata.offer else { throw FirmwareError.invalid("No eligible voice package") }
        let request = source.request
        return .init(formatVersion: 1, model: request.model, firmwareAtDiscovery: request.firmware,
                     category: request.category, service: request.service, language: request.language.title,
                     packageVersion: offer.version, languageCode: request.language.rawValue,
                     metadataURL: request.metadataURL.absoluteString, downloadURL: offer.url.absoluteString,
                     metadataSHA256: self.sha256(source.data), sha1: offer.sha1, sha256: sha256, size: offer.size,
                     verification: "Matched Sony metadata size and SHA-1; metadata envelope integrity checked. No publisher signature or installation compatibility verified.")
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
