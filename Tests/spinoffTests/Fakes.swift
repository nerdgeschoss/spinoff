import Foundation

/// A fake devcontainer CLI and docker in the fixture's `bin`: "containers" run commands right in
/// the workspace folder, their state lives in marker files, and every call is logged to `bin/calls.log`.
extension Fixture {
  static let fakeDevcontainer = """
    bin=$(dirname "$0")
    command="$1"; shift
    case "$command" in
      --version) echo 0.89.0 ;;
      up)
        echo "lots of build output" >&2
        sleep 0.3
        [ -f "$bin/fail-up" ] && { echo "boom" >&2; exit 1; }
        echo "up $*" >> "$bin/calls.log"
        echo "$2" > "$bin/running"
        touch "$bin/created"
        echo '{"outcome":"success"}' ;;
      exec)
        while [ $# -gt 0 ]; do
          case "$1" in
            --workspace-folder) workspace="$2"; shift 2 ;;
            --remote-env) echo "env $2" >> "$bin/calls.log"; shift 2 ;;
            --*) shift ;;
            *) break ;;
          esac
        done
        cd "$workspace" && exec "$@" ;;
      open) echo "open $*" >> "$bin/calls.log" ;;
    esac
    """

  static let fakeDocker = """
    bin=$(dirname "$0")
    case "$1" in
      ps)
        case "$*" in
          *-aq*) [ -f "$bin/created" ] && echo abc123 ;;
          *compose.project*) [ -f "$bin/running" ] && echo "abc123 acme0_devcontainer" ;;
          *--format*) [ -f "$bin/running" ] && cat "$bin/running" ;;
          *) [ -f "$bin/running" ] && echo abc123 ;;
        esac
        exit 0 ;;
      compose|stop) echo "docker $*" >> "$bin/calls.log"; rm -f "$bin/running" ;;
    esac
    """

  func installContainerFakes() throws {
    try script("\(bin)/devcontainer", Self.fakeDevcontainer)
    try script("\(bin)/docker", Self.fakeDocker)
  }

  /// Forgets all fake containers and logged calls.
  func resetContainerFakes() throws {
    for file in ["running", "created", "calls.log"] where exists("\(bin)/\(file)") {
      try FileManager.default.removeItem(atPath: "\(bin)/\(file)")
    }
  }

  /// The logged fake calls that start with `prefix`.
  func calls(_ prefix: String) throws -> [String] {
    guard exists("\(bin)/calls.log") else { return [] }
    return try read("\(bin)/calls.log").split(separator: "\n").map(String.init)
      .filter { $0.hasPrefix(prefix) }
  }

  /// Commits a devcontainer config, and a `bin/setup` that logs its arguments if `setup` is set.
  func addDevcontainer(setup: String? = nil) async throws {
    try write("\(main)/.devcontainer/devcontainer.json", "{}")
    if let setup {
      try script(
        "\(main)/bin/setup", setup.replacingOccurrences(of: "$LOG", with: "\(bin)/calls.log"))
    }
    try await commit("devcontainer")
    try await git("push", "--quiet")
  }
}
