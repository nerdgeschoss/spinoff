import Foundation
import Testing

@testable import spinoff

@Suite("spinoff doctor")
struct DoctorTests {
  let fixture: Fixture
  var bin: String { fixture.bin }
  var home: String { fixture.home }

  static let workingDocker = """
    case "$1" in
      info) echo "29.8.2 (Docker Desktop)" ;;
      compose) echo "5.6.0" ;;
      context) echo "desktop-linux" ;;
    esac
    """

  init() async throws {
    fixture = try await Fixture()
  }

  func doctor(in directory: String? = nil) async throws -> CommandResult {
    try await fixture.spinoff("doctor", in: directory ?? fixture.root)
  }

  @Test("passes when everything is installed, with warnings only for optional tools")
  func allPresent() async throws {
    try fixture.script("\(bin)/docker", Self.workingDocker)
    try fixture.script("\(bin)/devcontainer", "echo 0.89.0")

    let result = try await doctor()

    #expect(result.exitCode == 0)
    #expect(result.out.contains("✓ git 2."))
    #expect(result.out.contains("✓ Docker 29.8.2 (Docker Desktop), running"))
    #expect(result.out.contains("✓ Docker Compose 5.6.0"))
    #expect(result.out.contains("✓ devcontainer CLI 0.89.0 (on PATH)"))
    #expect(result.out.contains("! VS Code Dev Containers extension not found"))
  }

  @Test("points to the Docker downloads when Docker is missing")
  func dockerMissing() async throws {
    try fixture.script("\(bin)/devcontainer", "echo 0.89.0")

    let result = try await doctor()

    #expect(result.exitCode == 1)
    #expect(result.out.contains("✗ Docker not found"))
    #expect(result.out.contains("https://www.docker.com/products/docker-desktop/"))
    #expect(!result.out.contains("Compose"))
  }

  @Test("suggests Homebrew casks when Homebrew is installed")
  func dockerMissingWithHomebrew() async throws {
    try fixture.script("\(bin)/brew", "")

    let result = try await doctor()

    #expect(result.out.contains("brew install --cask docker-desktop"))
    #expect(result.out.contains("brew install --cask orbstack"))
  }

  @Test("explains how to start the Docker daemon for the current context")
  func dockerNotRunning() async throws {
    try fixture.script(
      "\(bin)/docker",
      """
      case "$1" in
        info) echo "failed to connect to the docker API" >&2; exit 1 ;;
        compose) echo "5.6.0" ;;
        context) echo "orbstack" ;;
      esac
      """)

    let result = try await doctor()

    #expect(result.exitCode == 1)
    #expect(
      result.out.contains(
        "✗ Docker is installed but not running\n    Start OrbStack: open -a OrbStack"))
  }

  @Test("finds the standalone devcontainer install")
  func standaloneDevcontainer() async throws {
    try fixture.script("\(bin)/docker", Self.workingDocker)
    try fixture.script("\(home)/.devcontainers/bin/devcontainer", "echo 0.89.0")

    #expect(try await doctor().out.contains("✓ devcontainer CLI 0.89.0 (standalone install)"))
  }

  @Test("finds the devcontainer CLI bundled with VS Code")
  func vscodeDevcontainer() async throws {
    try fixture.script("\(bin)/docker", Self.workingDocker)
    try fixture.script(
      "\(home)/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin/devcontainer",
      "echo 0.89.0")

    let result = try await doctor()

    #expect(result.exitCode == 0)
    #expect(result.out.contains("✓ devcontainer CLI 0.89.0 (VS Code Dev Containers)"))
    #expect(result.out.contains("✓ VS Code Dev Containers extension"))
  }

  @Test("explains how to install the devcontainer CLI without asking when not interactive")
  func devcontainerMissing() async throws {
    try fixture.script("\(bin)/docker", Self.workingDocker)

    let result = try await doctor()

    #expect(result.exitCode == 1)
    #expect(
      result.out.contains(
        "✗ devcontainer CLI not found\n    Install it (brings its own Node.js): \(Toolchain.installCommand)"
      ))
    #expect(result.out.contains("Or install the VS Code Dev Containers extension"))
    #expect(!result.err.contains("[Y/n]"))
  }

  @Test("checks the repo it runs in")
  func repoChecks() async throws {
    try fixture.script("\(bin)/docker", Self.workingDocker)
    try fixture.script("\(bin)/devcontainer", "echo 0.89.0")

    let healthy = try await doctor(in: fixture.main)
    #expect(healthy.exitCode == 0)
    #expect(
      healthy.out.contains(
        "\nacme\n✓ origin's default branch is origin/main\n! no devcontainer config"))

    try await fixture.git("remote", "set-head", "origin", "--delete")
    let broken = try await doctor(in: fixture.main)
    #expect(broken.exitCode == 1)
    #expect(
      broken.out.contains(
        "✗ origin has no default branch\n    Set it: git remote set-head origin --auto"))
  }

  @Test("parses git versions and requires 2.48")
  func gitVersions() {
    #expect(Toolchain.parseVersion("git version 2.54.0 (Apple Git-157)") == [2, 54, 0])
    #expect(Toolchain.parseVersion("git version 2.48") == [2, 48, 0])
    #expect(Toolchain.isSupportedGit([2, 48, 0]))
    #expect(!Toolchain.isSupportedGit([2, 47, 1]))
  }
}
