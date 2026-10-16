import ArgumentParser

struct Release: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Reset a slot to origin's default branch, stop its container and hand it back."
  )

  @Option(help: "Release <project>.<n> instead of the current slot.")
  var slot: Int?

  @Flag(help: "Discard uncommitted changes and unpushed commits.")
  var force = false

  func run() async throws {
    let repo = try await Repo.current()
    let target =
      if let slot {
        try await repo.requireSlot(slot)
      } else {
        try await repo.requireCurrentSlot(hint: "use --slot <n>")
      }
    try await repo.release(target, force: force)
  }
}
