import CryptoKit
import Foundation

// Verify Sparkle's Ed25519 archive signature using the public key embedded in
// the app, independently of the private key used by sign_update.
func validSignature(archive: Data, signature: Data, publicKey: Data) throws -> Bool {
    try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        .isValidSignature(signature, for: archive)
}

do {
    if CommandLine.arguments.dropFirst() == ["--self-test"] {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("personal update fixture".utf8)
        let signature = try key.signature(for: archive)
        guard try validSignature(archive: archive, signature: signature, publicKey: key.publicKey.rawRepresentation),
              try !validSignature(archive: Data("modified".utf8), signature: signature, publicKey: key.publicKey.rawRepresentation),
              try !validSignature(archive: archive, signature: signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) else {
            throw NSError(domain: "SignatureTests", code: 1)
        }
        print("Signature verification tests passed")
    } else {
        guard CommandLine.arguments.count == 4 else {
            throw NSError(domain: "Usage: verify_personal_update.swift archive signature-file public-key", code: 1)
        }
        let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
        let text = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"sparkle:edSignature="([A-Za-z0-9+/=]+)""#)
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let signature = Data(base64Encoded: String(text[range])),
              let publicKey = Data(base64Encoded: CommandLine.arguments[3]),
              try validSignature(archive: archive, signature: signature, publicKey: publicKey) else {
            throw NSError(domain: "Update signature does not match the app's public key", code: 1)
        }
        print("Archive signature verified against the app's public key")
    }
} catch {
    fputs("Signature verification failed: \(error)\n", stderr)
    exit(1)
}
