import Darwin
import Foundation

/// The devcontainer CLI, found on PATH, in the standalone install, or inside VS Code's Dev Containers extension.
struct DevcontainerCLI: Sendable {
  static let installScript =
    "https://raw.githubusercontent.com/devcontainers/cli/main/scripts/install.sh"
  static let installCommand = "curl -fsSL \(installScript) | sh"

  var path: String
  /// Where it was found, for `spinoff doctor`.
  var source: String

  static func find() -> DevcontainerCLI? {
    if let path = Shell.which("devcontainer") {
      return DevcontainerCLI(path: path, source: "on PATH")
    }
    let standalone = "\(Shell.home)/.devcontainers/bin/devcontainer"
    if FileManager.default.isExecutableFile(atPath: standalone) {
      return DevcontainerCLI(path: standalone, source: "standalone install")
    }
    return vscode()
  }

  /// The copy the VS Code Dev Containers extension writes on every activation; it runs on VS Code's own
  /// runtime and is the only one with `open`.
  static func vscode() -> DevcontainerCLI? {
    ["Code", "Code - Insiders"].map {
      "\(Shell.home)/Library/Application Support/\($0)/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin/devcontainer"
    }.first { FileManager.default.isExecutableFile(atPath: $0) }
      .map { DevcontainerCLI(path: $0, source: "VS Code Dev Containers") }
  }

  /// The CLI, offering to install it when a person is at the terminal.
  static func require() async throws -> DevcontainerCLI {
    if let cli = find() { return cli }
    if Terminal.isInteractive, confirmInstall() {
      return try await install()
    }
    throw SpinoffError.unavailable("the devcontainer CLI isn't installed; run `spinoff doctor`")
  }

  static func confirmInstall() -> Bool {
    Terminal.confirm(
      "The devcontainer CLI isn't installed. Install it now? It goes to ~/.devcontainers and brings its own Node.js."
    )
  }

  /// Runs the official install script, with its output on stderr.
  static func install() async throws -> DevcontainerCLI {
    guard try await Shell.runToStandardError("/bin/sh", ["-c", installCommand]), let cli = find()
    else {
      throw SpinoffError.unavailable("installing the devcontainer CLI failed")
    }
    return cli
  }

  /// Runs the CLI with its output collected as a log.
  func run(_ arguments: [String]) async throws -> (log: String, succeeded: Bool) {
    try await Shell.captureLog(path, arguments)
  }

  /// Replaces this process with the CLI, so stdio and the exit code are the command's own.
  func replaceProcess(_ arguments: [String]) -> Never {
    let cArguments = (["devcontainer"] + arguments).map { strdup($0) } + [nil]
    execv(path, cArguments)
    warn("spinoff: can't run \(path): \(String(cString: strerror(errno)))")
    exit(SpinoffError.unavailable("").exitCode)
  }
}
