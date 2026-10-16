import Foundation

struct Slot: Sendable {
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

  /// Describes the work that would be lost by resetting this slot, or nil if there is none.
  func work() async throws -> String? {
    if try await !Git.run(["status", "--porcelain"], in: path).isEmpty {
      return "uncommitted changes"
    }
    if try await Git.run(["rev-list", "-n1", "HEAD", "--not", "--remotes"], in: path).isEmpty {
      return nil
    }
    return branch.map { "unpushed commits on \($0)" }
      ?? "detached commits that aren't on any remote"
  }

  func holdsWork() async throws -> Bool {
    try await work() != nil
  }

  func lock(reason: String) async throws -> Bool {
    try await Git.capture(["worktree", "lock", "--reason", reason, path], in: path).succeeded
  }

  func unlock() async throws {
    try await Git.run(["worktree", "unlock", path], in: path)
  }

  func checkout(_ commit: String) async throws {
    try await Git.run(["checkout", "--quiet", "--force", "--detach", commit], in: path)
  }

  func clean() async throws {
    try await Git.run(["clean", "-fdq"], in: path)
  }
}
