import Foundation

/// Table 2 voice-guidance protocol, independently implemented from the pinned Sony reference.
/// See docs/VOICE-GUIDANCE.md for field provenance and the limits of current hardware evidence.
enum V1VoiceGuidance {
    struct Query: Equatable {
        let command: UInt8
        let detail: UInt8
        var payload: [UInt8] { [command, 0x01, detail] }
        var reply: MDRLink.Matcher { .init(.dataMdrNo2, command + 1, 0x01, detail: detail) }
    }

    static func queries(for capability: VoiceGuidanceCapability?) -> [Query] {
        guard let capability else { return [] }
        var queries: [Query] = []
        if capability.supportsOnOff {
            queries += [Query(command: 0x42, detail: 1), Query(command: 0x46, detail: 1)]
        }
        if capability.supportsLanguage {
            queries.append(Query(command: 0x42, detail: 2))
            queries += (UInt8(2)...5).map { Query(command: 0x46, detail: $0) }
        }
        return queries
    }

    static func capability(_ payload: [UInt8]) throws -> VoiceGuidanceCapability {
        var r = ByteReader(payload)
        guard try r.u8() == 0x41, try r.u8() == 1 else { throw invalid("capability selector") }
        let onOff = try r.u8(), language = try r.u8()
        guard onOff <= 1, language <= 1 else { throw invalid("capability flags") }
        var languages: [GuidanceLanguage] = []
        // A device without language switching ends its reply after the two support flags.
        if language == 1 {
            let count = Int(try r.u8())
            guard count > 0 else { throw invalid("empty language list") }
            languages = try r.take(count).map(GuidanceLanguage.init(rawValue:))
            guard Set(languages).count == languages.count, !languages.contains(.init(rawValue: 0)) else {
                throw invalid("invalid language list")
            }
        }
        guard r.isAtEnd else { throw invalid("capability length") }
        return VoiceGuidanceCapability(supportsOnOff: onOff == 1, supportsLanguage: language == 1, languages: languages)
    }

    enum Reply: Equatable {
        case onOff(Bool)
        case language(GuidanceLanguage)
        case requiredTime(UInt8)
        case downloadService(GuidanceDownloadService?)
        case updateMethod(GuidanceUpdateMethod)
        case onOffAvailable(Bool?)
        case languageUpdateEnabled(Bool?)
    }

    static func reply(_ payload: [UInt8]) throws -> Reply? {
        var r = ByteReader(payload)
        let command = try r.u8()
        guard [0x43, 0x45, 0x47, 0x49].contains(command), try r.u8() == 1 else { return nil }
        let detail = try r.u8()
        let reply: Reply
        if command == 0x43 || command == 0x45 {
            guard detail == 1 || detail == 2 else { return nil }
            let raw = try r.u8()
            // CommonStatus.ENABLE = 0, DISABLE = 1. The meaning depends on the detail:
            // on/off availability versus the language transfer's changeUpdateStatus flag.
            let enabled: Bool? = raw <= 1 ? raw == 0 : nil
            reply = detail == 1 ? .onOffAvailable(enabled) : .languageUpdateEnabled(enabled)
        } else {
            switch detail {
            case 1:
                let raw = try r.u8()
                guard raw <= 1 else { throw invalid("on/off value") }
                reply = .onOff(raw == 1)
            case 2: reply = .language(GuidanceLanguage(rawValue: try r.u8()))
            case 3: reply = .requiredTime(try r.u8())
            case 4:
                let method = try r.u8()
                guard method == 1 else {
                    // New methods cannot inherit a previous Automagic service or authorize a download.
                    return .downloadService(nil)
                }
                let categoryID = try identifier(&r), serialNumber = try identifier(&r)
                let count = Int(try r.u8())
                guard count > 0 else { throw invalid("empty service list") }
                var entries: [GuidanceDownloadService.Entry] = []
                for _ in 0..<count {
                    let language = GuidanceLanguage(rawValue: try r.u8())
                    let serviceID = try identifier(&r)
                    guard language.rawValue != 0, !entries.contains(where: { $0.language == language }) else {
                        throw invalid("duplicate or unspecified service language")
                    }
                    entries.append(.init(language: language, serviceID: serviceID))
                }
                reply = .downloadService(.init(categoryID: categoryID, serialNumber: serialNumber, entries: entries))
            case 5:
                let method = try r.u8()
                let parameters = try r.take(r.remaining)
                if (0x10...0x13).contains(method), parameters.count != 2 { throw invalid("CSR update parameters") }
                // Other module formats are retained for diagnostics only; no transfer is authorized here.
                reply = .updateMethod(.init(code: method, parameters: parameters))
            default: return nil
            }
        }
        guard r.isAtEnd else { throw invalid("reply length") }
        return reply
    }

    private static func identifier(_ r: inout ByteReader) throws -> String {
        let count = Int(try r.u8())
        guard (1...128).contains(count) else { throw invalid("identifier length") }
        let bytes = try r.take(count)
        // Identifiers will later become URL components and rule inputs. Reject paths, controls and
        // lossy UTF-8 rather than normalizing them into a different Sony service.
        guard bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0)
            || (0x61...0x7A).contains($0) || $0 == 0x2D || $0 == 0x5F }) else {
            throw invalid("download identifier")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func invalid(_ field: String) -> DriverError { .malformed("voice guidance \(field)") }
}
