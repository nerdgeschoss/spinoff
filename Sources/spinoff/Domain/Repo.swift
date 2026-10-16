import Foundation

/// The git repository you're standing in: its main checkout, and its slots as siblings of it.
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
    guard result.succeeded else { throw SpinoffError.failed("not inside a git repository") }

    let lines = result.output.components(separatedBy: "\n")
    let common = lines[2] as NSString
    guard common.lastPathComponent == ".git" else {
      throw SpinoffError.failed("bare repositories aren't supported")
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

  /// The slot you're standing in; outside one, fails with `hint` on what to do instead.
  func requireCurrentSlot(hint: String = "`spinoff start` hands one out") async throws -> Slot {
    guard let slot = try await currentSlot() else {
      throw SpinoffError.failed("not inside a slot; \(hint)")
    }
    return slot
  }

  func requireSlot(_ n: Int) async throws -> Slot {
    guard let slot = try await slot(n) else {
      throw SpinoffError.failed("\(project).\(n) is not a slot of \(project)")
    }
    return slot
  }

  /// Hands out a free slot (or a new one) at `startingPoint`, detached, with its container up and set up.
  func start(at startingPoint: String?, reason: String) async throws -> Slot {
    try await fetch()
    let commit: String
    if let startingPoint {
      commit = try await resolve(startingPoint)
    } else {
      commit = try await resolve(defaultBranch())
    }

    let (slot, created) = try await claim(reason: reason, commit: commit)
    do {
      if !created { try await slot.checkout(commit) }
      warn("spinoff: \(created ? "created" : "reusing") \(slot.name) at \(commit.prefix(7))")
      try await slot.prepare()
    } catch {
      try? await slot.unlock()
      throw error
    }
    return slot
  }

  /// Resets `slot` to the latest default branch, stops its container and unlocks it. Unless `force` is set,
  /// fails when that would lose work.
  func release(_ slot: Slot, force: Bool) async throws {
    if !force, let work = try await slot.work() {
      throw SpinoffError.failed("\(slot.name) has \(work); push or discard them, or use --force")
    }
    try await fetch()
    try await slot.checkout(defaultBranch())
    try await slot.clean()
    if try await slot.container.stopIfRunning() {
      warn("spinoff: stopped the container of \(slot.name)")
    }
    // Unlocking last keeps a parallel start from claiming a slot that's still being torn down.
    if slot.isLocked { try await slot.unlock() }
    warn("spinoff: released \(slot.name)")
  }

  func fetch() async throws {
    try await Git.run(["fetch", "--quiet", "origin"], in: main)
  }

  func defaultBranch() async throws -> String {
    let result = try await Git.capture(
      ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: main)
    guard result.succeeded else {
      throw SpinoffError.failed(
        "origin has no default branch; run `git remote set-head origin --auto`")
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func resolve(_ startingPoint: String) async throws -> String {
    for ref in [startingPoint, "origin/\(startingPoint)"] {
      let result = try await Git.capture(
        ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: main)
      if result.succeeded { return result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    throw SpinoffError.failed("unknown starting point: \(startingPoint)")
  }

  /// Locks a free slot, or creates a new one. Returns the slot and whether it was created.
  private func claim(reason: String, commit: String) async throws -> (slot: Slot, created: Bool) {
    try await withDirectoryLock(main) {
      let slots = try await slots()
      for slot in slots where !slot.isLocked && FileManager.default.fileExists(atPath: slot.path) {
        guard try await slot.lock(reason: reason) else { continue }
        if try await slot.work() == nil { return (slot, false) }
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
      throw SpinoffError.failed("git didn't create \(slotPath(n))")
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
