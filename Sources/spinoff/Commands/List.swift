import ArgumentParser

struct List: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List the slots of the current repo and whether their containers are running."
  )

  func run() async throws {
    let slots = try await Repo.current().slots()
    guard !slots.isEmpty else { return }

    let running = await Container.runningFolders()
    let rows = slots.map { slot in
      var row = [slot.name, String(slot.head.prefix(7)), slot.branch ?? "detached"]
      if let running { row.append(running.contains(slot.path) ? "running" : "stopped") }
      return row + [slot.status]
    }

    let columns = rows[0].count
    let widths = (0..<columns).map { column in rows.map { $0[column].count }.max() ?? 0 }
    for row in rows {
      let padded = row.enumerated().map { column, value in
        column == columns - 1
          ? value : value.padding(toLength: widths[column], withPad: " ", startingAt: 0)
      }
      print(padded.joined(separator: "  "))
    }
  }
}
