import ArgumentParser
import SwiftApoderado

@main
struct Apoderado: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "apoderado",
    abstract: "Agentic coder backed by local models.",
    version: SwiftApoderado.version
  )

  func run() async throws {
    print("apoderado \(SwiftApoderado.version)")
  }
}
