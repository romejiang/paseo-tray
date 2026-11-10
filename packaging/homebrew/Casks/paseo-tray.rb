cask "paseo-tray" do
  version "0.1.1"
  sha256 "16fb11d2bee304e10247fcd376577c5fc34cdcc1bcb9af6b34a7f1a2e86e6a96"

  url "https://github.com/romejiang/paseo-tray/releases/download/v#{version}/PaseoTray-#{version}.dmg"
  name "Paseo Tray"
  desc "macOS menu bar tray for Paseo"
  homepage "https://github.com/romejiang/paseo-tray"

  depends_on macos: :ventura

  app "PaseoTray.app"

  uninstall quit: "sh.paseo.tray"

  zap trash: [
    "~/Library/Application Support/PaseoTray",
    "~/Library/Preferences/sh.paseo.tray.plist",
  ]
end
