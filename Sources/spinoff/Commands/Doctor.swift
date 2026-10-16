import ArgumentParser
import Foundation

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check that everything spinoff needs is installed and set up."
  )

  struct Check {
    enum Status {
      case ok, warning, failure
    }

    var status: Status
    var title: String
    var hints: [String] = []
  }

  static let minimumGit = [2, 48]

  func run() async throws {
    var failed = false
    func report(_ check: Check) {
      failed = failed || check.status == .failure
      print(Self.render(check))
    }

    report(await Self.gitCheck())
    report(await Self.dockerCheck())
    if Docker.isInstalled { report(await Self.composeCheck()) }

    let devcontainer = await Self.devcontainerCheck()
    if devcontainer.status == .failure, Terminal.isInteractive {
      print(Self.render(devcontainer))
      if DevcontainerCLI.confirmInstall() {
        _ = try await DevcontainerCLI.install()
        report(await Self.devcontainerCheck())
      } else {
        failed = true
      }
    } else {
      report(devcontainer)
    }
    report(Self.vscodeCheck())

    if let repo = try? await Repo.current() {
      print("\n\(repo.project)")
      for check in await Self.repoChecks(repo) { report(check) }
    }

    if failed { throw ExitCode(1) }
  }

  static func render(_ check: Check) -> String {
    let (symbol, color) =
      switch check.status {
      case .ok: ("✓", "32")
      case .warning: ("!", "33")
      case .failure: ("✗", "31")
      }
    let marker = Terminal.usesColor ? "\u{1B}[\(color)m\(symbol)\u{1B}[0m" : symbol
    return (["\(marker) \(check.title)"] + check.hints.map { "    \($0)" }).joined(separator: "\n")
  }

  // MARK: Checks

  static func gitCheck() async -> Check {
    let hint = installHint(brew: "brew install git", download: "https://git-scm.com/downloads/mac")
    guard Shell.which("git") != nil else {
      return Check(status: .failure, title: "git not found", hints: [hint])
    }
    let output = (try? await Shell.capture("git", ["--version"]).output) ?? ""
    guard let version = parseVersion(output) else {
      return Check(status: .failure, title: "git doesn't report its version")
    }
    let versionString = version.map(String.init).joined(separator: ".")
    guard isSupportedGit(version) else {
      return Check(
        status: .failure, title: "git \(versionString) is too old; spinoff needs 2.48 or newer",
        hints: [hint])
    }
    return Check(status: .ok, title: "git \(versionString)")
  }

  static func dockerCheck() async -> Check {
    guard Docker.isInstalled else {
      return Check(status: .failure, title: "Docker not found", hints: dockerInstallHints())
    }
    if let info = try? await Docker.run([
      "info", "--format", "{{.ServerVersion}} ({{.OperatingSystem}})",
    ]) {
      return Check(status: .ok, title: "Docker \(info), running")
    }
    let context = (try? await Shell.capture("docker", ["context", "show"]))?.output
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Check(
      status: .failure, title: "Docker is installed but not running",
      hints: [startDockerHint(context: context ?? "")])
  }

  static func composeCheck() async -> Check {
    if let version = try? await Docker.run(["compose", "version", "--short"]) {
      return Check(status: .ok, title: "Docker Compose \(version)")
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
    guard let cli = DevcontainerCLI.find() else {
      return Check(
        status: .failure, title: "devcontainer CLI not found",
        hints: [
          "Install it (brings its own Node.js): \(DevcontainerCLI.installCommand)",
          "Or install the VS Code Dev Containers extension, which includes it.",
        ])
    }
    guard let result = try? await Shell.capture(cli.path, ["--version"]), result.succeeded else {
      return Check(
        status: .failure, title: "devcontainer CLI at \(cli.path) doesn't run",
        hints: ["Reinstall it: \(DevcontainerCLI.installCommand)"])
    }
    return Check(status: .ok, title: "devcontainer CLI \(trimmed(result.output)) (\(cli.source))")
  }

  static func vscodeCheck() -> Check {
    if DevcontainerCLI.vscode() != nil {
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
