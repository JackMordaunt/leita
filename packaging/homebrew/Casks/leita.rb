# typed: false
# frozen_string_literal: true

# The window, from the release's disk image. The manifests job fills the
# version, the file name (the image carries -unsigned until the certificate
# exists) and the sha256, and pushes this file to jackmordaunt/homebrew-tap.
cask "leita" do
  version "__VERSION__"
  sha256 "__SUM_DMG__"

  url "https://github.com/jackmordaunt/leita/releases/download/v#{version}/__FILE_DMG__"
  name "Leita"
  desc "See what is filling a drive, and report on it"
  homepage "https://mordaunt.dev/leita"
  license "Proprietary"

  livecheck do
    url "https://github.com/jackmordaunt/leita/releases/latest"
    strategy :github_latest
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  app "Leita.app"
  # The command lives inside the bundle. The link follows the app to the
  # Applications folder, where app puts it; a link to the staged copy would
  # dangle once the image is unmounted.
  binary "#{appdir}/Leita.app/Contents/Helpers/leita"

  # history/platform_darwin.odin keeps the store in this folder.
  zap trash: "~/Library/Application Support/leita"

  conflicts_with formula: "leita", because: "both install the leita command"
end
