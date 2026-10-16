import ArgumentParser

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
    print(try await Repo.current().start(at: startingPoint, reason: reason).path)
  }
}
