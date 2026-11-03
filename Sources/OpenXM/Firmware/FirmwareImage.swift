import Foundation
import CryptoKit

enum FirmwareError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum FirmwareRegion: String, CaseIterable, Sendable, Identifiable {
    case international, japan, china
    var id: String { rawValue }
    var title: String {
        switch self { case .international: "International"; case .japan: "Japan"; case .china: "China" }
    }
    var serviceID: String {
        switch self { case .international: "MDRID291600"; case .japan: "MDRID291601"; case .china: "MDRID291602" }
    }
    init?(serviceID: String) {
        guard let region = Self.allCases.first(where: { $0.serviceID == serviceID }) else { return nil }
        self = region
    }
}

/// Pinned original WH-1000XM3 packages. Version alone never identifies a regional package.
enum FirmwareRelease: String, CaseIterable, Sendable, Identifiable {
    case xm3v200 = "international-2.0.0"
    case xm3v411 = "international-4.1.1"
    case xm3v422 = "international-4.2.2"
    case xm3v452 = "international-4.5.2"
    case xm3jp411 = "japan-4.1.1"
    case xm3jp422 = "japan-4.2.2"
    case xm3jp452 = "japan-4.5.2"
    case xm3cn413 = "china-4.1.3"
    case xm3cn422 = "china-4.2.2"
    case xm3cn452 = "china-4.5.2"
    var id: String { rawValue }
    var label: String { "\(region.title) \(version)" }
    var cacheFilename: String { "WH-1000XM3-\(region.rawValue)-\(version).bin" }
    var provenance: String { self == .xm3v200 ? "MDR Proxy archive, pinned Git commit" : "Sony firmware server" }
    init?(version: String, region: FirmwareRegion) {
        guard let release = Self.allCases.first(where: { $0.version == version && $0.region == region }) else { return nil }
        self = release
    }
    var version: String {
        switch self {
        case .xm3v200: "2.0.0"
        case .xm3v411: "4.1.1"
        case .xm3v422: "4.2.2"
        case .xm3v452: "4.5.2"
        case .xm3jp411: "4.1.1"
        case .xm3jp422: "4.2.2"
        case .xm3jp452: "4.5.2"
        case .xm3cn413: "4.1.3"
        case .xm3cn422: "4.2.2"
        case .xm3cn452: "4.5.2"
        }
    }
    var region: FirmwareRegion {
        switch self {
        case .xm3v200: .international
        case .xm3v411: .international
        case .xm3v422: .international
        case .xm3v452: .international
        case .xm3jp411: .japan
        case .xm3jp422: .japan
        case .xm3jp452: .japan
        case .xm3cn413: .china
        case .xm3cn422: .china
        case .xm3cn452: .china
        }
    }
    var size: Int {
        switch self {
        case .xm3v200: 2711470
        case .xm3v411: 2916572
        case .xm3v422: 2917412
        case .xm3v452: 3776802
        case .xm3jp411: 2916572
        case .xm3jp422: 2917412
        case .xm3jp452: 3776802
        case .xm3cn413: 2747762
        case .xm3cn422: 2748326
        case .xm3cn452: 3607712
        }
    }
    var sha1: String {
        switch self {
        case .xm3v200: "952e4c5816428f871f6f3a29d30976feb17d51c8"
        case .xm3v411: "683a383079f3cf5b95e5f03eb45329bdd760aece"
        case .xm3v422: "d9a66cf57ccee120afc02b3256ad2f4fb6a5c143"
        case .xm3v452: "442ac8d9e1fac3f22144316e0f8a41ad3f43a195"
        case .xm3jp411: "ae287fb4fbcf916df611b3749a42e2c24649edcf"
        case .xm3jp422: "e22d26ddf7a9f22a65eb4c870a0a7efa6c02145f"
        case .xm3jp452: "eb3bfb60bd634e99a9f5595a152203f029aeefad"
        case .xm3cn413: "088c2559b0c18c8933124fd57f1ae6318b089014"
        case .xm3cn422: "8e4642360f172e959e37ef8632a49f8302ed9e26"
        case .xm3cn452: "06f4c53ebb6e6042732dcf781caad60eb1d929f0"
        }
    }
    var sha256: String {
        switch self {
        case .xm3v200: "c0f3a263011e14d3ad24f53661dc9c9c4e7f4a2171efff0e929f2053a0ffe3bd"
        case .xm3v411: "1c9a05d5cea5a4c38474a9e8f7ec07628b3b1430eb596ef7de828615a9746c26"
        case .xm3v422: "533b6a342bb3b84c1d29307a1024a582563921809713c55d76c2c529dfabcc3e"
        case .xm3v452: "b67330f6f75a87c7798bc7c994a25f2df09ac66d8013f2536e8799838850aa43"
        case .xm3jp411: "21920e5df9ec03852249e22bb1f20e208fbda95b38cafbec6b23e066cccdfdb4"
        case .xm3jp422: "4d28f46b1f768a1872012723d449eb328341bcf120a7b96f6ae39d169e0d9f30"
        case .xm3jp452: "43cd4e1672c4c2c39a2133f83da95d81f12bfacab716e4eacf63275524a77ace"
        case .xm3cn413: "14eccb2ab8e4fe6c9a14598956b5fc7bb456ea5cb7398b97f4274da2b3595f71"
        case .xm3cn422: "2f32b75762b9c5ec9007b30804c5b51138f76bd0a6e8614105a784f4f223ae91"
        case .xm3cn452: "9192c308c3f0136599d2da74327f1418aa450df277c9403adc089b536dedbd21"
        }
    }
    var downloadURL: URL {
        switch self {
        case .xm3v200: URL(string: "https://raw.githubusercontent.com/lzghzr/MDR_Proxy/2e80d32e05f55ebf354389283e767e5a7c273e27/firmware/2916/MDRID291600/HDX-2916_V0200.952e4c5816428f871f6f3a29d30976feb17d51c8.bin")!
        case .xm3v411: URL(string: "https://info.update.sony.net/HP001/MDRID291600/contents/0002/HDX-2916_V0411.bin")!
        case .xm3v422: URL(string: "https://info.update.sony.net/HP001/MDRID291600/contents/0003/HDX-2916_V0422.bin")!
        case .xm3v452: URL(string: "https://info.update.sony.net/HP001/MDRID291600/contents/0004/HDX-2916_V0452_with_stack.bin")!
        case .xm3jp411: URL(string: "https://info.update.sony.net/HP001/MDRID291601/contents/0003/HDX-2916_V0411_SPLC.bin")!
        case .xm3jp422: URL(string: "https://info.update.sony.net/HP001/MDRID291601/contents/0004/HDX-2916_V0422_SPLC.bin")!
        case .xm3jp452: URL(string: "https://info.update.sony.net/HP001/MDRID291601/contents/0005/HDX-2916_V0452_SPLC_with_stack.bin")!
        case .xm3cn413: URL(string: "https://info.update.sony.net/HP001/MDRID291602/contents/0001/HDX-2916_V0413_CN.bin")!
        case .xm3cn422: URL(string: "https://info.update.sony.net/HP001/MDRID291602/contents/0002/HDX-2916_V0422_CN.bin")!
        case .xm3cn452: URL(string: "https://info.update.sony.net/HP001/MDRID291602/contents/0003/HDX-2916_V0452_CN_with_stack.bin")!
        }
    }
}

/// A verified stock image, not an arbitrary file with a plausible filename.
/// Checksums identify the pinned bytes; they do not authenticate Sony's signing key.
struct FirmwareImage {
    let bytes: [UInt8]
    let sha256: String
    let syncID: [UInt8]
    let release: FirmwareRelease
    var version: String { release.version }
    var serviceID: String { release.region.serviceID }

    init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, FirmwareRelease.allCases.contains(where: { $0.size == size.fileSize }) else {
            throw FirmwareError.invalid("Expected an original WH-1000XM3 package from the supported international, Japanese or Chinese catalog.")
        }
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        let candidates = FirmwareRelease.allCases.filter { $0.size == data.count }
        guard !candidates.isEmpty else {
            throw FirmwareError.invalid("Incorrect firmware file size.")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let release = candidates.first(where: { $0.sha256 == hash }) else {
            throw FirmwareError.invalid("Firmware checksum mismatch. Only original packages matching the pinned XM3 catalog are supported.")
        }
        self.bytes = Array(data)
        self.sha256 = hash
        self.syncID = Array(Insecure.MD5.hash(data: data).suffix(4))
        self.release = release
    }
}
