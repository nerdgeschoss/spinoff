import Foundation
import Testing

@Suite("spinoff list")
struct ListTests {
  let fixture: Fixture

  init() async throws {
    fixture = try await Fixture()
  }

  @Test(
    "lists each slot with its HEAD, branch and lock, without a container column if Docker is missing"
  )
  func listsSlots() async throws {
    _ = try await fixture.spinoff("start", "--reason", "claude: abc123")
    _ = try await fixture.spinoff("start")
    _ = try await fixture.spinoff("release", "--slot", "1")
    try await fixture.git("switch", "--quiet", "-c", "feat", in: fixture.slotPath(1))
    let short = try await fixture.head(fixture.main).prefix(7)

    let result = try await fixture.spinoff("list")

    #expect(
      result.out == """
        acme.0  \(short)  detached  claude: abc123
        acme.1  \(short)  feat      free

        """)
  }

  @Test("prints nothing without slots")
  func empty() async throws {
    #expect(try await fixture.spinoff("list").out.isEmpty)
  }
}
