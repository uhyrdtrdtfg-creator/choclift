import CryptoKit
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

    func testPublishedRepoAppcastTopItemIsV1_0_21WithMatchingEnclosureMetadata() throws {
        let appcastData = try Data(contentsOf: repoRootURL.appendingPathComponent("appcast.xml"))
        let xmlDoc = try XMLDocument(data: appcastData)
        let items = try xmlDoc.nodes(forXPath: "//channel/item")
        let topItem = try XCTUnwrap(items.first as? XMLElement)

        let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        let shortVersion = topItem.elements(forLocalName: "shortVersionString", uri: sparkleNS).first?.stringValue
        let buildVersion = topItem.elements(forLocalName: "version", uri: sparkleNS).first?.stringValue
        XCTAssertEqual(shortVersion, "1.0.21")
        XCTAssertEqual(buildVersion, "91")

        let enclosure = try XCTUnwrap(topItem.elements(forName: "enclosure").first)
        XCTAssertEqual(
            enclosure.attribute(forName: "url")?.stringValue,
            "https://github.com/uhyrdtrdtfg-creator/choclift/releases/download/v1.0.21/Choclift.zip"
        )
        XCTAssertEqual(enclosure.attribute(forName: "length")?.stringValue, "5942387")
        XCTAssertEqual(enclosure.attribute(forLocalName: "os", uri: sparkleNS)?.stringValue, "macos")

        let edSig = try XCTUnwrap(enclosure.attribute(forLocalName: "edSignature", uri: sparkleNS)?.stringValue)
        let snapshot = SparkleAppcastItemSnapshot(
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            hasEnclosureURL: true,
            isInformationOnly: false,
            edSignatureBase64: edSig
        )
        XCTAssertNil(MacUpdateConfiguration.validateEnclosureSignature(of: snapshot))
    }

    func testClassifyFoundUpdateSurfacesVersionAndRejectsUnsignedOrMalformedEnclosures() {
        let validSig = Data(repeating: 0xAB, count: 64).base64EncodedString()
        let validItem = SparkleAppcastItemSnapshot(
            shortVersion: "1.0.22",
            buildVersion: "92",
            edSignatureBase64: validSig
        )

        let found = MacUpdateConfiguration.classifyFoundUpdate(validItem)
        XCTAssertEqual(found, .updateFound(shortVersion: "1.0.22", buildVersion: "92"))
        XCTAssertFalse(found.isUpToDate)
        XCTAssertFalse(found.isFailure)
        XCTAssertEqual(found.title(in: .english), "Update Available: v1.0.22 (92)")
        XCTAssertEqual(found.title(in: .chinese), "发现新版本 v1.0.22 (92)")

        let missingSigItem = SparkleAppcastItemSnapshot(
            shortVersion: "1.0.22",
            buildVersion: "92",
            edSignatureBase64: nil
        )
        let missingSigResult = MacUpdateConfiguration.classifyFoundUpdate(missingSigItem)
        if case .signatureMismatch = missingSigResult {
            // expected
        } else {
            XCTFail("Expected signatureMismatch for unsigned enclosure, got \(missingSigResult)")
        }
        XCTAssertFalse(missingSigResult.isUpToDate)
        XCTAssertTrue(missingSigResult.isFailure)

        let shortSigItem = SparkleAppcastItemSnapshot(
            shortVersion: "1.0.22",
            buildVersion: "92",
            edSignatureBase64: Data(repeating: 0xCD, count: 32).base64EncodedString()
        )
        if case .signatureMismatch = MacUpdateConfiguration.classifyFoundUpdate(shortSigItem) {
            // expected
        } else {
            XCTFail("Expected signatureMismatch for non-64-byte Ed25519 signature")
        }

        let failedSignedFeedItem = SparkleAppcastItemSnapshot(
            shortVersion: "1.0.22",
            buildVersion: "92",
            edSignatureBase64: validSig,
            feedSigningValidationFailed: true
        )
        if case .signatureMismatch = MacUpdateConfiguration.classifyFoundUpdate(failedSignedFeedItem) {
            // expected
        } else {
            XCTFail("Expected signatureMismatch when signed feed validation failed")
        }
    }

    func testClassifyNoUpdateConfirmsAlreadyCurrentOnlyWithVerifiedAppcastItem() {
        let validSig = Data(repeating: 0x42, count: 64).base64EncodedString()
        let latestItem = SparkleAppcastItemSnapshot(
            shortVersion: "1.0.21",
            buildVersion: "91",
            edSignatureBase64: validSig
        )

        let onLatestError = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.noUpdate,
            userInfo: [
                MacUpdateConfiguration.noUpdateFoundReasonKey: SparkleNoUpdateReason.onLatestVersion.rawValue
            ]
        )
        let current = MacUpdateConfiguration.classifyNoUpdate(
            error: onLatestError,
            latestItem: latestItem,
            fallbackHostShortVersion: "1.0.21",
            fallbackHostBuildVersion: "91"
        )
        XCTAssertEqual(current, .alreadyCurrent(shortVersion: "1.0.21", buildVersion: "91"))
        XCTAssertTrue(current.isUpToDate)
        XCTAssertFalse(current.isFailure)
        XCTAssertEqual(current.title(in: .english), "Up to Date (v1.0.21 (91))")
        XCTAssertEqual(current.title(in: .chinese), "已是最新版本（v1.0.21 (91)）")

        let newerHostError = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.noUpdate,
            userInfo: [
                MacUpdateConfiguration.noUpdateFoundReasonKey: SparkleNoUpdateReason.onNewerThanLatestVersion.rawValue
            ]
        )
        let newerResult = MacUpdateConfiguration.classifyNoUpdate(
            error: newerHostError,
            latestItem: latestItem,
            fallbackHostShortVersion: "1.0.22",
            fallbackHostBuildVersion: "92"
        )
        XCTAssertEqual(newerResult, .alreadyCurrent(shortVersion: "1.0.22", buildVersion: "92"))
        XCTAssertTrue(newerResult.isUpToDate)
    }

    func testEmptyFeedAndIncompatibleNoUpdateNeverClaimAppIsUpToDate() {
        // Sparkle emits SUNoUpdateError with localizedDescription "You’re up to date!" and nil latestItem
        // when an HTTP 200 XML payload contains zero <item> elements.
        let emptyFeedError = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.noUpdate,
            userInfo: [
                NSLocalizedDescriptionKey: "You’re up to date!",
                MacUpdateConfiguration.noUpdateFoundReasonKey: SparkleNoUpdateReason.onLatestVersion.rawValue
            ]
        )
        let emptyResult = MacUpdateConfiguration.classifyError(emptyFeedError, latestItem: nil)
        XCTAssertEqual(emptyResult, .feedUnreachable(detail: nil))
        XCTAssertFalse(emptyResult.isUpToDate)
        XCTAssertTrue(emptyResult.isFailure)
        XCTAssertFalse(emptyResult.title(in: .english).localizedCaseInsensitiveContains("up to date"))
        XCTAssertFalse((emptyResult.detailText(in: .english) ?? "").localizedCaseInsensitiveContains("up to date"))
        XCTAssertFalse(emptyResult.title(in: .chinese).contains("已是最新"))
        XCTAssertFalse((emptyResult.detailText(in: .chinese) ?? "").contains("已是最新"))

        let validSig = Data(repeating: 0x11, count: 64).base64EncodedString()
        let futureItem = SparkleAppcastItemSnapshot(
            shortVersion: "2.0.0",
            buildVersion: "200",
            edSignatureBase64: validSig
        )
        let osTooOldError = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.noUpdate,
            userInfo: [
                NSLocalizedDescriptionKey: "This Mac cannot update to v2.0.0 because macOS 15.0 or newer is required.",
                MacUpdateConfiguration.noUpdateFoundReasonKey: SparkleNoUpdateReason.systemIsTooOld.rawValue
            ]
        )
        let osTooOldResult = MacUpdateConfiguration.classifyNoUpdate(error: osTooOldError, latestItem: futureItem)
        XCTAssertEqual(
            osTooOldResult,
            .checkFailed(detail: "This Mac cannot update to v2.0.0 because macOS 15.0 or newer is required.")
        )
        XCTAssertFalse(osTooOldResult.isUpToDate)
        XCTAssertTrue(osTooOldResult.isFailure)
    }

    func testFeedUnreachableClassificationCoversNetworkHTTPAndParseFailures() {
        let offlineError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        let wrappedDownloadError = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.download,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred in retrieving update information. Please try again later.",
                NSUnderlyingErrorKey: offlineError
            ]
        )

        let offlineResult = MacUpdateConfiguration.classifyError(wrappedDownloadError)
        XCTAssertEqual(offlineResult, .feedUnreachable(detail: "The Internet connection appears to be offline."))
        XCTAssertFalse(offlineResult.isUpToDate)
        XCTAssertTrue(offlineResult.isFailure)
        XCTAssertEqual(offlineResult.title(in: .english), "Update Feed Unreachable")
        XCTAssertEqual(offlineResult.title(in: .chinese), "无法连接更新源")

        // TLS certificate failure on HTTPS endpoint must classify as feedUnreachable rather than signatureMismatch.
        let tlsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorServerCertificateUntrusted,
            userInfo: [NSLocalizedDescriptionKey: "The certificate for this server is invalid."]
        )
        XCTAssertEqual(
            MacUpdateConfiguration.classifyError(tlsError),
            .feedUnreachable(detail: "The certificate for this server is invalid.")
        )

        let http404Inner = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.download,
            userInfo: [NSLocalizedDescriptionKey: "The update feed could not be downloaded (HTTP status 404)."]
        )
        let http404Outer = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.appcast,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred in retrieving update information. Please try again later.",
                NSUnderlyingErrorKey: http404Inner
            ]
        )
        XCTAssertEqual(
            MacUpdateConfiguration.classifyError(http404Outer),
            .feedUnreachable(detail: "The update feed could not be downloaded (HTTP status 404).")
        )

        let xmlParseError = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.appcastParse,
            userInfo: [NSLocalizedDescriptionKey: "Line 1: Malformed XML document."]
        )
        XCTAssertEqual(
            MacUpdateConfiguration.classifyError(xmlParseError),
            .feedUnreachable(detail: "Line 1: Malformed XML document.")
        )
    }

    func testSignatureMismatchClassificationAndEd25519ArchiveVerification() throws {
        // Matches Sparkle SPUInstallerDriver wrapping SUValidationError (3002) inside SUInstallationError (4005).
        let eddsaMismatchInner = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.validation,
            userInfo: [
                NSLocalizedDescriptionKey: "EdDSA signature does not match. Data of the update file could be corrupted or modified."
            ]
        )
        let installerOuter = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.installation,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while installing the update. Please try again later.",
                NSLocalizedRecoverySuggestionErrorKey: "The update is improperly signed and could not be validated.",
                NSUnderlyingErrorKey: eddsaMismatchInner
            ]
        )

        let mismatchResult = MacUpdateConfiguration.classifyError(installerOuter)
        XCTAssertEqual(
            mismatchResult,
            .signatureMismatch(
                detail: "EdDSA signature does not match. Data of the update file could be corrupted or modified."
            )
        )
        XCTAssertFalse(mismatchResult.isUpToDate)
        XCTAssertTrue(mismatchResult.isFailure)
        XCTAssertEqual(mismatchResult.title(in: .english), "Update Signature Mismatch")
        XCTAssertEqual(mismatchResult.title(in: .chinese), "更新签名校验失败")

        // Signed-feed validation failure wraps SUValidationError inside SUAppcastParseError (1000).
        let signedFeedOuter = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.appcastParse,
            userInfo: [
                NSLocalizedDescriptionKey: "An error occurred while parsing the update feed.",
                NSUnderlyingErrorKey: eddsaMismatchInner
            ]
        )
        if case .signatureMismatch = MacUpdateConfiguration.classifyError(signedFeedOuter) {
            // expected: signatureMismatch takes precedence over appcastParse
        } else {
            XCTFail("Expected signatureMismatch when appcastParse wraps SUValidationError")
        }

        // Ephemeral Ed25519 keypair verification test (no stored private keys).
        let ephemeralKey = Curve25519.Signing.PrivateKey()
        let ephemeralPubB64 = ephemeralKey.publicKey.rawRepresentation.base64EncodedString()
        let archiveBytes = Data("Choclift-test-archive-payload".utf8)
        let signatureB64 = try ephemeralKey.signature(for: archiveBytes).base64EncodedString()

        XCTAssertNil(
            MacUpdateConfiguration.verifyArchiveSignature(
                archiveData: archiveBytes,
                signatureBase64: signatureB64,
                publicKeyBase64: ephemeralPubB64
            )
        )

        // Mismatched public key (e.g. verifying ephemeral-signed archive against production SUPublicEDKey) must fail.
        let wrongKeyOutcome = MacUpdateConfiguration.verifyArchiveSignature(
            archiveData: archiveBytes,
            signatureBase64: signatureB64,
            publicKeyBase64: MacUpdateConfiguration.publicEDKey
        )
        if case .signatureMismatch = wrongKeyOutcome {
            // expected
        } else {
            XCTFail("Expected signatureMismatch against mismatched public key, got \(String(describing: wrongKeyOutcome))")
        }

        // Tampered archive byte must fail.
        var tamperedArchive = archiveBytes
        tamperedArchive[0] ^= 0xFF
        XCTAssertNotNil(
            MacUpdateConfiguration.verifyArchiveSignature(
                archiveData: tamperedArchive,
                signatureBase64: signatureB64,
                publicKeyBase64: ephemeralPubB64
            )
        )
    }

    func testStateMachineLifecyclePreservesRealResultsAcrossDismissFailureAndCancellation() {
        var machine = MacUpdateCheckStateMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.state.menuStatusLine(in: .english))

        machine.beginCheck()
        XCTAssertEqual(machine.state, .checking)
        XCTAssertEqual(machine.state.menuStatusLine(in: .english), "Checking for updates…")

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let validSig = Data(repeating: 0x77, count: 64).base64EncodedString()
        let item = SparkleAppcastItemSnapshot(
            shortVersion: "1.0.22",
            buildVersion: "92",
            edSignatureBase64: validSig
        )
        machine.recordFoundUpdate(item, now: t1)
        XCTAssertEqual(
            machine.state,
            .completed(result: .updateFound(shortVersion: "1.0.22", buildVersion: "92"), checkedAt: t1)
        )

        // Dismissing the update prompt ends the cycle without error; updateFound must remain visible.
        machine.finishCycle(error: nil, now: t1.addingTimeInterval(5))
        XCTAssertEqual(
            machine.state,
            .completed(result: .updateFound(shortVersion: "1.0.22", buildVersion: "92"), checkedAt: t1)
        )

        // Starting another check and cancelling mid-flight restores the prior settled result rather than claiming up to date.
        machine.beginCheck()
        let userCancel = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        machine.recordError(userCancel, now: t1.addingTimeInterval(10))
        XCTAssertEqual(
            machine.state,
            .completed(result: .updateFound(shortVersion: "1.0.22", buildVersion: "92"), checkedAt: t1)
        )

        // If installation fails signature validation after finding an update, signatureMismatch replaces updateFound.
        let sigErr = NSError(
            domain: MacUpdateConfiguration.sparkleErrorDomain,
            code: MacUpdateConfiguration.SparkleErrorCode.signature,
            userInfo: [NSLocalizedDescriptionKey: "Bad Ed25519 signature."]
        )
        let t2 = t1.addingTimeInterval(20)
        machine.recordError(sigErr, now: t2)
        XCTAssertEqual(
            machine.state,
            .completed(result: .signatureMismatch(detail: "Bad Ed25519 signature."), checkedAt: t2)
        )
        XCTAssertEqual(machine.state.result?.isUpToDate, false)
    }
}
