import ArgumentParser
import Foundation

struct Start: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Claim a free slot of the current repo at a starting point and print its path.",
    discussion: """
      The slot's container is brought up and the project's bin/setup runs in it. Only the path \
      goes to stdout; everything else goes to stderr.
      """
  )

  @Argument(help: "Commit, branch or tag to check out (default: origin's default branch).")
  var startingPoint: String?

  @Option(help: "Lock reason, shown in `git worktree list`.")
  var reason = "manual"

  func run() async throws {
    let slot = try await Self.start(in: nil, startingPoint: startingPoint, reason: reason)
    print(slot.path)
  }

  static func start(in directory: String?, startingPoint: String?, reason: String) async throws
    -> Slot
  {
    let repo = try await Repo.current(in: directory ?? FileManager.default.currentDirectoryPath)
    try await repo.fetch()
    let commit: String
    if let startingPoint {
      commit = try await repo.resolve(startingPoint)
    } else {
      commit = try await repo.resolve(repo.defaultBranch())
    }

    let (slot, created) = try await repo.claim(reason: reason, commit: commit)
    do {
      if !created { try await slot.checkout(commit) }
      warn("spinoff: \(created ? "created" : "reusing") \(slot.name) at \(commit.prefix(7))")
      try await prepare(slot)
    } catch {
      try? await slot.unlock()
      throw error
    }
    return slot
  }

  /// Brings the slot's container up and runs bin/setup in it; slots without a devcontainer config stay plain worktrees.
  private static func prepare(_ slot: Slot) async throws {
    guard Container.config(in: slot.path) != nil else {
      warn("spinoff: \(slot.name) has no devcontainer config, so it's a plain worktree")
      return
    }
    let devcontainer = try await Toolchain.devcontainer(offerInstall: true)
    try await Container.ensureRunning(slot.path, devcontainer: devcontainer)
    try await Container.setUp(slot.path, devcontainer: devcontainer)
  }
}
