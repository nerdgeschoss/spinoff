import Foundation
import Subprocess
import System

struct CommandResult {
  var out: String
  var err: String
  var exitCode: Int32

  var succeeded: Bool { exitCode == 0 }
}

/// A bare `origin` and its clone `acme` in a fresh temp dir, with helpers to drive spinoff against them.
/// Commands only see the fakes in `bin`, the system's own tools and a `home` of their own, never the real Docker or devcontainer CLI.
final class Fixture: Sendable {
  /// The `spinoff` binary SwiftPM built next to this test bundle.
  static let executable = Bundle(for: Fixture.self).bundleURL
    .deletingLastPathComponent().appending(path: "spinoff").path

  let root: String

  var main: String { "\(root)/acme" }
  var bin: String { "\(root)/bin" }
  var home: String { "\(root)/home" }

  var environment: Environment {
    Environment.inherit.updating([
      "PATH": "\(bin):/usr/bin:/bin",
      "HOME": home,
      "RAILS_ENV": nil,
      "NODE_ENV": nil,
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_AUTHOR_NAME": "Spinoff",
      "GIT_COMMITTER_NAME": "Spinoff",
      "GIT_AUTHOR_EMAIL": "spinoff@example.com",
      "GIT_COMMITTER_EMAIL": "spinoff@example.com",
    ])
  }

  func slotPath(_ n: Int) -> String { "\(root)/acme.\(n)" }

  init() async throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: "spinoff-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    root = String(cString: realpath(temporary.path, nil))
    for directory in [bin, home] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    try await git("init", "--quiet", "--bare", "-b", "main", "origin.git", in: root)
    try await git("init", "--quiet", "-b", "main", "acme", in: root)
    try write("\(main)/.gitignore", ".env\nnode_modules/\nconfig/master.key\n")
    try await commit("initial")
    try await git("remote", "add", "origin", "../origin.git")
    try await git("push", "--quiet", "-u", "origin", "main")
    try await git("remote", "set-head", "origin", "main")
  }

  deinit {
    try? FileManager.default.removeItem(atPath: root)
  }

  func spinoff(
    _ arguments: String..., in directory: String? = nil,
    environment: [Environment.Key: String?] = [:]
  ) async throws -> CommandResult {
    try await spinoff(arguments, in: directory, environment: environment)
  }

  func spinoff(
    _ arguments: [String], in directory: String? = nil,
    environment: [Environment.Key: String?] = [:], input: String = ""
  ) async throws -> CommandResult {
    try await execute(
      .path(FilePath(Self.executable)), arguments, in: directory ?? main, environment: environment,
      input: input)
  }

  @discardableResult
  func git(_ arguments: String..., in directory: String? = nil) async throws -> String {
    let result = try await execute(.name("git"), arguments, in: directory ?? main)
    guard result.succeeded else {
      throw SpinoffTestError("git \(arguments.joined(separator: " ")) failed: \(result.err)")
    }
    return result.out
  }

  @discardableResult
  func commit(_ message: String, in directory: String? = nil) async throws -> String {
    try await git("add", "--all", in: directory)
    try await git("commit", "--quiet", "--allow-empty", "-m", message, in: directory)
    return try await head(directory ?? main)
  }

  func head(_ path: String) async throws -> String {
    try await git("rev-parse", "HEAD", in: path).trimmingCharacters(in: .newlines)
  }

  func isDetached(_ path: String) async throws -> Bool {
    try await !execute(.name("git"), ["symbolic-ref", "--quiet", "HEAD"], in: path).succeeded
  }

  func write(_ path: String, _ content: String = "") throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
  }

  func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
  }

  func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  /// Writes an executable shell script, e.g. a fake `docker`.
  func script(_ path: String, _ body: String) throws {
    try write(path, "#!/bin/sh\n\(body)\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }

  /// The lock reason of the worktree at `path`, or nil if it isn't locked.
  func lockReason(_ path: String) async throws -> String? {
    let records = try await git("worktree", "list", "--porcelain").components(separatedBy: "\n\n")
    for record in records {
      let lines = record.split(separator: "\n").map(String.init)
      guard lines.first == "worktree \(path)" else { continue }
      guard let locked = lines.first(where: { $0 == "locked" || $0.hasPrefix("locked ") }) else {
        return nil
      }
      return String(locked.dropFirst("locked".count).drop { $0 == " " })
    }
    return nil
  }

  private func execute(
    _ executable: Executable, _ arguments: [String], in directory: String,
    environment: [Environment.Key: String?] = [:], input: String = ""
  ) async throws -> CommandResult {
    let result = try await Subprocess.run(
      executable,
      arguments: Arguments(arguments),
      environment: self.environment.updating(environment),
      workingDirectory: FilePath(directory),
      input: .string(input),
      output: .string(limit: 1 << 20),
      error: .string(limit: 1 << 20)
    )
    let exitCode: Int32
    switch result.terminationStatus {
    case .exited(let code): exitCode = code
    case .signaled(let signal): exitCode = 128 + signal
    }
    return CommandResult(
      out: result.standardOutput, err: result.standardError, exitCode: exitCode)
  }
}

struct SpinoffTestError: Error, CustomStringConvertible {
  var description: String

  init(_ description: String) { self.description = description }
}
