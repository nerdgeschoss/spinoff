import Foundation

/// A worktree's devcontainer, identified by the `devcontainer.local_folder` label that the devcontainer CLI and
/// VS Code set. Starting it again reuses what was built; only stopping it is up to spinoff.
struct Container: Sendable {
  static let configPaths = [".devcontainer/devcontainer.json", ".devcontainer.json"]
  static let forwardedEnvironment = ["RAILS_ENV", "NODE_ENV"]

  var folder: String

  var name: String { (folder as NSString).lastPathComponent }

  /// The devcontainer config of the worktree at `root`, relative to it.
  static func config(in root: String) -> String? {
    configPaths.first { FileManager.default.fileExists(atPath: "\(root)/\($0)") }
  }

  /// The folders of all running devcontainers, or nil if Docker isn't available.
  static func runningFolders() async -> Set<String>? {
    guard
      let output = try? await Docker.run([
        "ps", "--filter", "label=devcontainer.local_folder",
        "--format", "{{.Label \"devcontainer.local_folder\"}}",
      ])
    else { return nil }
    return Set(output.split(separator: "\n").map(String.init))
  }

  func isRunning() async throws -> Bool {
    try await !Docker.run(["ps", "-q", "--filter", label]).isEmpty
  }

  func exists() async throws -> Bool {
    try await !Docker.run(["ps", "-aq", "--filter", label]).isEmpty
  }

  /// Starts the container unless it's running; parallel callers wait for the first one.
  /// The devcontainer CLI's log is only shown when starting fails.
  func start(with cli: DevcontainerCLI) async throws {
    if try await isRunning() { return }
    try await withDirectoryLock(folder) {
      if try await isRunning() { return }
      if try await exists() {
        warn("spinoff: starting container for \(name)…")
      } else {
        warn(
          "spinoff: building container for \(name); the first start runs its setup and can take a few minutes…"
        )
      }
      let result = try await cli.run(["up", "--workspace-folder", folder])
      guard result.succeeded else {
        warn(Shell.tail(result.log))
        throw SpinoffError.unavailable("the container for \(name) failed to start")
      }
    }
  }

  /// Runs the project's `bin/setup` in the container, if it has one, without starting a server.
  func setUp(with cli: DevcontainerCLI) async throws {
    guard FileManager.default.isExecutableFile(atPath: "\(folder)/bin/setup") else { return }
    warn("spinoff: running bin/setup in \(name)…")
    // Rails 8.0+ knows --skip-server and 8.1+ --reset; older and custom scripts ignore them.
    let result = try await cli.run(
      ["exec", "--workspace-folder", folder, "bin/setup", "--skip-server", "--reset"])
    guard result.succeeded else {
      warn(Shell.tail(result.log))
      throw SpinoffError.failed("bin/setup failed in \(name)")
    }
  }

  /// Stops all of the container's compose services if it's running; returns whether it did.
  func stopIfRunning() async throws -> Bool {
    guard Docker.isInstalled,
      let output = try? await Docker.run([
        "ps", "--filter", label, "--format", "{{.ID}} {{.Label \"com.docker.compose.project\"}}",
      ]), !output.isEmpty
    else { return false }

    let containers = output.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
    if let project = containers.first?.dropFirst().first {
      try await Docker.run(["compose", "-p", project, "stop"])
    } else {
      try await Docker.run(["stop"] + containers.compactMap(\.first))
    }
    return true
  }

  /// Replaces this process with `devcontainer exec`, running `command` in the same subdirectory inside the container.
  func exec(_ command: [String], in subdirectory: String, with cli: DevcontainerCLI) -> Never {
    let environment = ProcessInfo.processInfo.environment
    var arguments = ["exec", "--workspace-folder", folder]
    for key in Self.forwardedEnvironment {
      if let value = environment[key] { arguments += ["--remote-env", "\(key)=\(value)"] }
    }
    arguments += ["sh", "-c", #"cd "$1" && shift && exec "$@""#, "spinoff"]
    cli.replaceProcess(arguments + [subdirectory.isEmpty ? "." : subdirectory] + command)
  }

  private var label: String { "label=devcontainer.local_folder=\(folder)" }
}
