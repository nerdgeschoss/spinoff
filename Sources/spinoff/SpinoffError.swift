import Foundation

struct SpinoffError: Error, CustomStringConvertible {
  var message: String
  var exitCode: Int32 = 1

  init(_ message: String, exitCode: Int32 = 1) {
    self.message = message
    self.exitCode = exitCode
  }

  var description: String { message }
}

func warn(_ message: String) {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
}
