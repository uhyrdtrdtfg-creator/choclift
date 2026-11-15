import Foundation
import XCTest
@testable import ChocliftCore

final class FilesActionPackTests: XCTestCase {
    func testFilesPackHasExactlyTenUniqueExpectedIDs() {
        let expectedIDs = [
            "files.open_home",
            "files.open_desktop",
            "files.open_documents",
            "files.open_downloads",
            "files.open_applications",
            "files.open_screenshots",
            "files.open_icloud",
            "files.new_finder_window",
            "files.reveal_frontmost_app",
            "files.open_trash"
        ]

        let pack = CompanionActionCatalog.filesPack
        let actualIDs = pack.map(\.id)

        XCTAssertEqual(pack.count, 10)
        XCTAssertEqual(Set(actualIDs).count, 10)
        XCTAssertEqual(actualIDs, expectedIDs)

        for action in pack {
            XCTAssertTrue(action.id.hasPrefix("files."))
            XCTAssertFalse(action.title(in: .english).isEmpty)
            XCTAssertFalse(action.title(in: .chinese).isEmpty)
            XCTAssertFalse(action.sfSymbol.isEmpty)
            XCTAssertTrue(CompanionActionCatalog.isKnown(action.id))
            XCTAssertEqual(CompanionActionCatalog.action(id: action.id), action)
        }
    }

    func testScreenshotFolderResolutionPrefersExistingLocationFallsBackToDesktopAndFailsWithoutDesktop() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let customCaptures = tempHome.appendingPathComponent("Captures", isDirectory: true)
        try fm.createDirectory(at: customCaptures, withIntermediateDirectories: true)

        // 1. A set location that exists wins even before Desktop exists.
        let winWithoutDesktop = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: customCaptures.path,
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(winWithoutDesktop, .success(customCaptures.standardizedFileURL))

        let desktopDir = tempHome.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)

        let winWithDesktop = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: customCaptures.path,
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(winWithDesktop, .success(customCaptures.standardizedFileURL))

        let winTilde = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: "~/Captures",
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(winTilde, .success(customCaptures.standardizedFileURL))

        // 2. A missing location (or regular file / nil) falls back to Desktop.
        let missingCaptures = tempHome.appendingPathComponent("MissingCaptures", isDirectory: true)
        let fallbackMissing = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: missingCaptures.path,
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(fallbackMissing, .success(desktopDir.standardizedFileURL))

        let regularFile = tempHome.appendingPathComponent("not_a_dir.txt", isDirectory: false)
        try Data("x".utf8).write(to: regularFile)
        let fallbackRegularFile = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: regularFile.path,
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(fallbackRegularFile, .success(desktopDir.standardizedFileURL))

        let fallbackUnset = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: nil,
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(fallbackUnset, .success(desktopDir.standardizedFileURL))

        // 3. A missing Desktop fails clearly.
        try fm.removeItem(at: desktopDir)

        let failWhenUnset = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: nil,
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(failWhenUnset, .failure(.screenshotsAndDesktopMissing))

        let failWhenConfiguredMissing = FilesActionResolver.resolveScreenshotsFolder(
            configuredLocation: missingCaptures.path,
            homeDirectoryURL: tempHome,
            fileManager: fm
        )
        XCTAssertEqual(failWhenConfiguredMissing, .failure(.screenshotsAndDesktopMissing))
        XCTAssertFalse(FilesActionFailure.screenshotsAndDesktopMissing.message(in: .english).isEmpty)
        XCTAssertFalse(FilesActionFailure.screenshotsAndDesktopMissing.message(in: .chinese).isEmpty)
    }

    func testRevealFrontmostAppRefusesChocliftAndNilBundleURLs() {
        let fm = FileManager.default
        let sampleAppURL = fm.temporaryDirectory.appendingPathComponent("Sample.app", isDirectory: true)

        XCTAssertEqual(
            FilesActionResolver.resolveFrontmostAppRevealURL(
                bundleIdentifier: "com.choclift.mac",
                bundleURL: sampleAppURL
            ),
            .failure(.frontmostAppIsChoclift)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFrontmostAppRevealURL(
                bundleIdentifier: "  COM.CHOCLIFT.MAC  ",
                bundleURL: sampleAppURL
            ),
            .failure(.frontmostAppIsChoclift)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFrontmostAppRevealURL(
                bundleIdentifier: "com.apple.Safari",
                bundleURL: sampleAppURL,
                isCurrentProcess: true
            ),
            .failure(.frontmostAppIsChoclift)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFrontmostAppRevealURL(
                bundleIdentifier: "com.apple.Safari",
                bundleURL: nil
            ),
            .failure(.frontmostAppMissingBundleURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFrontmostAppRevealURL(
                bundleIdentifier: nil,
                bundleURL: nil
            ),
            .failure(.frontmostAppMissingBundleURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFrontmostAppRevealURL(
                bundleIdentifier: "com.apple.Safari",
                bundleURL: URL(string: "https://example.com")
            ),
            .failure(.frontmostAppMissingBundleURL)
        )

        XCTAssertEqual(
            FilesActionResolver.resolveFrontmostAppRevealURL(
                bundleIdentifier: "com.apple.Safari",
                bundleURL: sampleAppURL
            ),
            .success(sampleAppURL.standardizedFileURL)
        )
    }

    func testFolderResolutionFailsWithoutCreatingMissingFoldersAndResolvesExistingOnes() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let icloudDir = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
        let desktopDir = tempHome.appendingPathComponent("Desktop", isDirectory: true)
        let trashDir = tempHome.appendingPathComponent(".Trash", isDirectory: true)

        // Missing Desktop, iCloud Drive, and Trash fail clearly and are never created.
        if case .success = FilesActionResolver.resolveFolderURL(for: .openDesktop, homeDirectoryURL: tempHome, fileManager: fm) {
            XCTFail("Expected missing Desktop to fail")
        }
        if case .success = FilesActionResolver.resolveFolderURL(for: .openICloud, homeDirectoryURL: tempHome, fileManager: fm) {
            XCTFail("Expected missing iCloud Drive to fail")
        }
        if case .success = FilesActionResolver.resolveFolderURL(for: .openTrash, homeDirectoryURL: tempHome, fileManager: fm) {
            XCTFail("Expected missing Trash to fail")
        }
        XCTAssertFalse(fm.fileExists(atPath: desktopDir.path))
        XCTAssertFalse(fm.fileExists(atPath: icloudDir.path))
        XCTAssertFalse(fm.fileExists(atPath: trashDir.path))

        let documentsDir = tempHome.appendingPathComponent("Documents", isDirectory: true)
        let downloadsDir = tempHome.appendingPathComponent("Downloads", isDirectory: true)
        let appsDir = tempHome.appendingPathComponent("Applications", isDirectory: true)
        for dir in [desktopDir, documentsDir, downloadsDir, appsDir, icloudDir, trashDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        XCTAssertEqual(
            FilesActionResolver.resolveFolderURL(for: .openHome, homeDirectoryURL: tempHome, fileManager: fm),
            .success(tempHome.standardizedFileURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFolderURL(for: .openDesktop, homeDirectoryURL: tempHome, fileManager: fm),
            .success(desktopDir.standardizedFileURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFolderURL(for: .openDocuments, homeDirectoryURL: tempHome, fileManager: fm),
            .success(documentsDir.standardizedFileURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFolderURL(for: .openDownloads, homeDirectoryURL: tempHome, fileManager: fm),
            .success(downloadsDir.standardizedFileURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFolderURL(
                for: .openApplications,
                homeDirectoryURL: tempHome,
                applicationsDirectoryURL: appsDir,
                fileManager: fm
            ),
            .success(appsDir.standardizedFileURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFolderURL(for: .openICloud, homeDirectoryURL: tempHome, fileManager: fm),
            .success(icloudDir.standardizedFileURL)
        )
        XCTAssertEqual(
            FilesActionResolver.resolveFolderURL(for: .openTrash, homeDirectoryURL: tempHome, fileManager: fm),
            .success(trashDir.standardizedFileURL)
        )
    }
}
