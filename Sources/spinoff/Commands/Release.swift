import ArgumentParser
import Foundation

struct Release: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Reset a slot to origin's default branch, stop its container and hand it back."
  )

  @Option(help: "Release <project>.<n> instead of the current slot.")
  var slot: Int?

  @Flag(help: "Discard uncommitted changes and unpushed commits.")
  var force = false

  func run() async throws {
    try await Self.release(in: nil, number: slot, force: force)
  }

  static func release(in directory: String?, number: Int?, force: Bool) async throws {
    let repo = try await Repo.current(in: directory ?? FileManager.default.currentDirectoryPath)
    let target = try await targetSlot(in: repo, number: number)
    if !force, let work = try await target.work() {
      throw SpinoffError("\(target.name) has \(work); push or discard them, or use --force")
    }

    try await repo.fetch()
    try await target.checkout(repo.defaultBranch())
    try await target.clean()
    if try await Container.stopIfRunning(target.path) {
      warn("spinoff: stopped the container of \(target.name)")
    }
    if target.isLocked { try await target.unlock() }
    warn("spinoff: released \(target.name)")
  }

  private static func targetSlot(in repo: Repo, number: Int?) async throws -> Slot {
    if let number {
      guard let found = try await repo.slot(number) else {
        throw SpinoffError("\(repo.project).\(number) is not a slot of \(repo.project)")
      }
      return found
    }
    guard let found = try await repo.currentSlot() else {
      throw SpinoffError("not inside a slot; use --slot <n>")
    }
    return found
  }
}
