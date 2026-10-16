import ArgumentParser

struct Open: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Open the current slot in VS Code, directly inside its container."
  )

  func run() async throws {
    let repo = try await Repo.current()
    guard let slot = try await repo.currentSlot() else {
      throw SpinoffError("not inside a slot; `spinoff start` hands one out")
    }
    guard Container.config(in: slot.path) != nil else {
      throw SpinoffError(
        "\(slot.name) has no devcontainer config; run `spinoff doctor`", exitCode: 125)
    }
    // Only the extension's copy of the CLI has `open`; it attaches to the container spinoff started.
    guard let vscode = Toolchain.vscodeDevcontainer() else {
      throw SpinoffError(
        "the VS Code Dev Containers extension isn't installed; run `spinoff doctor`", exitCode: 125)
    }
    let result = try await Shell.captureLog(vscode, ["open", slot.path])
    guard result.succeeded else {
      warn(Shell.tail(result.log))
      throw SpinoffError("VS Code couldn't open \(slot.name)", exitCode: 125)
    }
  }
}
