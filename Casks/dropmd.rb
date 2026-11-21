cask "dropmd" do
  version "1.0.0"
  sha256 "3fc5acdb391a2664abda7e84c4e1643beaa242fd875533a5f4d32c6c43758cec"

  url "https://github.com/Katsurama/DropMD/releases/download/v#{version}/DropMD-macOS-AppleSilicon.dmg"
  name "DropMD"
  desc "Offline Markdown editor and document converter"
  homepage "https://github.com/Katsurama/DropMD"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "DropMD.app"

  zap trash: [
    "~/Library/Application Support/DropMD",
    "~/Library/Caches/DropMD",
    "~/Library/Caches/io.github.dropmd.app",
    "~/Library/Containers/io.github.dropmd.app.quicklook",
    "~/Library/HTTPStorages/io.github.dropmd.app",
    "~/Library/Logs/DropMD",
    "~/Library/Preferences/io.github.dropmd.app.plist",
    "~/Library/Saved Application State/io.github.dropmd.app.savedState",
  ]

  caveats <<~EOS
    DropMD is an open-source app signed ad-hoc without an Apple Developer ID or notarization.
    On first launch, macOS Gatekeeper may block it. You can allow it in:
      System Settings → Privacy & Security → Open Anyway
    or remove the quarantine attribute in Terminal:
      xattr -dr com.apple.quarantine /Applications/DropMD.app
  EOS
end
