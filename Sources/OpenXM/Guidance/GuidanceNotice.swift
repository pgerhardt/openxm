import Foundation
import CryptoKit

/// Plain text from Sony's NoticeFile. Display never evaluates HTML or treats it as app instructions.
struct GuidanceNoticeDocument: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        let locale, text: String
        var id: String { locale }
    }
    let defaultLocale: String
    let entries: [Entry]
    var preferred: Entry? { entries.first { $0.locale == "UK" } ?? entries.first { $0.locale == defaultLocale } }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576, let raw = String(data: data, encoding: .utf8),
              !raw.contains("<!DOCTYPE"), !raw.contains("<!ENTITY") else {
            throw FirmwareError.invalid("Unsupported Sony notice document.")
        }
        // The observed Sony notice has whitespace before its XML declaration. Normalize only the
        // parsing input; size/hash verification and the archived file always use the original bytes.
        let parser = XMLParser(data: Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        let delegate = GuidanceNoticeParser()
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid,
              delegate.entries.contains(where: { $0.locale == delegate.defaultLocale }) else {
            throw FirmwareError.invalid("Sony's notice format could not be read. No notice text was substituted.")
        }
        return .init(defaultLocale: delegate.defaultLocale, entries: delegate.entries)
    }
}

private final class GuidanceNoticeParser: NSObject, XMLParserDelegate {
    var valid = true
    var defaultLocale = ""
    var entries: [GuidanceNoticeDocument.Entry] = []
    private var path: [String] = []
    private var locale = ""
    private var text = ""
    private var sawText = false

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(element)
        switch path.joined(separator: "/") {
        case "NoticeFile":
            guard attributes["Version"] == "1.0", let value = attributes["DefaultLocale"],
                  GuidancePackageRequest.validIdentifier(value) else { valid = false; parser.abortParsing(); return }
            defaultLocale = value
        case "NoticeFile/Notice":
            guard let value = attributes["Locale"], GuidancePackageRequest.validIdentifier(value),
                  entries.count < 64, !entries.contains(where: { $0.locale == value }) else {
                valid = false; parser.abortParsing(); return
            }
            locale = value; text = ""; sawText = false
        case "NoticeFile/Notice/Text":
            if sawText { valid = false; parser.abortParsing() }
            sawText = true
        default: valid = false; parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string, parser: parser) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let value = String(data: CDATABlock, encoding: .utf8) else { valid = false; parser.abortParsing(); return }
        append(value, parser: parser)
    }
    private func append(_ value: String, parser: XMLParser) {
        if path == ["NoticeFile", "Notice", "Text"] {
            text += value
            if text.utf8.count > 65_536 { valid = false; parser.abortParsing() }
        } else if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            valid = false; parser.abortParsing()
        }
    }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = path.popLast() }
        if path == ["NoticeFile", "Notice"] {
            guard sawText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { valid = false; return }
            entries.append(.init(locale: locale, text: text))
        }
    }
}

struct GuidanceNoticeArchive: Equatable, Sendable {
    let directory: URL
    let sha256: String
    let document: GuidanceNoticeDocument
    var noticeURL: URL { directory.appendingPathComponent("notice.xml") }
}

enum GuidanceNoticeDownloads {
    static let directory = FirmwareJournalStore.url.deletingLastPathComponent().appendingPathComponent("VoiceGuidanceNotices", isDirectory: true)

    static func notice(_ source: GuidanceMetadataDownload, directory: URL = directory) async throws -> GuidanceNoticeArchive? {
        try Task.checkCancellation()
        guard let offer = source.metadata.offer?.notice else { return nil }
        let target = GuidanceDownloads.destination(for: source, in: directory)
        if FileManager.default.fileExists(atPath: target.path) { return try readArchive(at: target, source: source) }
        let data = try await FirmwareDownloads.fetch(offer.url, limit: offer.size, expectedSize: offer.size,
                                                     allowedURL: { source.request.permits($0) })
        return try preserve(data, source: source, directory: directory)
    }

    /// Notices have their own immutable archive, so collecting one never modifies a package archive.
    static func preserve(_ data: Data, source: GuidanceMetadataDownload, directory: URL) throws -> GuidanceNoticeArchive {
        let document = try verify(data, source: source)
        let digest = GuidanceDownloads.sha256(data)
        try Task.checkCancellation()
        let target = GuidanceDownloads.destination(for: source, in: directory)
        if FileManager.default.fileExists(atPath: target.path) { return try readArchive(at: target, source: source) }
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".notice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging.appendingPathComponent("notice.xml"))
        try source.data.write(to: staging.appendingPathComponent("metadata.enc"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(provenance(source, digest: digest)).write(to: staging.appendingPathComponent("provenance.json"))
        try Task.checkCancellation()
        do { try FileManager.default.moveItem(at: staging, to: target) }
        catch {
            guard FileManager.default.fileExists(atPath: target.path) else { throw error }
            return try readArchive(at: target, source: source)
        }
        return .init(directory: target, sha256: digest, document: document)
    }

    static func verify(_ data: Data, source: GuidanceMetadataDownload) throws -> GuidanceNoticeDocument {
        guard let offer = source.metadata.offer?.notice, data.count == offer.size,
              Insecure.SHA1.hash(data: data).map({ String(format: "%02x", $0) }).joined() == offer.sha1 else {
            throw FirmwareError.invalid("The notice does not match Sony's metadata size and SHA-1.")
        }
        return try GuidanceNoticeDocument.parse(data)
    }

    static func readArchive(at target: URL, source: GuidanceMetadataDownload) throws -> GuidanceNoticeArchive {
        do {
            guard let offer = source.metadata.offer?.notice else { throw FirmwareError.invalid("No notice") }
            let data = try GuidanceDownloads.boundedRead(target.appendingPathComponent("notice.xml"), limit: offer.size)
            let document = try verify(data, source: source)
            let digest = GuidanceDownloads.sha256(data)
            guard try GuidanceDownloads.boundedRead(target.appendingPathComponent("metadata.enc"), limit: 1_048_576) == source.data else {
                throw FirmwareError.invalid("Notice metadata differs")
            }
            let saved = try JSONDecoder().decode(Provenance.self, from: GuidanceDownloads.boundedRead(target.appendingPathComponent("provenance.json"), limit: 16_384))
            guard saved == (try provenance(source, digest: digest)) else { throw FirmwareError.invalid("Notice provenance differs") }
            return .init(directory: target, sha256: digest, document: document)
        } catch {
            throw FirmwareError.invalid("An existing notice archive could not be validated. It was preserved at \(target.path).")
        }
    }

    private struct Provenance: Codable, Equatable {
        let formatVersion: Int
        let model, firmwareAtDiscovery, category, service, noticeID, noticeVersion, metadataURL, metadataSHA256, noticeURL, sha1, sha256: String
        let languageCode: UInt8
        let size: Int
    }
    private static func provenance(_ source: GuidanceMetadataDownload, digest: String) throws -> Provenance {
        guard let offer = source.metadata.offer?.notice else { throw FirmwareError.invalid("No notice") }
        let request = source.request
        return .init(formatVersion: 1, model: request.model, firmwareAtDiscovery: request.firmware,
            category: request.category, service: request.service, noticeID: offer.id, noticeVersion: offer.version,
            metadataURL: request.metadataURL.absoluteString, metadataSHA256: GuidanceDownloads.sha256(source.data),
            noticeURL: offer.url.absoluteString, sha1: offer.sha1, sha256: digest,
            languageCode: request.language.rawValue, size: offer.size)
    }
}
