class Apoderado < Formula
  desc "Agentic coder backed by local models"
  homepage "https://github.com/intrusive-memory/SwiftApoderado"
  url "https://github.com/intrusive-memory/SwiftApoderado.git", branch: "main"
  version "0.0.1"
  license "MIT"

  depends_on xcode: ["26.0", :build]
  depends_on macos: :tahoe
  depends_on arch: :arm64

  def install
    system "make", "release"
    bin.install "bin/apoderado"
  end

  test do
    assert_match "apoderado", shell_output("#{bin}/apoderado --version")
  end
end
