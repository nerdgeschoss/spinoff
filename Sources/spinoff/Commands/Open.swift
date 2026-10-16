import ArgumentParser

struct Open: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Open the current slot in VS Code, directly inside its container."
  )

  func run() async throws {
    let slot = try await Repo.current().requireCurrentSlot()
    try slot.requireContainerConfig()
    // Only the extension's copy of the CLI has `open`; it attaches to the container spinoff started.
    guard let vscode = DevcontainerCLI.vscode() else {
      throw SpinoffError.unavailable(
        "the VS Code Dev Containers extension isn't installed; run `spinoff doctor`")
    }
    let result = try await vscode.run(["open", slot.path])
    guard result.succeeded else {
      warn(Shell.tail(result.log))
      throw SpinoffError.unavailable("VS Code couldn't open \(slot.name)")
    }
  }
}
