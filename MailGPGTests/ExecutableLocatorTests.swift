import XCTest
@testable import MailGPG

final class ExecutableLocatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func executable(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func locate(
        _ environment: [String: String], fallback: [String] = [], names: [String] = ["gpg", "gpg2"]
    ) throws -> String {
        try ExecutableLocator.locate(
            overrideKey: "MAILGPG_GPG_PATH", names: names,
            fallbackPaths: fallback, environment: environment)
    }

    func testExplicitPathWinsOverPATHAndFallback() throws {
        let explicit = try executable("custom tools/my gpg")
        let other = try executable("other/gpg")
        XCTAssertEqual(try locate([
            "MAILGPG_GPG_PATH": explicit,
            "PATH": URL(fileURLWithPath: other).deletingLastPathComponent().path,
        ], fallback: [other]), explicit)
    }

    func testInvalidExplicitPathNeverFallsBack() throws {
        let fallback = try executable("fallback/gpg")
        for path in ["", "relative/gpg", directory.path, directory.path + "/missing", "/bin/sh\n"] {
            XCTAssertThrowsError(try locate([
                "MAILGPG_GPG_PATH": path, "PATH": "/bin",
            ], fallback: [fallback])) { error in
                guard case GPGLocatorError.invalidOverride("MAILGPG_GPG_PATH") = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testNonExecutableOverrideIsRejected() throws {
        let path = try executable("gpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertThrowsError(try locate(["MAILGPG_GPG_PATH": path]))
    }

    func testPATHPrecedesKnownLocationsAndPreservesDirectoryOrder() throws {
        let first = try executable("first/gpg2")
        let second = try executable("second/gpg")
        let fallback = try executable("fallback/gpg")
        let path = [first, second].map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            .joined(separator: ":")
        XCTAssertEqual(try locate(["PATH": path], fallback: [fallback]), first)
    }

    func testGPGPreferredOverGPG2InSameDirectory() throws {
        let gpg = try executable("bin/gpg")
        _ = try executable("bin/gpg2")
        XCTAssertEqual(try locate(["PATH": directory.appendingPathComponent("bin").path]), gpg)
    }

    func testMissingPATHUsesFallback() throws {
        let fallback = try executable("fallback/gpg")
        XCTAssertEqual(try locate([:], fallback: [fallback]), fallback)
    }

    func testRelativeAndEmptyPATHEntriesAreIgnored() throws {
        // Even a matching executable in the working directory is not eligible.
        let path = try executable("gpg")
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        XCTAssertThrowsError(try locate(["PATH": ":.:relative:"]))
        XCTAssertEqual(try locate(["PATH": ":.:relative:"], fallback: [path]), path)
    }

    func testDirectoriesAreNotExecutables() throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("gpg"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try locate(["PATH": directory.path]))
    }

    func testPinentryOverrideAndPATHDiscovery() throws {
        let pinentry = try executable("GUI tools/pinentry-mac")
        XCTAssertEqual(try ExecutableLocator.locate(
            overrideKey: "MAILGPG_PINENTRY_PATH", names: ["pinentry-mac"], fallbackPaths: [],
            environment: ["MAILGPG_PINENTRY_PATH": pinentry]), pinentry)
        XCTAssertEqual(try ExecutableLocator.locate(
            overrideKey: "MAILGPG_PINENTRY_PATH", names: ["pinentry-mac"], fallbackPaths: [],
            environment: ["PATH": URL(fileURLWithPath: pinentry).deletingLastPathComponent().path]), pinentry)
        XCTAssertThrowsError(try ExecutableLocator.locate(
            overrideKey: "MAILGPG_PINENTRY_PATH", names: ["pinentry-mac"], fallbackPaths: [pinentry],
            environment: ["MAILGPG_PINENTRY_PATH": "missing"]))
    }

    func testCompanionToolsFollowSelectedGPGThroughProfileSymlinks() throws {
        let gpg = try executable("installation/bin/gpg")
        let profile = directory.appendingPathComponent("profile/bin")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let link = profile.appendingPathComponent("gpg")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: gpg)
        _ = try executable("profile/bin/gpgconf")
        let expected = URL(fileURLWithPath: gpg).deletingLastPathComponent()
            .appendingPathComponent("gpgconf").resolvingSymlinksInPath().path
        XCTAssertEqual(try GPGAgent.toolPath("gpgconf", environment: [
            "MAILGPG_GPG_PATH": link.path,
        ]), expected)
    }

    func testRealConfiguredGPGAndCompanionVersion() throws {
        guard let path = ProcessInfo.processInfo.environment["MAILGPG_TEST_GPG_PATH"] else {
            throw XCTSkip("Set MAILGPG_TEST_GPG_PATH for the installed GnuPG smoke test")
        }
        let environment = ["MAILGPG_GPG_PATH": path, "PATH": ""]
        let selected = try GPGLocator.locate(environment: environment)
        XCTAssertTrue(try GPGLocator.version(at: selected).contains("GnuPG"))
        let companion = try GPGAgent.toolPath("gpgconf", environment: environment)
        XCTAssertTrue(try GPGLocator.version(at: companion).contains("GnuPG"))
    }
}
