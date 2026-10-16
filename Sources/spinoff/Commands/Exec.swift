import ArgumentParser

struct Exec: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run a command inside the current slot's container.",
    discussion: """
      The command runs in the same subdirectory it was called from. stdin, stdout, stderr and \
      the exit code are the command's own; spinoff's own failures exit with 125.
      """
  )

  @Argument(parsing: .captureForPassthrough, help: "The command and its arguments.")
  var command: [String] = []

  func validate() throws {
    if command.isEmpty { throw ValidationError("Missing the command to run.") }
  }

  func run() async throws {
    let repo = try await Repo.current()
    guard let slot = try await repo.currentSlot() else {
      throw SpinoffError("not inside a slot; `spinoff start` hands one out")
    }
    guard Container.config(in: slot.path) != nil else {
      throw SpinoffError(
        "\(slot.name) has no devcontainer config; run `spinoff doctor`", exitCode: 125)
    }

    let devcontainer = try await Toolchain.devcontainer(offerInstall: true)
    try await Container.ensureRunning(slot.path, devcontainer: devcontainer)
    Container.exec(
      devcontainer: devcontainer, folder: slot.path, subdirectory: repo.prefix, command: command)
  }
}
