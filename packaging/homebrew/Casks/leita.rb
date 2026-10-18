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

  livecheck do
    url "https://github.com/jackmordaunt/leita/releases/latest"
    strategy :github_latest
    regex(/^v?(\d+(?:\.\d+)+)$/i)
  end

  app "Leita.app"
  # Link the command inside the bundle at the configured app destination.
  binary "#{appdir}/Leita.app/Contents/Helpers/leita"

  # history/platform_darwin.odin keeps the store in this folder.
  zap trash: "~/Library/Application Support/leita"

end
