import Foundation
import Testing

@Suite("containers in start and release")
struct ContainerTests {
  let fixture: Fixture
  var slot: String { fixture.slotPath(0) }

  init() async throws {
    fixture = try await Fixture()
    try fixture.installContainerFakes()
  }

  @Test("start brings the container up and runs bin/setup without a server")
  func startPrepares() async throws {
    try await fixture.addDevcontainer(setup: #"echo "setup $*" >> $LOG"#)

    let result = try await fixture.spinoff("start")

    #expect(result.succeeded)
    #expect(result.out == "\(slot)\n")
    #expect(try fixture.calls("up") == ["up --workspace-folder \(slot)"])
    #expect(try fixture.calls("setup") == ["setup --skip-server --reset"])
    #expect(result.err.contains("spinoff: running bin/setup in acme.0…"))
    #expect(!result.err.contains("lots of build output"))
  }

  @Test("start skips bin/setup when the project has none")
  func startWithoutSetup() async throws {
    try await fixture.addDevcontainer()

    #expect(try await fixture.spinoff("start").succeeded)
    #expect(try fixture.calls("up").count == 1)
    #expect(try fixture.calls("setup").isEmpty)
  }

  @Test("start hands out a plain worktree without a devcontainer config")
  func startWithoutDevcontainer() async throws {
    let result = try await fixture.spinoff("start")

    #expect(result.succeeded)
    #expect(try fixture.calls("up").isEmpty)
    #expect(result.err.contains("acme.0 has no devcontainer config, so it's a plain worktree"))
  }

  @Test("start unlocks the slot when the container fails to start")
  func startContainerFailure() async throws {
    try await fixture.addDevcontainer()
    try fixture.write("\(fixture.bin)/fail-up")

    let result = try await fixture.spinoff("start")

    #expect(result.exitCode == 125)
    #expect(result.out.isEmpty)
    #expect(try await fixture.lockReason(slot) == nil)
  }

  @Test("start unlocks the slot and shows the log when bin/setup fails")
  func startSetupFailure() async throws {
    try await fixture.addDevcontainer(setup: "echo 'migration failed'; exit 1")

    let result = try await fixture.spinoff("start")

    #expect(result.exitCode == 1)
    #expect(result.err.contains("migration failed\nspinoff: bin/setup failed in acme.0\n"))
    #expect(try await fixture.lockReason(slot) == nil)
  }

  @Test("release stops the running containers of the slot")
  func releaseStops() async throws {
    try await fixture.addDevcontainer()
    _ = try await fixture.spinoff("start")

    let result = try await fixture.spinoff("release", in: slot)

    #expect(result.succeeded)
    #expect(try fixture.calls("docker") == ["docker compose -p acme0_devcontainer stop"])
    #expect(result.err.contains("spinoff: stopped the container of acme.0"))
    #expect(try await fixture.lockReason(slot) == nil)
  }

  @Test("release leaves a stopped container alone")
  func releaseStopped() async throws {
    try await fixture.addDevcontainer()
    _ = try await fixture.spinoff("start")
    try FileManager.default.removeItem(atPath: "\(fixture.bin)/running")

    #expect(try await fixture.spinoff("release", in: slot).succeeded)
    #expect(try fixture.calls("docker").isEmpty)
  }

  @Test("open hands the slot to VS Code's own devcontainer CLI")
  func open() async throws {
    try await fixture.addDevcontainer()
    _ = try await fixture.spinoff("start")
    try fixture.script(
      "\(fixture.home)/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/cli-bin/devcontainer",
      #"echo "vscode $*" >> \#(fixture.bin)/calls.log"#)

    let result = try await fixture.spinoff("open", in: slot)

    #expect(result.succeeded)
    #expect(try fixture.calls("vscode") == ["vscode open \(slot)"])
  }

  @Test("open points to doctor without the VS Code extension")
  func openWithoutVSCode() async throws {
    try await fixture.addDevcontainer()
    _ = try await fixture.spinoff("start")

    let result = try await fixture.spinoff("open", in: slot)

    #expect(result.exitCode == 125)
    #expect(
      result.err
        == "spinoff: the VS Code Dev Containers extension isn't installed; run `spinoff doctor`\n")
  }

  @Test("open refuses outside a slot")
  func openOutsideSlot() async throws {
    let result = try await fixture.spinoff("open")

    #expect(result.exitCode == 1)
    #expect(result.err == "spinoff: not inside a slot; `spinoff start` hands one out\n")
  }
}
