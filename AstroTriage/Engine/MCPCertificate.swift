// Self-signed TLS certificate for the in-app MCP HTTPS server.
//
// Why HTTPS at all: Claude Desktop's MCP client refuses plain `http://`
// URLs as a security policy (even on localhost). To serve our MCP tools
// to Claude Desktop without requiring a third-party stdio↔HTTP proxy,
// the in-app server must speak TLS.
//
// Why self-signed: we're binding to 127.0.0.1, so no public CA exists for
// the hostname. The user trusts the cert once via Keychain Access /
// SecTrustSettings (handled by MCPConnectorWindow); afterwards Claude
// Desktop and any other macOS app validates our cert normally.
//
// Lifecycle:
//   1. First app launch: generateAndStore() creates a P-256 key + cert,
//      writes PEM files to ~/Library/Containers/<id>/.../Application
//      Support/AstroBlinkV2/mcp-tls/{cert.pem,key.pem}.
//   2. MCPHTTPServer.start() reads those files at boot and uses them in
//      the NIOSSL TLS context.
//   3. User clicks "Install Certificate" in MCP Connector window →
//      SecTrustSettingsSetTrustSettings marks it trusted for SSL.
//   4. Cert lives 10 years; if the file gets deleted, a fresh cert is
//      generated on next launch (user re-runs Install).
import Foundation
import Crypto
import X509
import SwiftASN1

enum MCPCertificate {

    struct Material {
        let certPEM: String
        let keyPEM: String
        let certDER: Data
    }

    private static let directoryName = "mcp-tls"
    private static let certFilename = "cert.pem"
    private static let keyFilename = "key.pem"
    private static let commonName = "AstroBlinkV2 MCP"

    /// Load existing cert+key from disk, or generate a fresh pair if none exist.
    static func loadOrGenerate() throws -> Material {
        let dir = try storageDirectory()
        let certURL = dir.appendingPathComponent(certFilename)
        let keyURL = dir.appendingPathComponent(keyFilename)

        if let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
           let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8) {
            let certDER = try Self.derFromPEM(certPEM)
            return Material(certPEM: certPEM, keyPEM: keyPEM, certDER: certDER)
        }
        return try generateAndStore(at: dir)
    }

    private static func storageDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = appSupport
            .appendingPathComponent("AstroBlinkV2", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func generateAndStore(at dir: URL) throws -> Material {
        // P-256 EC key — small (~91 byte private key), fast, widely supported.
        let privateKey = P256.Signing.PrivateKey()
        let certPrivateKey = Certificate.PrivateKey(privateKey)
        let publicKey = Certificate.PublicKey(privateKey.publicKey)

        let now = Date()
        let notAfter = now.addingTimeInterval(60 * 60 * 24 * 365 * 10) // 10 years

        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("joergsflow")
        }

        // SubjectAltName must include both DNS name "localhost" and the IP
        // 127.0.0.1 — Claude Desktop / URLSession validates the hostname
        // it actually connected to, and we support both forms.
        let san = try SubjectAlternativeNames([
            .dnsName("localhost"),
            .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1]))
        ])

        let extensions = try Certificate.Extensions {
            try Critical(BasicConstraints.notCertificateAuthority)
            try KeyUsage(digitalSignature: true, keyEncipherment: true)
            try ExtendedKeyUsage([.serverAuth])
            try san
        }

        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now,
            notValidAfter: notAfter,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: certPrivateKey
        )

        // Serialize cert to PEM.
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let certDER = Data(serializer.serializedBytes)
        let certPEM = Self.pemString(label: "CERTIFICATE", der: certDER)

        // Private key as PEM (PKCS#8) via Crypto's built-in encoding.
        let keyPEM = privateKey.pemRepresentation

        let certURL = dir.appendingPathComponent(certFilename)
        let keyURL = dir.appendingPathComponent(keyFilename)
        try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
        try keyPEM.write(to: keyURL, atomically: true, encoding: .utf8)

        // Tighten permissions on the private key — anyone on this Mac who
        // can read it can impersonate the MCP server.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        return Material(certPEM: certPEM, keyPEM: keyPEM, certDER: certDER)
    }

    // MARK: - PEM helpers

    private static func pemString(label: String, der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters,
                                                    .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }

    private static func derFromPEM(_ pem: String) throws -> Data {
        let stripped = pem
            .split(whereSeparator: { $0.isNewline })
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: stripped) else {
            throw NSError(domain: "MCPCertificate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PEM body is not valid base64"])
        }
        return data
    }
}
