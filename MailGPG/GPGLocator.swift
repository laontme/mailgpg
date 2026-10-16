//
//  GPGLocator.swift
//  MailGPG
//
//  Created by Marcel Haupt on 17.03.26.
//
import Foundation

enum GPGLocatorError: LocalizedError {
    case notFound
    case invalidOverride(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Executable not found in PATH or known installation locations."
        case .invalidOverride(let key):
            return "\(key) must name an existing executable using an absolute path."
        }
    }
}

/// Shared discovery for tools launched by the unsandboxed host app.
struct ExecutableLocator {
    static func locate(
        overrideKey: String,
        names: [String],
        fallbackPaths: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        // An explicit setting is authoritative. Never silently switch to a
        // different installation when a configured executable is unavailable.
        if let path = environment[overrideKey] {
            guard isExecutable(path) else {
                throw GPGLocatorError.invalidOverride(overrideKey)
            }
            return path
        }

        // Ignore relative/empty PATH entries: a background app must not execute
        // tools from its current working directory.
        let directories = (environment["PATH"] ?? "").components(separatedBy: ":")
            .filter { $0.hasPrefix("/") }
        let searchPaths = directories.flatMap { directory in
            names.map { URL(fileURLWithPath: directory).appendingPathComponent($0).path }
        }
        if let path = (searchPaths + fallbackPaths).first(where: isExecutable) {
            return path
        }
        throw GPGLocatorError.notFound
    }

    private static func isExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"),
              !path.contains("\0") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// GUI apps do not necessarily inherit the interactive shell's PATH.
    static var nixBinDirectories: [String] {
        [
            NSHomeDirectory() + "/.nix-profile/bin",
            "/etc/profiles/per-user/" + NSUserName() + "/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
        ]
    }
}

struct GPGLocator {
    /// Alle bekannten Installationspfade, Reihenfolge ist Priorität
    static let candidatePaths = [
        "/opt/homebrew/bin/gpg",       // Apple Silicon Homebrew
        "/usr/local/bin/gpg",          // Intel Homebrew
        "/usr/local/MacGPG2/bin/gpg",  // GPG Suite
        "/usr/bin/gpg",                // System (selten)
        "/opt/homebrew/bin/gpg2",      // Alternative Namen
        "/usr/local/bin/gpg2",
    ] + ExecutableLocator.nixBinDirectories.map { $0 + "/gpg" }
    
    /// Findet den ersten verfügbaren GPG-Binary und gibt seinen Pfad zurück
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        try ExecutableLocator.locate(
            overrideKey: "MAILGPG_GPG_PATH",
            names: ["gpg", "gpg2"],
            fallbackPaths: candidatePaths,
            environment: environment)
    }

    /// Ruft `gpg --version` auf und gibt die Version zurück — damit testen wir ob es wirklich funktioniert
    static func version(at path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
      
        // Xcode Preview-Injektion aus der Umgebung entfernen
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        process.environment = env
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        try process.run()
        process.waitUntilExit()
        
        // Beide Pipes lesen
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        
        // Ersten nicht-leeren String aus beiden nehmen
        let output = stdout.isEmpty ? stderr : stdout
        guard let firstLine = output.components(separatedBy: "\n").first(where: { !$0.isEmpty }) else {
            throw GPGLocatorError.notFound
        }
        return firstLine
    }
}
