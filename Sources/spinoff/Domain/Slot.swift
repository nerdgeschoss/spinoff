import Foundation

/// A linked worktree `<project>.<n>` next to the main checkout. Taken means locked; a slot that holds work is
/// never handed out or reset, whoever forgot to lock it.
struct Slot: Sendable {
  /// What resetting the slot would lose.
  enum Work: Equatable, CustomStringConvertible {
    case uncommittedChanges
    case unpushedCommits(branch: String)
    case detachedCommits

    var description: String {
      switch self {
      case .uncommittedChanges: "uncommitted changes"
      case .unpushedCommits(let branch): "unpushed commits on \(branch)"
      case .detachedCommits: "detached commits that aren't on any remote"
      }
    }
  }

  var path: String
  var n: Int
  var head: String
  var branch: String?
  var lockReason: String?

  var name: String { (path as NSString).lastPathComponent }

  var isLocked: Bool { lockReason != nil }

  var status: String {
    guard let lockReason else { return "free" }
    return lockReason.isEmpty ? "locked" : lockReason
  }

  var container: Container { Container(folder: path) }

  func work() async throws -> Work? {
    if try await !Git.run(["status", "--porcelain"], in: path).isEmpty {
      return .uncommittedChanges
    }
    if try await Git.run(["rev-list", "-n1", "HEAD", "--not", "--remotes"], in: path).isEmpty {
      return nil
    }
    return branch.map { .unpushedCommits(branch: $0) } ?? .detachedCommits
  }

  func requireContainerConfig() throws {
    guard Container.config(in: path) != nil else {
      throw SpinoffError.unavailable("\(name) has no devcontainer config; run `spinoff doctor`")
    }
  }

  /// Brings the container up and runs bin/setup in it; without a devcontainer config the slot stays a plain worktree.
  func prepare() async throws {
    guard Container.config(in: path) != nil else {
      warn("spinoff: \(name) has no devcontainer config, so it's a plain worktree")
      return
    }
    let cli = try await DevcontainerCLI.require()
    try await container.start(with: cli)
    try await container.setUp(with: cli)
  }

  /// Takes the slot; fails if someone else holds it.
  func lock(reason: String) async throws -> Bool {
    try await Git.capture(["worktree", "lock", "--reason", reason, path], in: path).succeeded
  }

  func unlock() async throws {
    try await Git.run(["worktree", "unlock", path], in: path)
  }

  func checkout(_ commit: String) async throws {
    try await Git.run(["checkout", "--quiet", "--force", "--detach", commit], in: path)
  }

  /// Removes untracked files but keeps ignored ones (gems, node_modules, secrets).
  func clean() async throws {
    try await Git.run(["clean", "-fdq"], in: path)
  }
}
