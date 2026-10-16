import Foundation
import Testing

@Suite("spinoff exec")
struct ExecTests {
  let fixture: Fixture
  var bin: String { fixture.bin }
  var slot: String { fixture.slotPath(0) }

  init() async throws {
    fixture = try await Fixture()
    try fixture.write("\(fixture.main)/app/.keep")
    try await fixture.addDevcontainer()
    try fixture.installContainerFakes()
    _ = try await fixture.spinoff("start")
    try fixture.resetContainerFakes()
  }

  func exec(_ arguments: String..., in directory: String? = nil) async throws -> CommandResult {
    try await fixture.spinoff(
      ["exec"] + arguments, in: directory ?? slot,
      environment: ["RAILS_ENV": "test", "FOO": "bar"])
  }

  @Test("starts the container once and runs the command in it")
  func startsContainer() async throws {
    let result = try await exec("pwd")

    #expect(result.succeeded)
    #expect(result.out == "\(slot)\n")
    #expect(result.err.contains("spinoff: building container for acme.0;"))
    #expect(!result.err.contains("lots of build output"))
    #expect(try fixture.calls("up") == ["up --workspace-folder \(slot)"])

    let again = try await exec("pwd")
    #expect(!again.err.contains("starting container"))
    #expect(try fixture.calls("up").count == 1)
  }

  @Test("runs in the same subdirectory")
  func subdirectory() async throws {
    #expect(try await exec("pwd", in: "\(slot)/app").out == "\(slot)/app\n")
  }

  @Test("passes arguments through verbatim")
  func verbatimArguments() async throws {
    let result = try await exec("printf", "%s|", "a b", "$HOME", "--help", "'quoted'")

    #expect(result.out == "a b|$HOME|--help|'quoted'|")
  }

  @Test("keeps the command's exit code and output streams")
  func exitCode() async throws {
    let result = try await exec("sh", "-c", "echo out; echo err >&2; exit 7")

    #expect(result.exitCode == 7)
    #expect(result.out == "out\n")
    #expect(result.err.hasSuffix("err\n"))
  }

  @Test("forwards only allowlisted environment variables")
  func environment() async throws {
    _ = try await exec("true")

    #expect(try fixture.calls("env") == ["env RAILS_ENV=test"])
  }

  @Test("starts the container only once for parallel calls")
  func parallel() async throws {
    async let first = exec("true")
    async let second = exec("true")
    let results = try await [first, second]

    #expect(results.allSatisfy { $0.succeeded })
    #expect(try fixture.calls("up").count == 1)
  }

  @Test("reports a container that fails to start with exit 125")
  func containerFailure() async throws {
    try fixture.write("\(bin)/fail-up")

    let result = try await exec("true")

    #expect(result.exitCode == 125)
    #expect(result.err.contains("lots of build output\nboom\n"))
    #expect(result.err.hasSuffix("spinoff: the container for acme.0 failed to start\n"))
  }

  @Test("points to doctor when the devcontainer CLI is missing")
  func devcontainerMissing() async throws {
    try FileManager.default.removeItem(atPath: "\(bin)/devcontainer")

    let result = try await exec("true")

    #expect(result.exitCode == 125)
    #expect(
      result.err == "spinoff: the devcontainer CLI isn't installed; run `spinoff doctor`\n")
  }

  @Test("points to doctor when Docker is missing")
  func dockerMissing() async throws {
    try FileManager.default.removeItem(atPath: "\(bin)/docker")

    let result = try await exec("true")

    #expect(result.exitCode == 125)
    #expect(result.err == "spinoff: Docker isn't installed; run `spinoff doctor`\n")
  }

  @Test("refuses outside a slot")
  func outsideSlot() async throws {
    let result = try await exec("true", in: fixture.main)

    #expect(result.exitCode == 1)
    #expect(result.err == "spinoff: not inside a slot; `spinoff start` hands one out\n")
  }

  @Test("lists the slot as running once its container is up")
  func listShowsRunning() async throws {
    _ = try await exec("true")

    let list = try await fixture.spinoff("list")

    #expect(list.out.contains("acme.0  "))
    #expect(list.out.contains("  running  manual"))
  }
}
