import Foundation

struct Repo: Sendable {
  var main: String
  var root: String
  var prefix: String

  static func current(in directory: String = FileManager.default.currentDirectoryPath)
    async throws -> Repo
  {
    let result = try await Git.capture(
      [
        "rev-parse", "--path-format=absolute", "--show-toplevel", "--show-prefix",
        "--git-common-dir",
      ],
      in: directory
    )
    guard result.succeeded else { throw SpinoffError("not inside a git repository") }

    let lines = result.output.components(separatedBy: "\n")
    let common = lines[2] as NSString
    guard common.lastPathComponent == ".git" else {
      throw SpinoffError("bare repositories aren't supported")
    }
    return Repo(main: common.deletingLastPathComponent, root: lines[0], prefix: lines[1])
  }

  var project: String { (main as NSString).lastPathComponent }

  func slotPath(_ n: Int) -> String {
    slotPathPrefix + String(n)
  }

  func slots() async throws -> [Slot] {
    try await worktrees().compactMap(slot(from:)).sorted { $0.n < $1.n }
  }

  func slot(_ n: Int) async throws -> Slot? {
    try await slots().first { $0.n == n }
  }

  func currentSlot() async throws -> Slot? {
    try await slots().first { $0.path == root }
  }

  func fetch() async throws {
    try await Git.run(["fetch", "--quiet", "origin"], in: main)
  }

  func defaultBranch() async throws -> String {
    let result = try await Git.capture(
      ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: main)
    guard result.succeeded else {
      throw SpinoffError("origin has no default branch; run `git remote set-head origin --auto`")
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func resolve(_ startingPoint: String) async throws -> String {
    for ref in [startingPoint, "origin/\(startingPoint)"] {
      let result = try await Git.capture(
        ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: main)
      if result.succeeded { return result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    throw SpinoffError("unknown starting point: \(startingPoint)")
  }

  /// Locks a free slot, or creates a new one. Returns the slot and whether it was created.
  func claim(reason: String, commit: String) async throws -> (slot: Slot, created: Bool) {
    try await withDirectoryLock(main) {
      let slots = try await slots()
      for slot in slots where !slot.isLocked && FileManager.default.fileExists(atPath: slot.path) {
        guard try await slot.lock(reason: reason) else { continue }
        if try await !slot.holdsWork() { return (slot, false) }
        try await slot.unlock()
      }
      return (try await create(reason: reason, commit: commit, taken: Set(slots.map(\.n))), true)
    }
  }

  private var slotPathPrefix: String {
    ((main as NSString).deletingLastPathComponent as NSString).appendingPathComponent(
      "\(project).")
  }

  private func worktrees() async throws -> [[String: String]] {
    try await Git.run(["worktree", "list", "--porcelain", "-z"], in: main)
      .components(separatedBy: "\0\0")
      .filter { !$0.isEmpty }
      .map { record in
        Dictionary(
          record.split(separator: "\0").map { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
          },
          uniquingKeysWith: { first, _ in first }
        )
      }
  }

  private func slot(from worktree: [String: String]) -> Slot? {
    guard let path = worktree["worktree"], path.hasPrefix(slotPathPrefix),
      let n = Int(path.dropFirst(slotPathPrefix.count)), slotPath(n) == path
    else { return nil }

    return Slot(
      path: path,
      n: n,
      head: worktree["HEAD"] ?? "",
      branch: worktree["branch"].map { String($0.trimmingPrefix("refs/heads/")) },
      lockReason: worktree["locked"]
    )
  }

  private func create(reason: String, commit: String, taken: Set<Int>) async throws -> Slot {
    var n = 0
    while taken.contains(n) || FileManager.default.fileExists(atPath: slotPath(n)) { n += 1 }
    try await Git.run(
      [
        "worktree", "add", "--quiet", "--detach", "--lock", "--reason", reason, "--relative-paths",
        slotPath(n), commit,
      ],
      in: main
    )
    try await copyIncludedFiles(to: slotPath(n))
    guard let slot = try await slot(n) else {
      throw SpinoffError("git didn't create \(slotPath(n))")
    }
    return slot
  }

  /// Copies files that match .worktreeinclude and are gitignored, like Claude Code does.
  private func copyIncludedFiles(to target: String) async throws {
    guard FileManager.default.fileExists(atPath: "\(main)/.worktreeinclude") else { return }

    let candidates = try await Git.run(
      ["ls-files", "-z", "--others", "--ignored", "--exclude-from=.worktreeinclude"], in: main)
    guard !candidates.isEmpty else { return }

    let ignored = try await Git.capture(
      ["check-ignore", "-z", "--stdin"], in: main, input: candidates
    ).output
    let fileManager = FileManager.default
    for file in ignored.split(separator: "\0").map(String.init) {
      let source = "\(main)/\(file)"
      if (try? fileManager.destinationOfSymbolicLink(atPath: source)) != nil { continue }

      let destination = "\(target)/\(file)"
      try fileManager.createDirectory(
        atPath: (destination as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
      try fileManager.copyItem(atPath: source, toPath: destination)
    }
  }
}
