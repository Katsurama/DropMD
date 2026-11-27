cask "dropmd" do
  version "1.1.0"
  sha256 "49ea38bef3742b0a24160c070316d75a4936af52c71e8b9082f37824ef104d8a"

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

  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/DropMD.app"],
        writable_paths: ["DropMD.app"],
        writable_base:  :appdir,
        must_succeed:   false,
        print_stderr:   false
  end

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
    The quarantine attribute is automatically cleared on install so you can open DropMD directly.
    If macOS still blocks it, allow it in System Settings → Privacy & Security → Open Anyway.
  EOS
end
