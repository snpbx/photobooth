import Foundation
import CryptoKit
import CommonCrypto

/// Locks an album's contents behind the password the operator hands out.
///
/// The important part is *what* is protected. The page never contains the photo
/// addresses at all — the whole list is encrypted, and the password is what
/// turns it back into addresses. So a page found without its password is not a
/// gallery with a locked door; it is a page that does not know where any
/// photographs are. Nothing is checked in JavaScript that could simply be
/// skipped, because there is nothing to check: the wrong password produces
/// gibberish that fails the cipher's own authentication tag.
///
/// PBKDF2-SHA256 at 250,000 rounds, then AES-256-GCM — chosen because
/// WebCrypto in every current browser can do exactly this and nothing has to be
/// shipped to the guest's phone to make it work.
enum AlbumCrypto {

    struct Sealed {
        let salt: String        // base64
        let nonce: String       // base64
        let payload: String     // base64, ciphertext + tag
        let rounds: Int
    }

    static let rounds = 250_000

    static func seal(_ plaintext: Data, password: String) throws -> Sealed {
        var salt = Data(count: 16)
        try salt.withUnsafeMutableBytes { raw in
            guard SecRandomCopyBytes(kSecRandomDefault, 16, raw.baseAddress!) == errSecSuccess else {
                throw AlbumCryptoError.randomFailed
            }
        }
        let key = try derive(password: password, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let nonce = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data?,
              !nonce.isEmpty else { throw AlbumCryptoError.sealFailed }
        return Sealed(salt: salt.base64EncodedString(),
                      nonce: nonce.base64EncodedString(),
                      payload: (sealed.ciphertext + sealed.tag).base64EncodedString(),
                      rounds: rounds)
    }

    private static func derive(password: String, salt: Data) throws -> SymmetricKey {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        let status: Int32 = out.withUnsafeMutableBytes { outRaw in
            salt.withUnsafeBytes { saltRaw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw, pw.count,
                                     saltRaw.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(rounds),
                                     outRaw.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
            }
        }
        guard status == kCCSuccess else { throw AlbumCryptoError.deriveFailed }
        return SymmetricKey(data: out)
    }

    /// A password an operator can read down a phone line: four short words and a
    /// number. Long enough to be worth having, short enough to be dictated.
    static func suggestPassword() -> String {
        let words = ["amber", "basil", "cedar", "coral", "delta", "ember", "fable", "grove",
                     "harbor", "ivory", "jasper", "kite", "linen", "marble", "nectar", "opal",
                     "pebble", "quartz", "rowan", "sable", "tulip", "umber", "violet", "willow"]
        let picked = (0..<3).map { _ in words.randomElement()! }
        return (picked + [String(Int.random(in: 10...99))]).joined(separator: "-")
    }
}

enum AlbumCryptoError: LocalizedError {
    case randomFailed, deriveFailed, sealFailed

    var errorDescription: String? {
        switch self {
        case .randomFailed:  return "The Mac would not provide random bytes for the album key."
        case .deriveFailed:  return "Could not turn that password into a key."
        case .sealFailed:    return "Could not lock the album."
        }
    }
}
