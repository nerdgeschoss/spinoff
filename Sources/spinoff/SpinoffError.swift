import Foundation

/// spinoff's own failures, kept apart from the exit codes of commands it runs.
enum SpinoffError: Error, CustomStringConvertible {
  /// spinoff refused or couldn't do what was asked, e.g. outside a slot or with work that would be lost (exit 1).
  case failed(String)
  /// Something spinoff needs is missing or broke: Docker, the devcontainer CLI, the container (exit 125).
  case unavailable(String)

  var message: String {
    switch self {
    case .failed(let message), .unavailable(let message): message
    }
  }

  var exitCode: Int32 {
    switch self {
    case .failed: 1
    case .unavailable: 125
    }
  }

  var description: String { message }
}

func warn(_ message: String) {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
}
