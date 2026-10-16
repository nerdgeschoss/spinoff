import Foundation

enum Terminal {
  /// Whether a person can answer questions: stdin and stderr are both terminals.
  static var isInteractive: Bool { isatty(0) == 1 && isatty(2) == 1 }

  static var usesColor: Bool {
    isatty(1) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
  }

  /// Asks a yes/no question on stderr; an empty answer means yes.
  static func confirm(_ question: String) -> Bool {
    FileHandle.standardError.write(Data("\(question) [Y/n] ".utf8))
    guard let answer = readLine() else { return false }
    return ["", "y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
  }
}
