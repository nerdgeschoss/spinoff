import Foundation

/// The devcontainer of a worktree, identified by the `devcontainer.local_folder` label that the devcontainer CLI and VS Code set.
enum Container {
  static let configPaths = [".devcontainer/devcontainer.json", ".devcontainer.json"]
  static let forwardedEnvironment = ["RAILS_ENV", "NODE_ENV"]

  /// The devcontainer config of the worktree at `root`, relative to it.
  static func config(in root: String) -> String? {
    configPaths.first { FileManager.default.fileExists(atPath: "\(root)/\($0)") }
  }

  static func isRunning(_ folder: String) async throws -> Bool {
    try await !docker(["ps", "-q", "--filter", "label=devcontainer.local_folder=\(folder)"]).isEmpty
  }

  /// The folders of all running devcontainers, or nil if Docker isn't available.
  static func runningFolders() async -> Set<String>? {
    guard
      let output = try? await docker([
        "ps", "--filter", "label=devcontainer.local_folder",
        "--format", "{{.Label \"devcontainer.local_folder\"}}",
      ])
    else { return nil }
    return Set(output.split(separator: "\n").map(String.init))
  }

  static func exists(_ folder: String) async throws -> Bool {
    try await !docker(["ps", "-aq", "--filter", "label=devcontainer.local_folder=\(folder)"])
      .isEmpty
  }

  /// Starts the container unless it's running; parallel callers wait for the first one.
  /// The devcontainer CLI's log is only shown when starting fails.
  static func ensureRunning(_ folder: String, devcontainer: String) async throws {
    if try await isRunning(folder) { return }
    try await withDirectoryLock(folder) {
      if try await isRunning(folder) { return }
      let name = (folder as NSString).lastPathComponent
      if try await exists(folder) {
        warn("spinoff: starting container for \(name)…")
      } else {
        warn(
          "spinoff: building container for \(name); the first start runs its setup and can take a few minutes…"
        )
      }
      let result = try await Shell.captureLog(devcontainer, ["up", "--workspace-folder", folder])
      guard result.succeeded else {
        warn(Shell.tail(result.log))
        throw SpinoffError("the container for \(name) failed to start", exitCode: 125)
      }
    }
  }

  /// Runs the project's `bin/setup` in the container, if it has one, without starting a server.
  static func setUp(_ folder: String, devcontainer: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: "\(folder)/bin/setup") else { return }
    let name = (folder as NSString).lastPathComponent
    warn("spinoff: running bin/setup in \(name)…")
    // Rails 8.0+ knows --skip-server and 8.1+ --reset; older and custom scripts ignore them.
    let result = try await Shell.captureLog(
      devcontainer,
      ["exec", "--workspace-folder", folder, "bin/setup", "--skip-server", "--reset"])
    guard result.succeeded else {
      warn(Shell.tail(result.log))
      throw SpinoffError("bin/setup failed in \(name)")
    }
  }

  /// Stops the containers of `folder` (all compose services) if any are running; returns whether it did.
  static func stopIfRunning(_ folder: String) async throws -> Bool {
    guard Shell.which("docker") != nil,
      let output = try? await docker([
        "ps", "--filter", "label=devcontainer.local_folder=\(folder)",
        "--format", "{{.ID}} {{.Label \"com.docker.compose.project\"}}",
      ]), !output.isEmpty
    else { return false }

    let containers = output.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
    if let project = containers.first?.dropFirst().first {
      _ = try await docker(["compose", "-p", project, "stop"])
    } else {
      _ = try await docker(["stop"] + containers.compactMap(\.first))
    }
    return true
  }

  /// Replaces this process with `devcontainer exec`, running `command` in the same subdirectory inside the container.
  static func exec(devcontainer: String, folder: String, subdirectory: String, command: [String])
    -> Never
  {
    let environment = ProcessInfo.processInfo.environment
    var arguments = ["devcontainer", "exec", "--workspace-folder", folder]
    for key in forwardedEnvironment {
      if let value = environment[key] { arguments += ["--remote-env", "\(key)=\(value)"] }
    }
    arguments += ["sh", "-c", #"cd "$1" && shift && exec "$@""#, "spinoff"]
    arguments += [subdirectory.isEmpty ? "." : subdirectory] + command

    let cArguments = arguments.map { strdup($0) } + [nil]
    execv(devcontainer, cArguments)
    warn("spinoff: can't run \(devcontainer): \(String(cString: strerror(errno)))")
    exit(125)
  }

  private static func docker(_ arguments: [String]) async throws -> String {
    guard Shell.which("docker") != nil else {
      throw SpinoffError("Docker isn't installed; run `spinoff doctor`", exitCode: 125)
    }
    let result = try await Shell.capture("docker", arguments)
    guard result.succeeded else {
      throw SpinoffError("Docker isn't running; run `spinoff doctor`", exitCode: 125)
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
