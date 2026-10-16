import ArgumentParser
import Foundation

@main
struct Spinoff: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "spinoff",
    abstract: "Spin off development environments as git worktrees with their own devcontainer.",
    version: version,
    subcommands: [
      Start.self, Release.self, Exec.self, Open.self, List.self, Doctor.self, Hook.self,
    ]
  )

  static func main() async {
    // Docker Desktop otherwise appends "What's next" ads to the output of commands run in containers.
    setenv("DOCKER_CLI_HINTS", "false", 0)
    do {
      var command = try parseAsRoot()
      if var command = command as? AsyncParsableCommand {
        try await command.run()
      } else {
        try command.run()
      }
    } catch let error as SpinoffError {
      warn("spinoff: \(error.message)")
      exit(withError: ExitCode(error.exitCode))
    } catch {
      exit(withError: error)
    }
  }
}
