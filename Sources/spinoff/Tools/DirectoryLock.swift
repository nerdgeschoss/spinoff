import Darwin

/// Runs `body` while holding an exclusive flock on `path`, which the kernel releases when the process exits.
func withDirectoryLock<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
  let descriptor = open(path, O_RDONLY)
  guard descriptor >= 0 else { throw SpinoffError.failed("can't open \(path) for locking") }
  defer { close(descriptor) }
  guard flock(descriptor, LOCK_EX) == 0 else { throw SpinoffError.failed("can't lock \(path)") }
  return try await body()
}
