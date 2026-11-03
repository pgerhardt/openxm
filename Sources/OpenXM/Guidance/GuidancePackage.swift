import Foundation

struct GuidancePackageRequest: Equatable, Sendable {
    let category: String
    let service: String
    let model: String
    let firmware: String
    let serial: String
    let language: GuidanceLanguage

    /// The production entry point requires a fresh connected-device read, including the ordinary
    /// firmware service for region identification. A language label alone never selects a service.
    @MainActor
    static func make(state: DeviceState, firmwareCategory: String, firmwareService: String,
                     language: GuidanceLanguage) throws -> Self {
        guard state.family == .v1, state.modelName == "WH-1000XM3", firmwareCategory == "HP001",
              firmwareService == "MDRID291600", let version = state.firmware, !version.isEmpty else {
            throw FirmwareError.invalid("Voice-package discovery currently requires international WH-1000XM3 headphones.")
        }
        guard let capability = state.capabilities.voiceGuidanceCapability, capability.supportsLanguage,
              capability.languages.contains(language), let descriptor = state.voiceGuidanceDetails.downloadService,
              descriptor.entries.filter({ $0.language == language }).count == 1,
              let entry = descriptor.entries.first(where: { $0.language == language }),
              entry.serviceID != firmwareService else {
            throw FirmwareError.invalid("The headphones did not report a download service for this language.")
        }
        let request = Self(category: descriptor.categoryID, service: entry.serviceID, model: "WH-1000XM3",
                           firmware: version, serial: descriptor.serialNumber, language: language)
        try request.validate()
        return request
    }

    func validate() throws {
        guard [category, service, serial].allSatisfy(Self.validIdentifier), !model.isEmpty, !firmware.isEmpty,
              language.rawValue != 0 else { throw FirmwareError.invalid("Invalid voice-package request identifiers.") }
    }

    static func validIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    var metadataURL: URL { URL(string: "https://info.update.sony.net/\(category)/\(service)/info/info.xml")! }

    func permits(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.host == "info.update.sony.net", c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil, c.percentEncodedPath == c.path,
              !c.path.contains(".."), !c.path.contains("\\"), !c.path.contains("//") else { return false }
        return url == metadataURL || (c.path.hasPrefix("/\(category)/\(service)/contents/") && !c.path.hasSuffix("/"))
    }
}

struct GuidancePackageOffer: Equatable, Sendable {
    let version: String
    let url: URL
    let size: Int
    let sha1: String
    var notice: GuidanceNoticeOffer? = nil
    var instructions: GuidancePackageInstructions? = nil
}

struct GuidanceNoticeOffer: Equatable, Sendable {
    let id, version: String
    let url: URL
    let size: Int
    let sha1: String
}

struct GuidancePackageInstructions: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        let language, title, text: String
        var id: String { language }
    }
    let defaultLanguage: String
    let entries: [Entry]
    var preferred: Entry? { entries.first { $0.language == "English" } ?? entries.first { $0.language == defaultLanguage } }
}

struct GuidancePackageMetadata: Equatable, Sendable {
    let lastUpdate: String
    let offer: GuidancePackageOffer?

    static func decode(_ data: Data, for request: GuidancePackageRequest) throws -> Self {
        try request.validate()
        let xml = try SonyMetadataEnvelope.decode(data, category: request.category, service: request.service)
        return try parseXML(xml, for: request)
    }

    static func parseXML(_ data: Data, for request: GuidancePackageRequest) throws -> Self {
        try request.validate()
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw FirmwareError.invalid("Unsupported voice-package metadata document.")
        }
        let delegate = GuidanceMetadataParser(request: request)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.valid, delegate.sawControl, delegate.sawApplyConditions else {
            throw FirmwareError.invalid("Sony's voice-package metadata could not be validated.")
        }
        guard delegate.offers.count <= 1 else {
            throw FirmwareError.invalid("Sony's metadata selects multiple voice packages. No package was selected.")
        }
        return .init(lastUpdate: delegate.lastUpdate, offer: delegate.offers.first)
    }
}

private final class GuidanceMetadataParser: NSObject, XMLParserDelegate {
    let request: GuidancePackageRequest
    var valid = true
    var sawControl = false
    var sawApplyConditions = false
    var lastUpdate = ""
    var offers: [GuidancePackageOffer] = []
    private var path: [String] = []
    private var rules: [[String: String]] = []
    private var distributions: [[String: String]] = []
    private var rulesSeen = false
    private var distributionsSeen = false
    private var conditionCount = 0
    private var descriptionsSeen = false
    private var defaultLanguage = ""
    private var instructions: [GuidancePackageInstructions.Entry] = []
    private var descriptionAttributes: [String: String] = [:]
    private var descriptionText = ""

    init(request: GuidancePackageRequest) { self.request = request }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(element)
        guard path.count <= 24 else { valid = false; parser.abortParsing(); return }
        switch path.joined(separator: "/") {
        case "InformationFile":
            valid = attributes["Version"] == "1.0" && attributes["Noop"] == "false"
            lastUpdate = attributes["LastUpdate"] ?? "Not reported"
        case "InformationFile/ControlConditions":
            if sawControl || attributes["DefaultServiceStatus"] != "open" || attributes["DefaultVariance"] != "0" { valid = false }
            sawControl = true
        case "InformationFile/ApplyConditions":
            if sawApplyConditions { valid = false }
            sawApplyConditions = true
        case "InformationFile/ApplyConditions/ApplyCondition":
            conditionCount += 1
            if conditionCount > 256 { valid = false; parser.abortParsing() }
            rules = []; distributions = []; rulesSeen = false; distributionsSeen = false
            descriptionsSeen = false; defaultLanguage = ""; instructions = []; descriptionText = ""
        case "InformationFile/ApplyConditions/ApplyCondition/Rules":
            if rulesSeen { valid = false }
            rulesSeen = true
        case "InformationFile/ApplyConditions/ApplyCondition/Rules/Rule": rules.append(attributes)
        case "InformationFile/ApplyConditions/ApplyCondition/Distributions":
            if distributionsSeen { valid = false }
            distributionsSeen = true
        case "InformationFile/ApplyConditions/ApplyCondition/Distributions/Distribution": distributions.append(attributes)
        case "InformationFile/ApplyConditions/ApplyCondition/Descriptions":
            if descriptionsSeen { valid = false }
            descriptionsSeen = true
            defaultLanguage = attributes["DefaultLang"] ?? ""
        case "InformationFile/ApplyConditions/ApplyCondition/Descriptions/Description":
            descriptionAttributes = attributes; descriptionText = ""
        default:
            // Control variants can narrow eligibility; never ignore an unfamiliar control rule.
            if path.count > 2, path[1] == "ControlConditions" { valid = false }
            if path.count >= 2, path[0] != "InformationFile" { valid = false }
            if path.count == 2 { valid = false }
            if path.count == 3, path[1] == "ApplyConditions" { valid = false }
            if path.count == 4, !["Rules", "Distributions", "Descriptions"].contains(element) { valid = false }
            if path.count > 4, path[3] == "Rules" { valid = false }
            if path.count > 4, path[3] == "Distributions" { valid = false }
            if path.count > 4, path[3] == "Descriptions" { valid = false }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { appendDescription(string, parser: parser) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { valid = false; parser.abortParsing(); return }
        appendDescription(text, parser: parser)
    }
    private func appendDescription(_ text: String, parser: XMLParser) {
        guard path.last == "Description" else { return }
        descriptionText += text
        if descriptionText.utf8.count > 32_768 { valid = false; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = path.popLast() }
        if path.joined(separator: "/") == "InformationFile/ApplyConditions/ApplyCondition/Descriptions/Description" {
            guard let language = descriptionAttributes["Lang"], !language.isEmpty, language.utf8.count <= 128,
                  let title = descriptionAttributes["Title"], title.utf8.count <= 256,
                  !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  instructions.count < 64, !instructions.contains(where: { $0.language == language }) else {
                valid = false; return
            }
            instructions.append(.init(language: language, title: title, text: descriptionText))
            return
        }
        guard path.joined(separator: "/") == "InformationFile/ApplyConditions/ApplyCondition" else { return }
        guard rulesSeen, distributionsSeen, !rules.isEmpty else { valid = false; return }
        guard rules.allSatisfy({ GuidanceRule.matches($0, request: request) }) else { return }
        let binaries = distributions.filter { $0["InstallType"] == "binary" }
        let notices = distributions.filter { $0["InstallType"] == "notice" }
        guard binaries.count == 1, notices.count <= 1, binaries.count + notices.count == distributions.count,
              let binary = binaries.first.flatMap({ asset($0, limit: 32_000_000) }) else { valid = false; return }
        let notice = notices.first.flatMap { asset($0, limit: 1_048_576) }
        guard notices.isEmpty || (notice != nil && notice?.url != binary.url),
              !descriptionsSeen || instructions.contains(where: { $0.language == defaultLanguage }) else { valid = false; return }
        offers.append(.init(version: binary.version, url: binary.url, size: binary.size, sha1: binary.sha1,
            notice: notice, instructions: descriptionsSeen ? .init(defaultLanguage: defaultLanguage, entries: instructions) : nil))
    }

    private func asset(_ attributes: [String: String], limit: Int) -> GuidanceNoticeOffer? {
        guard let id = attributes["ID"], GuidancePackageRequest.validIdentifier(id),
              attributes["InstallParams", default: ""].isEmpty,
              let version = attributes["Version"], !version.isEmpty, version.utf8.count <= 64,
              let size = attributes["Size"].flatMap(Int.init), (1...limit).contains(size),
              let sha1 = attributes["MAC"], sha1.utf8.count == 40,
              sha1.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let uri = attributes["URI"], var components = URLComponents(string: uri),
              ["http", "https"].contains(components.scheme) else { return nil }
        // Sony's reference upgrades HTTP distribution URLs to HTTPS before requesting them.
        components.scheme = "https"
        guard let url = components.url, request.permits(url), url != request.metadataURL else { return nil }
        return .init(id: id, version: version, url: url, size: size, sha1: sha1.lowercased())
    }
}

enum GuidanceRule {
    /// Unknown keys/operators are not evidence that this device is eligible.
    static func matches(_ rule: [String: String], request: GuidancePackageRequest) -> Bool {
        guard rule["Type"] == "System", let key = rule["Key"], let expected = rule["Value"],
              !expected.isEmpty, let operation = rule["Operator"] else { return false }
        let order: ComparisonResult
        switch key {
        case "Model":
            guard operation == "Equal" || operation == "NotEqual" else { return false }
            order = request.model == expected ? .orderedSame : .orderedAscending
        case "FirmwareVersion":
            guard let comparison = compareVersions(request.firmware, expected) else { return false }
            order = comparison
        case "SerialNo":
            if operation == "Equal" || operation == "NotEqual" {
                order = request.serial == expected ? .orderedSame : .orderedAscending
            } else {
                guard let comparison = compareDecimal(request.serial, expected) else { return false }
                order = comparison
            }
        default: return false
        }
        switch operation {
        case "Equal": return order == .orderedSame
        case "NotEqual": return order != .orderedSame
        case "LessThan": return order == .orderedAscending
        case "LessThanEqual": return order != .orderedDescending
        case "GreaterThan": return order == .orderedDescending
        case "GreaterThanEqual": return order != .orderedAscending
        default: return false
        }
    }

    private static func compareDecimal(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard !lhs.isEmpty, !rhs.isEmpty, lhs.utf8.allSatisfy({ (48...57).contains($0) }),
              rhs.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let a = lhs.drop(while: { $0 == "0" }), b = rhs.drop(while: { $0 == "0" })
        if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
        if a == b { return .orderedSame }
        return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        let a = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let b = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(a.count), (1...4).contains(b.count) else { return nil }
        var result = ComparisonResult.orderedSame
        for index in 0..<max(a.count, b.count) {
            guard let order = compareDecimal(index < a.count ? a[index] : "0", index < b.count ? b[index] : "0") else { return nil }
            if result == .orderedSame { result = order }
        }
        return result
    }
}
