import Foundation
import Testing

@Suite("spinoff release")
struct ReleaseTests {
  let fixture: Fixture
  let slot: String

  init() async throws {
    fixture = try await Fixture()
    slot = fixture.slotPath(0)
    _ = try await fixture.spinoff("start")
  }

  @Test("unlocks the slot and detaches it to the latest default branch")
  func releases() async throws {
    let latest = try await fixture.commit("latest")
    try await fixture.git("push", "--quiet")

    let result = try await fixture.spinoff("release", in: slot)

    #expect(result.succeeded)
    #expect(result.out.isEmpty)
    #expect(try await fixture.lockReason(slot) == nil)
    #expect(try await fixture.head(slot) == latest)
    #expect(try await fixture.isDetached(slot))
  }

  @Test("keeps ignored files")
  func keepsIgnoredFiles() async throws {
    try fixture.write("\(slot)/.env", "SECRET=1")

    _ = try await fixture.spinoff("release", in: slot)

    #expect(fixture.exists("\(slot)/.env"))
  }

  @Test("aborts on uncommitted changes")
  func uncommittedChanges() async throws {
    try fixture.write("\(slot)/wip.txt")

    let result = try await fixture.spinoff("release", in: slot)

    #expect(result.exitCode == 1)
    #expect(result.err.contains("acme.0 has uncommitted changes"))
    #expect(try await fixture.lockReason(slot) == "manual")
  }

  @Test("aborts on unpushed commits on a branch")
  func unpushedCommits() async throws {
    try await fixture.git("switch", "--quiet", "-c", "feat", in: slot)
    try await fixture.commit("feat", in: slot)

    let result = try await fixture.spinoff("release", in: slot)

    #expect(result.err.contains("unpushed commits on feat"))
    #expect(try await fixture.lockReason(slot) == "manual")
  }

  @Test("aborts on detached commits that aren't on any remote")
  func orphanedCommits() async throws {
    try await fixture.commit("orphan", in: slot)

    let result = try await fixture.spinoff("release", in: slot)

    #expect(result.err.contains("detached commits that aren't on any remote"))
    #expect(try await fixture.lockReason(slot) == "manual")
  }

  @Test("discards work with --force but leaves branches alone")
  func force() async throws {
    try await fixture.git("switch", "--quiet", "-c", "feat", in: slot)
    try await fixture.commit("feat", in: slot)
    try fixture.write("\(slot)/wip.txt")

    let result = try await fixture.spinoff("release", "--force", in: slot)

    #expect(result.succeeded)
    #expect(!fixture.exists("\(slot)/wip.txt"))
    #expect(try await fixture.head(slot) == fixture.head(fixture.main))
    #expect(try await !fixture.git("branch", "--list", "feat").isEmpty)
    #expect(try await fixture.lockReason(slot) == nil)
  }

  @Test("releases another slot with --slot from the main checkout")
  func slotFromMain() async throws {
    #expect(try await fixture.spinoff("release", "--slot", "0").succeeded)
    #expect(try await fixture.lockReason(slot) == nil)
  }

  @Test("releases another slot with --slot from a different slot")
  func slotFromOtherSlot() async throws {
    _ = try await fixture.spinoff("start")

    _ = try await fixture.spinoff("release", "--slot", "0", in: fixture.slotPath(1))

    #expect(try await fixture.lockReason(slot) == nil)
    #expect(try await fixture.lockReason(fixture.slotPath(1)) == "manual")
  }

  @Test("refuses an unknown slot")
  func unknownSlot() async throws {
    let result = try await fixture.spinoff("release", "--slot", "7")

    #expect(result.err == "spinoff: acme.7 is not a slot of acme\n")
  }

  @Test("refuses outside a slot without --slot")
  func outsideSlot() async throws {
    let result = try await fixture.spinoff("release")

    #expect(result.exitCode == 1)
    #expect(result.err == "spinoff: not inside a slot; use --slot <n>\n")
  }
}
