import Testing
@testable import SwiftApoderado

@Test
func versionIsSet() {
  #expect(!SwiftApoderado.version.isEmpty)
}
