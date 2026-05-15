import Foundation
import Testing

/// Validates the compiled `./bin/apoderado` binary produced by `make release`/`make install`.
/// Skipped in environments where the binary hasn't been built.
@Suite("Apoderado Binary Integration")
struct ApoderadoBinaryIntegrationTests {

  static let binaryPath: String = {
    let cwd = FileManager.default.currentDirectoryPath
    return "\(cwd)/bin/apoderado"
  }()

  @Test
  func binaryExists() throws {
    try requireBinary()
  }

  @Test
  func helpFlagSucceeds() throws {
    try requireBinary()
    let result = try run(args: ["--help"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("apoderado"))
  }

  @Test
  func versionFlagSucceeds() throws {
    try requireBinary()
    let result = try run(args: ["--version"])
    #expect(result.exitCode == 0)
    #expect(!result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  // MARK: - Helpers

  private func requireBinary() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.binaryPath) else {
      Issue.record("apoderado binary not found at \(Self.binaryPath) — run `make install` first")
      throw CancellationError()
    }
  }

  private struct RunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
  }

  private func run(args: [String]) throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.binaryPath)
    process.arguments = args
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return RunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }
}
