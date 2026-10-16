import Foundation

struct Check {
  enum Status {
    case ok, warning, failure
  }

  var status: Status
  var title: String
  var hints: [String] = []
}

/// Finds the tools spinoff relies on and explains how to get the missing ones.
enum Toolchain {
  static let installScript =
    "https://raw.githubusercontent.com/devcontainers/cli/main/scripts/install.sh"
  static let installCommand = "curl -fsSL \(installScript) | sh"
  static let minimumGit = [2, 48]

  struct DevcontainerCLI {
    var path: String
    var source: String
  }

  // MARK: devcontainer CLI

  static func findDevcontainer() -> DevcontainerCLI? {
    if let path = Shell.which("devcontainer") {
      return DevcontainerCLI(path: path, source: "on PATH")
    }
    let standalone = "\(Shell.home)/.devcontainers/bin/devcontainer"
    if FileManager.default.isExecutableFile(atPath: standalone) {
      return DevcontainerCLI(path: standalone, source: "standalone install")
    }
    if let path = vscodeDevcontainer() {
      return DevcontainerCLI(path: path, source: "VS Code Dev Containers")
    }
    return nil
  }

  /// The CLI the VS Code Dev Containers extension writes on every activation; it runs on VS Code's own runtime.
  static func vscodeDevcontainer() -> String? {
    ["Code", "Code - Insiders"].map {
      "\(Shell.home)/Library/Application Support/\($0)/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin/devcontainer"
    }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// The devcontainer CLI's path, offering to install it when a person is at the terminal.
  static func devcontainer(offerInstall: Bool) async throws -> String {
    if let cli = findDevcontainer() { return cli.path }
    if offerInstall, Terminal.isInteractive, confirmInstall() {
      try await installDevcontainer()
      if let cli = findDevcontainer() { return cli.path }
    }
    throw SpinoffError("the devcontainer CLI isn't installed; run `spinoff doctor`", exitCode: 125)
  }

  static func confirmInstall() -> Bool {
    Terminal.confirm(
      "The devcontainer CLI isn't installed. Install it now? It goes to ~/.devcontainers and brings its own Node.js."
    )
  }

  static func installDevcontainer() async throws {
    guard try await Shell.runToStandardError("/bin/sh", ["-c", installCommand]),
      findDevcontainer() != nil
    else {
      throw SpinoffError("installing the devcontainer CLI failed", exitCode: 125)
    }
  }

  // MARK: Checks

  static func gitCheck() async -> Check {
    guard Shell.which("git") != nil else {
      return Check(
        status: .failure, title: "git not found",
        hints: [
          installHint(brew: "brew install git", download: "https://git-scm.com/downloads/mac")
        ])
    }
    let output = (try? await Shell.capture("git", ["--version"]).output) ?? ""
    guard let version = parseVersion(output) else {
      return Check(status: .failure, title: "git doesn't report its version")
    }
    let versionString = version.map(String.init).joined(separator: ".")
    guard isSupportedGit(version) else {
      return Check(
        status: .failure,
        title: "git \(versionString) is too old; spinoff needs 2.48 or newer",
        hints: [
          installHint(brew: "brew install git", download: "https://git-scm.com/downloads/mac")
        ])
    }
    return Check(status: .ok, title: "git \(versionString)")
  }

  static func dockerCheck() async -> Check {
    guard Shell.which("docker") != nil else {
      return Check(status: .failure, title: "Docker not found", hints: dockerInstallHints())
    }
    let info = try? await Shell.capture(
      "docker", ["info", "--format", "{{.ServerVersion}} ({{.OperatingSystem}})"])
    if let info, info.succeeded {
      return Check(
        status: .ok,
        title: "Docker \(info.output.trimmingCharacters(in: .whitespacesAndNewlines)), running")
    }
    let context = (try? await Shell.capture("docker", ["context", "show"]))?.output
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Check(
      status: .failure, title: "Docker is installed but not running",
      hints: [startDockerHint(context: context ?? "")])
  }

  static func composeCheck() async -> Check {
    if let result = try? await Shell.capture("docker", ["compose", "version", "--short"]),
      result.succeeded
    {
      return Check(status: .ok, title: "Docker Compose \(trimmed(result.output))")
    }
    if Shell.which("docker-compose") != nil,
      let result = try? await Shell.capture("docker-compose", ["version", "--short"]),
      result.succeeded
    {
      return Check(status: .ok, title: "docker-compose \(trimmed(result.output))")
    }
    var hints = ["Docker Desktop and OrbStack include it."]
    if Shell.which("brew") != nil { hints.append("Install it: brew install docker-compose") }
    return Check(status: .failure, title: "Docker Compose not found", hints: hints)
  }

  static func devcontainerCheck() async -> Check {
    guard let cli = findDevcontainer() else {
      return Check(
        status: .failure, title: "devcontainer CLI not found",
        hints: [
          "Install it (brings its own Node.js): \(installCommand)",
          "Or install the VS Code Dev Containers extension, which includes it.",
        ])
    }
    guard let result = try? await Shell.capture(cli.path, ["--version"]), result.succeeded else {
      return Check(
        status: .failure, title: "devcontainer CLI at \(cli.path) doesn't run",
        hints: ["Reinstall it: \(installCommand)"])
    }
    return Check(status: .ok, title: "devcontainer CLI \(trimmed(result.output)) (\(cli.source))")
  }

  static func vscodeCheck() -> Check {
    if vscodeDevcontainer() != nil {
      return Check(status: .ok, title: "VS Code Dev Containers extension")
    }
    let hint =
      Shell.which("code") != nil
      ? "Install it: code --install-extension ms-vscode-remote.remote-containers, then open VS Code once."
      : "Install VS Code (https://code.visualstudio.com) and its Dev Containers extension, then open VS Code once."
    return Check(
      status: .warning,
      title: "VS Code Dev Containers extension not found (needed for `spinoff open`)",
      hints: [hint])
  }

  static func repoChecks(_ repo: Repo) async -> [Check] {
    var checks: [Check] = []
    if let remote = try? await Git.capture(["remote", "get-url", "origin"], in: repo.main),
      remote.succeeded
    {
      if let branch = try? await repo.defaultBranch() {
        checks.append(Check(status: .ok, title: "origin's default branch is \(branch)"))
      } else {
        checks.append(
          Check(
            status: .failure, title: "origin has no default branch",
            hints: ["Set it: git remote set-head origin --auto"]))
      }
    } else {
      checks.append(
        Check(
          status: .failure, title: "no `origin` remote",
          hints: ["Add it: git remote add origin <url>"]))
    }

    if let config = Container.config(in: repo.root) {
      checks.append(Check(status: .ok, title: config))
    } else {
      checks.append(
        Check(
          status: .warning, title: "no devcontainer config",
          hints: [
            "Without one, slots are plain worktrees and `spinoff exec` can't run commands in a container.",
            "VS Code's \"Dev Containers: Add Dev Container Configuration Files…\" creates one.",
          ]))
    }
    return checks
  }

  // MARK: Helpers

  static func parseVersion(_ text: String) -> [Int]? {
    guard let match = text.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?/) else { return nil }
    return [match.1, match.2, match.3 ?? "0"].compactMap { Int($0) }
  }

  static func isSupportedGit(_ version: [Int]) -> Bool {
    !version.lexicographicallyPrecedes(minimumGit)
  }

  private static func installHint(brew: String, download: String) -> String {
    Shell.which("brew") != nil ? "Install it: \(brew)" : "Download it: \(download)"
  }

  private static func dockerInstallHints() -> [String] {
    if Shell.which("brew") != nil {
      return [
        "Install Docker Desktop: brew install --cask docker-desktop",
        "Or OrbStack: brew install --cask orbstack",
      ]
    }
    return [
      "Install Docker Desktop: https://www.docker.com/products/docker-desktop/",
      "Or OrbStack: https://orbstack.dev",
    ]
  }

  private static func startDockerHint(context: String) -> String {
    switch context {
    case "desktop-linux": "Start Docker Desktop: open -a Docker"
    case "orbstack": "Start OrbStack: open -a OrbStack"
    case let context where context.hasPrefix("colima"): "Start Colima: colima start"
    default: "Start the Docker daemon for context \"\(context)\"."
    }
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
