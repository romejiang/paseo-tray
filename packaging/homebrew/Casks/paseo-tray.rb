cask "paseo-tray" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SIGNED_DMG_SHA256"

  url "https://github.com/romejiang/paseo-tray/releases/download/v#{version}/PaseoTray-#{version}.dmg"
  name "Paseo Tray"
  desc "macOS menu bar tray for Paseo"
  homepage "https://github.com/romejiang/paseo-tray"

  depends_on macos: ">= :ventura"

  app "PaseoTray.app"

  uninstall quit: "sh.paseo.tray"

  zap trash: [
    "~/Library/Application Support/PaseoTray",
    "~/Library/Preferences/sh.paseo.tray.plist",
  ]
end
