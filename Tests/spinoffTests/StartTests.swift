import Foundation
import Testing

@Suite("spinoff start")
struct StartTests {
  let fixture: Fixture

  init() async throws {
    fixture = try await Fixture()
  }

  @Test("creates the first slot, locked and detached at the default branch")
  func createsFirstSlot() async throws {
    let result = try await fixture.spinoff("start")

    #expect(result.succeeded)
    #expect(result.out == "\(fixture.slotPath(0))\n")
    #expect(try await fixture.lockReason(fixture.slotPath(0)) == "manual")
    #expect(try await fixture.head(fixture.slotPath(0)) == fixture.head(fixture.main))
    #expect(try await fixture.isDetached(fixture.slotPath(0)))
  }

  @Test("links the slot to the main checkout with relative paths")
  func relativePaths() async throws {
    _ = try await fixture.spinoff("start")

    #expect(
      try fixture.read("\(fixture.slotPath(0))/.git") == "gitdir: ../acme/.git/worktrees/acme.0\n")
  }

  @Test("creates the next slot when all are taken")
  func nextSlot() async throws {
    _ = try await fixture.spinoff("start")

    #expect(try await fixture.spinoff("start").out == "\(fixture.slotPath(1))\n")
  }

  @Test("uses the given lock reason")
  func lockReason() async throws {
    _ = try await fixture.spinoff("start", "--reason", "claude: abc123")

    #expect(try await fixture.lockReason(fixture.slotPath(0)) == "claude: abc123")
  }

  @Test("checks out a starting point that only exists on origin, without creating a branch")
  func remoteStartingPoint() async throws {
    try await fixture.git("switch", "--quiet", "-c", "feature")
    let feature = try await fixture.commit("feature")
    try await fixture.git("push", "--quiet", "origin", "feature")
    try await fixture.git("switch", "--quiet", "main")
    try await fixture.git("branch", "--quiet", "-D", "feature")

    _ = try await fixture.spinoff("start", "feature")

    #expect(try await fixture.head(fixture.slotPath(0)) == feature)
    #expect(try await fixture.isDetached(fixture.slotPath(0)))
    #expect(try await fixture.git("branch", "--list", "feature").isEmpty)
  }

  @Test("refuses an unknown starting point")
  func unknownStartingPoint() async throws {
    let result = try await fixture.spinoff("start", "nope")

    #expect(!result.succeeded)
    #expect(result.err.contains("unknown starting point: nope"))
    #expect(!fixture.exists(fixture.slotPath(0)))
  }

  @Test("reuses a released slot at the new starting point")
  func reusesReleasedSlot() async throws {
    _ = try await fixture.spinoff("start")
    _ = try await fixture.spinoff("release", in: fixture.slotPath(0))
    let latest = try await fixture.commit("latest")
    try await fixture.git("push", "--quiet")

    #expect(try await fixture.spinoff("start").out == "\(fixture.slotPath(0))\n")
    #expect(try await fixture.head(fixture.slotPath(0)) == latest)
    #expect(try await fixture.lockReason(fixture.slotPath(0)) == "manual")
  }

  @Test("skips an unlocked slot that still holds work")
  func skipsSlotWithWork() async throws {
    _ = try await fixture.spinoff("start")
    try fixture.write("\(fixture.slotPath(0))/wip.txt")
    try await fixture.git("worktree", "unlock", fixture.slotPath(0))

    #expect(try await fixture.spinoff("start").out == "\(fixture.slotPath(1))\n")
    #expect(try await fixture.lockReason(fixture.slotPath(0)) == nil)
  }

  @Test("hands out different slots to parallel starts")
  func parallelStarts() async throws {
    async let first = fixture.spinoff("start")
    async let second = fixture.spinoff("start")
    async let third = fixture.spinoff("start")
    let results = try await [first, second, third]

    #expect(results.allSatisfy { $0.succeeded })
    #expect(results.map(\.out).sorted() == [0, 1, 2].map { "\(fixture.slotPath($0))\n" })
  }

  @Test("copies gitignored files listed in .worktreeinclude into new slots")
  func worktreeInclude() async throws {
    try fixture.write("\(fixture.main)/.worktreeinclude", ".env\nconfig/master.key\nnotes.txt\n")
    try await fixture.commit("include")
    try fixture.write("\(fixture.main)/.env", "SECRET=1")
    try fixture.write("\(fixture.main)/config/master.key", "key")
    try fixture.write("\(fixture.main)/node_modules/left-pad.js")
    try fixture.write("\(fixture.main)/notes.txt")

    _ = try await fixture.spinoff("start")

    let slot = fixture.slotPath(0)
    #expect(try fixture.read("\(slot)/.env") == "SECRET=1")
    #expect(try fixture.read("\(slot)/config/master.key") == "key")
    #expect(!fixture.exists("\(slot)/node_modules"))
    #expect(!fixture.exists("\(slot)/notes.txt"))
  }

  @Test("works from inside a slot")
  func fromInsideSlot() async throws {
    _ = try await fixture.spinoff("start")

    #expect(
      try await fixture.spinoff("start", in: fixture.slotPath(0)).out == "\(fixture.slotPath(1))\n")
  }

  @Test("refuses outside a git repository")
  func outsideRepository() async throws {
    let result = try await fixture.spinoff("start", in: fixture.root)

    #expect(result.exitCode == 1)
    #expect(result.err == "spinoff: not inside a git repository\n")
  }
}
