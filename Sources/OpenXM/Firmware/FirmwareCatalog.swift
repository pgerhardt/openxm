import Foundation
import CryptoKit

struct FirmwareOffer: Equatable, Sendable {
    let region: FirmwareRegion
    let sourceVersion: String
    let targetVersion: String
    let url: URL
    let size: Int
    let sha1: String

    var pinnedRelease: FirmwareRelease? {
        FirmwareRelease.allCases.first {
            $0.region == region && $0.version == targetVersion && $0.size == size && $0.sha1 == sha1 && $0.downloadURL == url
        }
    }
}

struct FirmwareMetadata: Equatable, Sendable {
    static let url = url(for: .international)
    static func url(for region: FirmwareRegion) -> URL {
        URL(string: "https://info.update.sony.net/HP001/\(region.serviceID)/info/info.xml")!
    }
    let region: FirmwareRegion
    let lastUpdate: String
    let offers: [FirmwareOffer]

    static func decode(_ data: Data, region: FirmwareRegion = .international) throws -> Self {
        try parseXML(SonyMetadataEnvelope.decode(data, category: "HP001", service: region.serviceID), region: region)
    }

    static func parseXML(_ data: Data, region: FirmwareRegion = .international) throws -> Self {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw FirmwareError.invalid("Unsupported Sony metadata document.")
        }
        let delegate = MetadataParser(region: region)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.sawControl, !delegate.offers.isEmpty else {
            throw FirmwareError.invalid("Sony metadata contains no supported \(region.title) XM3 update rules.")
        }
        return Self(region: region, lastUpdate: delegate.lastUpdate, offers: delegate.offers)
    }
}

private final class MetadataParser: NSObject, XMLParserDelegate {
    let region: FirmwareRegion
    init(region: FirmwareRegion) { self.region = region }
    var valid = true
    var sawControl = false
    var lastUpdate = ""
    var offers: [FirmwareOffer] = []
    private var path: [String] = []
    private var model: String?
    private var version: String?
    private var distribution: [String: String]?
    private var seenRules: Set<String> = []
    private var conditionValid = true

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(element)
        if path.count > 24 { valid = false; parser.abortParsing(); return }
        switch path.joined(separator: "/") {
        case "InformationFile":
            valid = attributes["Noop"] == "false" && attributes["Version"] == "1.0"
            lastUpdate = attributes["LastUpdate"] ?? "Unreported"
        case "InformationFile/ControlConditions":
            if sawControl || attributes["DefaultServiceStatus"] != "open" || attributes["DefaultVariance"] != "0" { valid = false }
            sawControl = true
        case "InformationFile/ApplyConditions/ApplyCondition":
            model = nil; version = nil; distribution = nil; seenRules = []; conditionValid = true
        case "InformationFile/ApplyConditions/ApplyCondition/Rules/Rule":
            guard let key = attributes["Key"], seenRules.insert(key).inserted, attributes["Type"] == "System" else {
                conditionValid = false; return
            }
            switch key {
            case "Model": model = attributes["Value"]; conditionValid = conditionValid && attributes["Operator"] == "Equal"
            case "FirmwareVersion": version = attributes["Value"]; conditionValid = conditionValid && attributes["Operator"] == "Equal"
            case "SerialNo": conditionValid = conditionValid && attributes["Operator"] == "GreaterThanEqual" && attributes["Value"] == "0"
            default: conditionValid = false
            }
        case "InformationFile/ApplyConditions/ApplyCondition/Distributions/Distribution":
            if attributes["ID"] == "FW" {
                if distribution != nil { conditionValid = false }
                distribution = attributes
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { if !path.isEmpty { path.removeLast() } }
        guard path.joined(separator: "/") == "InformationFile/ApplyConditions/ApplyCondition" else { return }
        guard conditionValid, model == "WH-1000XM3", let source = version, !source.isEmpty,
              let item = distribution, item["InstallType"] == "binary", let target = item["Version"], !target.isEmpty,
              let rawURL = item["URI"], var components = URLComponents(string: rawURL),
              ["http", "https"].contains(components.scheme), components.host == "info.update.sony.net",
              components.user == nil, components.password == nil, components.port == nil, components.query == nil,
              components.fragment == nil, components.path.hasPrefix("/HP001/\(region.serviceID)/contents/"),
              !components.path.contains(".."), let size = item["Size"].flatMap(Int.init), size > 0, size <= 32_000_000,
              let hash = item["MAC"], hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) else {
            valid = false; return
        }
        components.scheme = "https"
        guard let url = components.url else { valid = false; return }
        offers.append(FirmwareOffer(region: region, sourceVersion: source, targetVersion: target, url: url, size: size, sha1: hash.lowercased()))
        if offers.count > 128 { valid = false; parser.abortParsing() }
    }
}

/// Explicit network reads only. No account, device identifiers, cookies or credentials are sent.
final class FirmwareNetworkPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let scope: @Sendable (URL) -> Bool
    init(scope: @escaping @Sendable (URL) -> Bool = { _ in true }) { self.scope = scope }
    func allows(_ url: URL) -> Bool { Self.allowed(url) && scope(url) }
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && ["info.update.sony.net", "raw.githubusercontent.com"].contains(url.host)
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allows) == true ? request : nil)
    }
}

enum FirmwareDownloads {
    static let directory = FirmwareJournalStore.url.deletingLastPathComponent().appendingPathComponent("Firmware", isDirectory: true)

    static func fetch(_ url: URL, limit: Int, expectedSize: Int? = nil,
                      allowedURL: @escaping @Sendable (URL) -> Bool = { _ in true },
                      progress: @escaping @MainActor (Int, Int?) -> Void = { _, _ in }) async throws -> Data {
        let policy = FirmwareNetworkPolicy(scope: allowedURL)
        guard policy.allows(url) else { throw FirmwareError.invalid("Package download URL is not allowed.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("OpenXM-firmware/1", forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url.map(policy.allows) == true,
              response.expectedContentLength <= limit else { throw FirmwareError.invalid("The package server returned an unexpected response.") }
        if let expectedSize, response.expectedContentLength >= 0, response.expectedContentLength != expectedSize {
            throw FirmwareError.invalid("The server's file size differs from the expected package size.")
        }
        var data = Data(); data.reserveCapacity(expectedSize ?? 20_000)
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < limit else { throw FirmwareError.invalid("The download exceeded its expected size.") }
            data.append(byte)
            if data.count % 65_536 == 0 { await progress(data.count, expectedSize) }
        }
        if let expectedSize, data.count != expectedSize { throw FirmwareError.invalid("The package download was incomplete.") }
        await progress(data.count, expectedSize)
        return data
    }

    static func metadata(region: FirmwareRegion = .international) async throws -> FirmwareMetadata {
        try FirmwareMetadata.decode(await fetch(FirmwareMetadata.url(for: region), limit: 1_048_576), region: region)
    }

    static func package(_ release: FirmwareRelease, directory: URL = directory,
                        progress: @escaping @MainActor (Int, Int?) -> Void) async throws -> URL {
        let destination = directory.appendingPathComponent(release.cacheFilename)
        if FileManager.default.fileExists(atPath: destination.path) {
            let image = try FirmwareImage(url: destination)
            guard image.release == release else { throw FirmwareError.invalid("A different cached package exists at \(destination.path). It was preserved.") }
            return destination
        }
        let data = try await fetch(release.downloadURL, limit: release.size, expectedSize: release.size, progress: progress)
        let image = try FirmwareImage(data: data)
        guard image.release == release else { throw FirmwareError.invalid("The downloaded package has the wrong version.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Publish a complete file without replacing anything created while the request was in flight.
        let temporary = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.linkItem(at: temporary, to: destination)
        return destination
    }
}
