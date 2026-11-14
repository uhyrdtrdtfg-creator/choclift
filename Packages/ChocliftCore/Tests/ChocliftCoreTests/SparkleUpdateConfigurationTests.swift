import Foundation
import XCTest
@testable import ChocliftCore

final class SparkleUpdateConfigurationTests: XCTestCase {
    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ChocliftCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ChocliftCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    private func loadPlistDictionary(relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let url = repoRootURL.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = raw as? [String: Any] else {
            XCTFail("Expected dictionary plist at \(relativePath)", file: file, line: line)
            return [:]
        }
        return dict
    }

    func testFeedURLConstantMatchesPublishedAppcastEndpoint() {
        XCTAssertEqual(
            ChocliftDefaults.macSparkleFeedURLString,
            "https://raw.githubusercontent.com/uhyrdtrdtfg-creator/choclift/main/appcast.xml"
        )
        XCTAssertEqual(MacUpdateConfiguration.feedURLString, ChocliftDefaults.macSparkleFeedURLString)
        XCTAssertEqual(MacUpdateConfiguration.feedURL.scheme, "https")
        XCTAssertEqual(MacUpdateConfiguration.feedURL.host, "raw.githubusercontent.com")
        XCTAssertEqual(MacUpdateConfiguration.feedURL.path, "/uhyrdtrdtfg-creator/choclift/main/appcast.xml")
        XCTAssertEqual(MacUpdateConfiguration.scheduledCheckInterval, 86400)
        XCTAssertTrue(MacUpdateConfiguration.enableAutomaticChecks)
        XCTAssertTrue(MacUpdateConfiguration.allowsAutomaticUpdates)
    }

    func testMacInfoPlistMatchesSparkleContractAndExcludesPrivateKeys() throws {
        let macPlist = try loadPlistDictionary(relativePath: "Apps/ChocliftMac/Info.plist")
        let issues = MacUpdateConfiguration.validateMacInfoPlist(macPlist)
        XCTAssertTrue(issues.isEmpty, "Unexpected Mac Info.plist Sparkle issues: \(issues)")

        XCTAssertEqual(macPlist["SUFeedURL"] as? String, ChocliftDefaults.macSparkleFeedURLString)
        XCTAssertEqual(macPlist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(macPlist["SUScheduledCheckInterval"] as? Int, 86400)
        XCTAssertEqual(macPlist["SUAllowsAutomaticUpdates"] as? Bool, true)

        let publicKey = try XCTUnwrap(macPlist["SUPublicEDKey"] as? String)
        let decodedPublicKey = try XCTUnwrap(Data(base64Encoded: publicKey))
        XCTAssertEqual(decodedPublicKey.count, 32, "Ed25519 public key must be 32 raw bytes, never a private key")

        // Ensure existing Bonjour services (pairing + AirPlay discovery) remain intact
        let bonjour = try XCTUnwrap(macPlist["NSBonjourServices"] as? [String])
        XCTAssertEqual(Set(bonjour), Set(["_choclift._tcp", "_raop._tcp", "_airplay._tcp"]))

        // Reject tampered plists in validator
        var tampered = macPlist
        tampered["SPARKLE_PRIVATE_KEY"] = "secret"
        tampered["SURequireSignedFeed"] = true
        let tamperedIssues = MacUpdateConfiguration.validateMacInfoPlist(tampered)
        XCTAssertEqual(tamperedIssues.count, 2)
    }

    func testIOSAndWatchDoNotIncludeSparkleKeysOrDependencies() throws {
        let iosPlist = try loadPlistDictionary(relativePath: "Apps/ChocliftIOS/Info.plist")
        let watchPlist = try loadPlistDictionary(relativePath: "Apps/ChocliftWatch/Info.plist")

        XCTAssertTrue(iosPlist.keys.filter { $0.hasPrefix("SU") }.isEmpty)
        XCTAssertTrue(watchPlist.keys.filter { $0.hasPrefix("SU") }.isEmpty)

        let projectYAML = try String(contentsOf: repoRootURL.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(projectYAML.contains("url: https://github.com/sparkle-project/Sparkle"))
        XCTAssertTrue(projectYAML.contains("exactVersion: 2.10.1"))
        XCTAssertTrue(projectYAML.contains("macOS: \"13.0\""))

        let iosRange = try XCTUnwrap(projectYAML.range(of: "  ChocliftIOS:\n"))
        let schemesRange = try XCTUnwrap(projectYAML.range(of: "\nschemes:\n"))
        let iosAndWatchSlice = String(projectYAML[iosRange.lowerBound..<schemesRange.lowerBound])
        XCTAssertFalse(iosAndWatchSlice.contains("Sparkle"), "iOS and watchOS targets must not link Sparkle")
    }

    func testPublishedRepoAppcastHasSignedHTTPSMacEnclosures() throws {
        let appcastData = try Data(contentsOf: repoRootURL.appendingPathComponent("appcast.xml"))
        let xmlDoc = try XMLDocument(data: appcastData)
        let enclosures = try xmlDoc.nodes(forXPath: "//channel/item/enclosure")
        XCTAssertFalse(enclosures.isEmpty)

        for node in enclosures {
            let elem = try XCTUnwrap(node as? XMLElement)
            let urlString = try XCTUnwrap(elem.attribute(forName: "url")?.stringValue)
            XCTAssertTrue(urlString.hasPrefix("https://github.com/uhyrdtrdtfg-creator/choclift/releases/download/"))
            XCTAssertTrue(urlString.hasSuffix("/Choclift.zip"))

            let sigB64 = try XCTUnwrap(
                elem.attribute(forLocalName: "edSignature", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle")?.stringValue
            )
            let sigData = try XCTUnwrap(Data(base64Encoded: sigB64))
            XCTAssertEqual(sigData.count, 64, "Ed25519 archive signature must be 64 bytes")
        }
    }

    func testLocalizedLabelsAndVersionBadgeFormatting() {
        XCTAssertEqual(MacUpdateConfiguration.checkForUpdatesMenuTitle(in: .english), "Check for Updates…")
        XCTAssertEqual(MacUpdateConfiguration.checkForUpdatesMenuTitle(in: .chinese), "检查更新…")
        XCTAssertEqual(MacUpdateConfiguration.softwareUpdatesSectionTitle(in: .english), "Software Updates")
        XCTAssertEqual(MacUpdateConfiguration.softwareUpdatesSectionTitle(in: .chinese), "软件更新")
        XCTAssertEqual(MacUpdateConfiguration.formattedVersionBadge(shortVersion: "1.0.13", buildVersion: "61"), "v1.0.13 (61)")
        XCTAssertEqual(MacUpdateConfiguration.formattedVersionBadge(shortVersion: "1.0.13", buildVersion: nil), "v1.0.13")
        XCTAssertEqual(MacUpdateConfiguration.formattedVersionBadge(shortVersion: nil, buildVersion: nil), "v1.0")
    }
}
