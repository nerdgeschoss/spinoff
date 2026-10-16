import ArgumentParser
import Foundation

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check that everything spinoff needs is installed and set up."
  )

  func run() async throws {
    var failed = false
    func report(_ check: Check) {
      failed = failed || check.status == .failure
      print(Self.render(check))
    }

    report(await Toolchain.gitCheck())
    let docker = await Toolchain.dockerCheck()
    report(docker)
    if Shell.which("docker") != nil { report(await Toolchain.composeCheck()) }

    var devcontainer = await Toolchain.devcontainerCheck()
    if devcontainer.status == .failure, Terminal.isInteractive {
      print(Self.render(devcontainer))
      if Toolchain.confirmInstall() {
        try await Toolchain.installDevcontainer()
        devcontainer = await Toolchain.devcontainerCheck()
        report(devcontainer)
      } else {
        failed = true
      }
    } else {
      report(devcontainer)
    }
    report(Toolchain.vscodeCheck())

    if let repo = try? await Repo.current() {
      print("\n\(repo.project)")
      for check in await Toolchain.repoChecks(repo) { report(check) }
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
}
