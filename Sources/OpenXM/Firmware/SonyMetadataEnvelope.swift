import Foundation
import CryptoKit
import CommonCrypto

/// Shared envelope decoding only. Each caller separately enforces its own device/service and XML rules.
enum SonyMetadataEnvelope {
    /// Sony's public ENC0003 envelope: AES-128 ECB, no padding; HAS0003 hashes the plaintext SHA-1 hex,
    /// service ID and category. This checks metadata consistency, not a cryptographic publisher signature.
    /// Wire facts: lzghzr/MDR_Proxy, mdr.ts at 2e80d32e05f55ebf354389283e767e5a7c273e27.
    static func decode(_ data: Data, category: String, service: String) throws -> Data {
        guard data.count <= 1_048_576, let delimiter = data.range(of: Data([10, 10])), delimiter.lowerBound < 256,
              let header = String(data: data[..<delimiter.lowerBound], encoding: .utf8) else {
            throw FirmwareError.invalid("Unrecognized Sony metadata envelope.")
        }
        let lines = header.split(separator: "\n").map(String.init)
        guard lines.count == 3, lines[0] == "eaid:ENC0003", lines[1] == "daid:HAS0003",
              lines[2].hasPrefix("digest:"), lines[2].count == 47 else {
            throw FirmwareError.invalid("Sony changed the metadata format. No installation was enabled.")
        }
        let ciphertext = Data(data[delimiter.upperBound...])
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw FirmwareError.invalid("Truncated Sony metadata.")
        }
        let key: [UInt8] = [0x4f, 0xa2, 0x79, 0x99, 0xff, 0xd0, 0x8b, 0x1f, 0xe4, 0xd2, 0x60, 0xd5, 0x7b, 0x6d, 0x3c, 0x17]
        var output = Data(count: ciphertext.count)
        var count = 0
        let status = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil, input.baseAddress, ciphertext.count,
                            out.baseAddress, out.count, &count)
                }
            }
        }
        guard status == kCCSuccess, count == ciphertext.count else { throw FirmwareError.invalid("Sony metadata could not be decoded.") }
        func sha1(_ bytes: Data) -> String { Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        let digest = sha1(Data((sha1(output) + service + category).utf8))
        guard digest == String(lines[2].dropFirst(7)) else { throw FirmwareError.invalid("Sony metadata digest did not match the requested service.") }
        return output
    }

}
