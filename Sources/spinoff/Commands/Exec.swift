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
    let slot = try await repo.requireCurrentSlot()
    try slot.requireContainerConfig()

    let cli = try await DevcontainerCLI.require()
    try await slot.container.start(with: cli)
    slot.container.exec(command, in: repo.prefix, with: cli)
  }
}
