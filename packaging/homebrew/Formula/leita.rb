# typed: false
# frozen_string_literal: true

# The command line, from the release archives. The manifests job fills the
# version and each sha256 from sha256sums.txt and pushes this file to
# jackmordaunt/homebrew-tap. macOS is one universal archive, because a
# formula needs a tarball with a known sha and the bare universal binary is
# the name jm:selfupdate fetches. Linux is the per-architecture tar.zst a
# person also downloads. The window is the cask.
class Leita < Formula
  desc "See what is filling a drive, and report on it"
  homepage "https://mordaunt.dev/leita"
  version "__VERSION__"
  license "Proprietary"

  # GitHub's latest release, which is not a draft or a pre-release. The tag
  # is v1.2.0 and this formula's version is 1.2.0.
  livecheck do
    url "https://github.com/jackmordaunt/leita/releases/latest"
    strategy :github_latest
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  on_macos do
    url "https://github.com/jackmordaunt/leita/releases/download/v#{version}/leita-v#{version}-darwin-universal-cli.tar.zst"
    sha256 "__SUM_DARWIN_CLI__"
  end

  on_linux do
    if Hardware::CPU.intel? && Hardware::CPU.is_64_bit?
      url "https://github.com/jackmordaunt/leita/releases/download/v#{version}/leita-v#{version}-linux-amd64.tar.zst"
      sha256 "__SUM_LINUX_AMD64__"
    end
    if Hardware::CPU.arm? && Hardware::CPU.is_64_bit?
      url "https://github.com/jackmordaunt/leita/releases/download/v#{version}/leita-v#{version}-linux-arm64.tar.zst"
      sha256 "__SUM_LINUX_ARM64__"
    end
  end

  # The Linux archive wraps its files in one directory and the macOS CLI
  # archive does not, so the binary is found by name in either. The notices
  # travel with the binary, as they do in the other archives.
  def install
    bin.install buildpath.glob("**/leita").first
    license = buildpath.glob("**/LICENSE.md").first
    third = buildpath.glob("**/THIRD_PARTY.md").first
    doc.install license if license
    doc.install third if third
  end

  # The cask links the same command out of Leita.app.
  conflicts_with cask: "leita", because: "both install the leita command"
end
