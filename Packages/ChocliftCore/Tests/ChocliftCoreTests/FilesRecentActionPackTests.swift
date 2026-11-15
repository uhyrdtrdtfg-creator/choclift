import Foundation
import XCTest
@testable import ChocliftCore

final class FilesRecentActionPackTests: XCTestCase {
    func testCatalogContainsBothRecentFileActionsWithDistinctTitlesAndSymbols() throws {
        let pack = CompanionActionCatalog.filesRecentPack
        XCTAssertEqual(pack.map(\.id), ["files.open_recent", "files.open_latest_download"])

        let openRecent = try XCTUnwrap(CompanionActionCatalog.action(id: "files.open_recent"))
        let openLatestDownload = try XCTUnwrap(CompanionActionCatalog.action(id: "files.open_latest_download"))

        XCTAssertTrue(CompanionActionCatalog.isKnown("files.open_recent"))
        XCTAssertTrue(CompanionActionCatalog.isKnown("files.open_latest_download"))

        XCTAssertEqual(openRecent.titleZh, "打开最近使用")
        XCTAssertEqual(openRecent.titleEn, "Open Recent Items")
        XCTAssertEqual(openRecent.sfSymbol, "clock.arrow.circlepath")

        XCTAssertNotEqual(openRecent.titleZh, openLatestDownload.titleZh)
        XCTAssertNotEqual(openRecent.titleEn, openLatestDownload.titleEn)
        XCTAssertNotEqual(openRecent.title(in: .chinese), openRecent.title(in: .english))
        XCTAssertNotEqual(openLatestDownload.title(in: .chinese), openLatestDownload.title(in: .english))

        XCTAssertFalse(openRecent.sfSymbol.isEmpty)
        XCTAssertFalse(openLatestDownload.sfSymbol.isEmpty)
    }

    func testNewestFileReturnsNilForEmptyOrIneligibleLists() {
        XCTAssertNil(FilesRecentSelection.newestFile(in: []))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ineligible: [FilesRecentSelection.Candidate] = [
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/.DS_Store"),
                modificationDate: now.addingTimeInterval(30),
                isRegularFile: true,
                isPackage: false,
                isHidden: false
            ),
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/HiddenReport.pdf"),
                modificationDate: now.addingTimeInterval(40),
                isRegularFile: true,
                isPackage: false,
                isHidden: true
            ),
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/Installer.app"),
                modificationDate: now.addingTimeInterval(50),
                isRegularFile: true,
                isPackage: true,
                isHidden: false
            ),
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/Subfolder"),
                modificationDate: now.addingTimeInterval(60),
                isRegularFile: false,
                isPackage: false,
                isHidden: false
            )
        ]

        XCTAssertNil(FilesRecentSelection.newestFile(in: ineligible))
    }

    func testNewestFilePicksNewestNonHiddenRegularNonPackageFile() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let olderURL = URL(fileURLWithPath: "/tmp/Downloads/older.pdf")
        let newestRegularURL = URL(fileURLWithPath: "/tmp/Downloads/newest.pdf")

        let candidates: [FilesRecentSelection.Candidate] = [
            FilesRecentSelection.Candidate(
                url: olderURL,
                modificationDate: base.addingTimeInterval(10)
            ),
            FilesRecentSelection.Candidate(
                url: newestRegularURL,
                modificationDate: base.addingTimeInterval(20)
            ),
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/.newer_hidden.pdf"),
                modificationDate: base.addingTimeInterval(100)
            ),
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/FlaggedHidden.pdf"),
                modificationDate: base.addingTimeInterval(110),
                isHidden: true
            ),
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/Bundle.rtfd"),
                modificationDate: base.addingTimeInterval(120),
                isPackage: true
            ),
            FilesRecentSelection.Candidate(
                url: URL(fileURLWithPath: "/tmp/Downloads/ArchiveFolder"),
                modificationDate: base.addingTimeInterval(130),
                isRegularFile: false
            )
        ]

        XCTAssertEqual(FilesRecentSelection.newestFile(in: candidates), newestRegularURL)
    }

    func testRecentFolderFallbackAndDownloadsDirectoryResolution() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let recentDir = tempHome.appendingPathComponent("Library/Recent", isDirectory: true)
        let fallbackTarget = FilesRecentSelection.resolveRecentFolderTarget(
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(fallbackTarget.url, tempHome)
        XCTAssertTrue(fallbackTarget.usedHomeFallback)
        XCTAssertFalse(fm.fileExists(atPath: recentDir.path))

        try fm.createDirectory(at: recentDir, withIntermediateDirectories: true)
        let existingTarget = FilesRecentSelection.resolveRecentFolderTarget(
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(existingTarget.url, recentDir)
        XCTAssertFalse(existingTarget.usedHomeFallback)

        let downloadsDir = tempHome.appendingPathComponent("Downloads", isDirectory: true)
        XCTAssertEqual(
            FilesRecentSelection.resolveLatestDownload(inDownloadsDirectory: downloadsDir, fileManager: fm),
            .failure(.downloadsMissing)
        )
        XCTAssertFalse(fm.fileExists(atPath: downloadsDir.path))

        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        XCTAssertEqual(
            FilesRecentSelection.resolveLatestDownload(inDownloadsDirectory: downloadsDir, fileManager: fm),
            .failure(.downloadsEmpty)
        )

        let dotFile = downloadsDir.appendingPathComponent(".DS_Store")
        try Data("hidden".utf8).write(to: dotFile)
        let appBundle = downloadsDir.appendingPathComponent("Sample.app", isDirectory: true)
        try fm.createDirectory(at: appBundle, withIntermediateDirectories: true)
        XCTAssertEqual(
            FilesRecentSelection.resolveLatestDownload(inDownloadsDirectory: downloadsDir, fileManager: fm),
            .failure(.downloadsEmpty)
        )

        let olderFile = downloadsDir.appendingPathComponent("first.txt")
        let newerFile = downloadsDir.appendingPathComponent("second.txt")
        try Data("1".utf8).write(to: olderFile)
        try Data("2".utf8).write(to: newerFile)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)],
            ofItemAtPath: olderFile.path
        )
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)],
            ofItemAtPath: newerFile.path
        )

        XCTAssertEqual(
            FilesRecentSelection.resolveLatestDownload(inDownloadsDirectory: downloadsDir, fileManager: fm),
            .success(newerFile.standardizedFileURL)
        )
        XCTAssertTrue(fm.fileExists(atPath: olderFile.path))
        XCTAssertTrue(fm.fileExists(atPath: newerFile.path))
    }
}
