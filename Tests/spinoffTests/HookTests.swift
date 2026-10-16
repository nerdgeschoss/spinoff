import Foundation
import Testing

@testable import spinoff

@Suite("Claude Code hooks")
struct HookTests {
  let fixture: Fixture
  var slot: String { fixture.slotPath(0) }

  init() async throws {
    fixture = try await Fixture()
  }

  func hook(_ name: String, _ input: [String: Any], in directory: String? = nil) async throws
    -> CommandResult
  {
    let json = try JSONSerialization.data(withJSONObject: input)
    return try await fixture.spinoff(
      ["hook", name], in: directory, input: String(decoding: json, as: UTF8.self))
  }

  func preToolUse(_ command: String, in directory: String) async throws -> CommandResult {
    try await hook(
      "pre-tool-use",
      [
        "session_id": "abc123", "cwd": directory, "hook_event_name": "PreToolUse",
        "tool_name": "Bash", "tool_input": ["command": command, "description": "test"],
      ])
  }

  @Test("worktree-create hands out a slot locked for the session and prints only its path")
  func worktreeCreate() async throws {
    let result = try await hook(
      "worktree-create",
      [
        "session_id": "abc123", "cwd": fixture.main, "hook_event_name": "WorktreeCreate",
        "name": "bold-oak-a3f2",
      ])

    #expect(result.succeeded)
    #expect(result.out == "\(slot)\n")
    #expect(try await fixture.lockReason(slot) == "claude: abc123")
  }

  @Test("worktree-remove releases the slot")
  func worktreeRemove() async throws {
    _ = try await fixture.spinoff("start", "--reason", "claude: abc123")

    let result = try await hook(
      "worktree-remove", ["hook_event_name": "WorktreeRemove", "worktree_path": slot])

    #expect(result.succeeded)
    #expect(try await fixture.lockReason(slot) == nil)
  }

  @Test("worktree-remove keeps a slot that holds work, so Claude Code keeps the directory")
  func worktreeRemoveWithWork() async throws {
    _ = try await fixture.spinoff("start", "--reason", "claude: abc123")
    try fixture.write("\(slot)/wip.txt")

    let result = try await hook(
      "worktree-remove", ["hook_event_name": "WorktreeRemove", "worktree_path": slot])

    #expect(result.exitCode == 1)
    #expect(result.err.contains("acme.0 has uncommitted changes"))
    #expect(try await fixture.lockReason(slot) == "claude: abc123")
  }

  @Test("pre-tool-use blocks toolchain commands in a slot with a hint")
  func blocksInSlot() async throws {
    _ = try await fixture.spinoff("start")

    let result = try await preToolUse("cd app && bundle exec rspec", in: slot)

    #expect(result.exitCode == 2)
    #expect(result.err.contains("Run it as `spinoff exec bundle …` instead"))
  }

  @Test("pre-tool-use lets spinoff exec and other commands through")
  func allowsInSlot() async throws {
    _ = try await fixture.spinoff("start")

    for command in ["spinoff exec bin/rails test", "git status", "ls bin/"] {
      let result = try await preToolUse(command, in: slot)
      #expect(result.exitCode == 0, "\(command)")
      #expect(result.err.isEmpty, "\(command)")
    }
  }

  @Test("pre-tool-use doesn't block anything outside a slot")
  func allowsOutsideSlot() async throws {
    #expect(try await preToolUse("bundle install", in: fixture.main).exitCode == 0)
    #expect(try await preToolUse("npm test", in: fixture.root).exitCode == 0)
  }

  @Test(
    "finds host toolchain commands in command lines",
    arguments: [
      ("bin/rails test", "bin/rails"),
      ("./bin/dev", "./bin/dev"),
      ("cd app && npm test", "npm"),
      ("RAILS_ENV=test bundle exec rspec", "bundle"),
      ("echo $(node -v)", "node"),
      ("git ls-files | xargs rubocop", "rubocop"),
      ("time yarn build", "yarn"),
      ("/usr/bin/ruby -v", "/usr/bin/ruby"),
    ])
  func blockedCommands(commandLine: String, blocked: String) {
    #expect(HostCommands.firstBlocked(in: commandLine) == blocked)
  }

  @Test(
    "ignores command lines without host toolchain commands",
    arguments: [
      "spinoff exec bin/rails test",
      "spinoff exec bundle install && spinoff exec bin/rails db:migrate",
      #"git commit -m "run bundle; rake""#,
      "echo 'npm test'",
      "ls bin/",
      "grep -r bundle .",
    ])
  func allowedCommands(commandLine: String) {
    #expect(HostCommands.firstBlocked(in: commandLine) == nil)
  }
}
