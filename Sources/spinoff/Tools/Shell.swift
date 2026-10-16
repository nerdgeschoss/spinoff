import Foundation
import Subprocess
import System

struct ShellResult {
  var output: String
  var error: String
  var exitCode: Int32

  var succeeded: Bool { exitCode == 0 }
}

enum Shell {
  private static let outputLimit = 64 << 20

  static var home: String {
    ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
  }

  /// Runs `executable` (a name looked up on PATH, or a path) and collects its output.
  static func capture(
    _ executable: String, _ arguments: [String], in directory: String? = nil, input: String? = nil
  ) async throws -> ShellResult {
    if let input {
      return try await collect(executable, arguments, directory, input: .string(input))
    }
    return try await collect(executable, arguments, directory, input: .none)
  }

  /// Runs `executable` and collects stdout and stderr interleaved, as a log to show when something fails.
  static func captureLog(_ executable: String, _ arguments: [String], in directory: String? = nil)
    async throws -> (log: String, succeeded: Bool)
  {
    let result = try await Subprocess.run(
      Self.executable(executable),
      arguments: Arguments(arguments),
      workingDirectory: directory.map { FilePath($0) },
      output: .string(limit: outputLimit),
      error: .combinedWithOutput
    )
    return (result.standardOutput, result.terminationStatus.isSuccess)
  }

  /// The last `count` lines of `log`.
  static func tail(_ log: String, _ count: Int = 30) -> String {
    log.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
      .suffix(count).joined(separator: "\n")
  }

  /// Runs `executable` with both of its output streams on our stderr, keeping stdout free for results.
  static func runToStandardError(
    _ executable: String, _ arguments: [String], in directory: String? = nil
  ) async throws -> Bool {
    let result = try await Subprocess.run(
      Self.executable(executable),
      arguments: Arguments(arguments),
      workingDirectory: directory.map { FilePath($0) },
      output: .currentStandardError,
      error: .currentStandardError
    )
    return result.terminationStatus.isSuccess
  }

  /// The absolute path of `name` on PATH, or nil.
  static func which(_ name: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").map { "\($0)/\(name)" }.first {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  private static func executable(_ name: String) -> Executable {
    name.contains("/") ? .path(FilePath(name)) : .name(name)
  }

  private static func collect<Input: InputProtocol>(
    _ executable: String, _ arguments: [String], _ directory: String?, input: Input
  ) async throws -> ShellResult {
    let result = try await Subprocess.run(
      Self.executable(executable),
      arguments: Arguments(arguments),
      workingDirectory: directory.map { FilePath($0) },
      input: input,
      output: .string(limit: outputLimit),
      error: .string(limit: outputLimit)
    )
    let exitCode: Int32
    switch result.terminationStatus {
    case .exited(let code): exitCode = code
    case .signaled(let signal): exitCode = 128 + signal
    }
    return ShellResult(
      output: result.standardOutput, error: result.standardError, exitCode: exitCode)
  }
}

enum Git {
  static func capture(_ arguments: [String], in directory: String, input: String? = nil)
    async throws -> ShellResult
  {
    try await Shell.capture("git", arguments, in: directory, input: input)
  }

  @discardableResult
  static func run(_ arguments: [String], in directory: String, input: String? = nil)
    async throws -> String
  {
    let result = try await capture(arguments, in: directory, input: input)
    guard result.succeeded else {
      throw SpinoffError.failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return result.output
  }
}

enum Docker {
  static var isInstalled: Bool { Shell.which("docker") != nil }

  /// Runs docker and returns its trimmed output, failing when Docker is missing or not running.
  @discardableResult
  static func run(_ arguments: [String]) async throws -> String {
    guard isInstalled else {
      throw SpinoffError.unavailable("Docker isn't installed; run `spinoff doctor`")
    }
    let result = try await Shell.capture("docker", arguments)
    guard result.succeeded else {
      throw SpinoffError.unavailable("Docker isn't running; run `spinoff doctor`")
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
