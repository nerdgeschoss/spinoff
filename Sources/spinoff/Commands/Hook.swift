import ArgumentParser
import Foundation

/// The Claude Code plugin's hooks. Each reads the hook's JSON input from stdin.
struct Hook: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Claude Code hooks; they read the hook's JSON input from stdin.",
    shouldDisplay: false,
    subcommands: [WorktreeCreate.self, WorktreeRemove.self, PreToolUse.self]
  )

  static func input<Input: Decodable>(_ type: Input.Type) throws -> Input {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do {
      return try decoder.decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
    } catch {
      throw SpinoffError.failed("can't read the hook input: \(error)")
    }
  }

  struct WorktreeCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "worktree-create", abstract: "Hand out a slot to a Claude Code session.")

    struct Input: Decodable {
      var sessionId: String
      var cwd: String
    }

    func run() async throws {
      let input = try Hook.input(Input.self)
      let slot = try await Repo.current(in: input.cwd)
        .start(at: nil, reason: "claude: \(input.sessionId)")
      print(slot.path)
    }
  }

  struct WorktreeRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "worktree-remove", abstract: "Release a Claude Code session's slot.")

    struct Input: Decodable {
      var worktreePath: String
    }

    func run() async throws {
      let repo = try await Repo.current(in: Hook.input(Input.self).worktreePath)
      try await repo.release(repo.requireCurrentSlot(), force: false)
    }
  }

  struct PreToolUse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "pre-tool-use",
      abstract: "Block toolchain commands in a slot that don't go through `spinoff exec`.")

    struct Input: Decodable {
      struct ToolInput: Decodable {
        var command: String?
      }

      var cwd: String
      var toolInput: ToolInput
    }

    func run() async throws {
      let input = try Hook.input(Input.self)
      guard let command = input.toolInput.command,
        let blocked = HostCommands.firstBlocked(in: command),
        let repo = try? await Repo.current(in: input.cwd),
        try await repo.currentSlot() != nil
      else { return }

      warn(
        "`\(blocked)` would run on the host, but this slot's toolchain lives in its container. "
          + "Run it as `spinoff exec \(blocked) …` instead; it keeps the working directory, "
          + "arguments and exit code.")
      throw ExitCode(2)
    }
  }
}
