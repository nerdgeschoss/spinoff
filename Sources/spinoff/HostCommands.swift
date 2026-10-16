/// Finds toolchain commands in a shell command line that would run on the host instead of in a slot's container.
enum HostCommands {
  static let toolchain: Set<String> = [
    "bundle", "rails", "rake", "ruby", "gem", "rspec", "rubocop", "yarn", "npm", "npx", "node",
  ]
  /// Prefixes that run the next word as the actual command.
  static let wrappers: Set<String> = [
    "env", "time", "command", "exec", "nohup", "sudo", "xargs", "nice",
  ]

  /// The first toolchain command in `commandLine` that isn't run through `spinoff exec`, or nil.
  static func firstBlocked(in commandLine: String) -> String? {
    for words in segments(of: commandLine) {
      guard let command = words.drop(while: { isAssignment($0) || wrappers.contains($0) }).first
      else { continue }
      let name = command.split(separator: "/").last.map(String.init) ?? command
      if command.hasPrefix("bin/") || command.hasPrefix("./bin/") || toolchain.contains(name) {
        return command
      }
    }
    return nil
  }

  /// Splits a command line into the words of each simple command, honoring quotes and escapes.
  static func segments(of commandLine: String) -> [[String]] {
    var segments: [[String]] = [[]]
    var word = ""
    var inWord = false
    var quote: Character?
    let characters = Array(commandLine)

    func endWord() {
      if inWord { segments[segments.count - 1].append(word) }
      word = ""
      inWord = false
    }
    func endSegment() {
      endWord()
      if !segments[segments.count - 1].isEmpty { segments.append([]) }
    }

    var index = 0
    while index < characters.count {
      let character = characters[index]
      if let open = quote {
        if character == open {
          quote = nil
        } else if character == "\\", open == "\"", index + 1 < characters.count {
          index += 1
          word.append(characters[index])
        } else {
          word.append(character)
        }
      } else {
        switch character {
        case "'", "\"":
          quote = character
          inWord = true
        case "\\" where index + 1 < characters.count:
          index += 1
          word.append(characters[index])
          inWord = true
        case " ", "\t":
          endWord()
        case ";", "|", "&", "(", ")", "`", "\n":
          endSegment()
        case "$" where index + 1 < characters.count && characters[index + 1] == "(":
          endSegment()
          index += 1
        default:
          word.append(character)
          inWord = true
        }
      }
      index += 1
    }
    endWord()
    return segments.filter { !$0.isEmpty }
  }

  private static func isAssignment(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
  }
}
