# Homebrew cask for Dev Monitor — TEMPLATE.
#
# Publish this in a tap repo (e.g. `<you>/homebrew-tap`) as `Casks/dev-monitor.rb`, then users:
#   brew tap <you>/tap
#   brew install --cask dev-monitor
#
# Fill in `version`, the two `sha256` values (shasum -a 256 dist/*.dmg dist/*.zip) and the release
# URLs. The CI release workflow (.github/workflows/release.yml) can bump these automatically.
# Requires a notarized .dmg (see docs/DISTRIBUTION.md) — otherwise Gatekeeper blocks the install.
cask "dev-monitor" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/OWNER/DevMonitor/releases/download/v#{version}/Dev.Monitor-#{version}.dmg"
  name "Dev Monitor"
  desc "Native macOS supervisor for JS/TS dev servers"
  homepage "https://github.com/OWNER/DevMonitor"

  depends_on macos: ">= :sequoia"

  app "Dev Monitor.app"

  # The CLI ships as a separate zip in the same release; install it onto PATH.
  resource "cli" do
    url "https://github.com/OWNER/DevMonitor/releases/download/v#{version}/dev-monitor-#{version}.zip"
    sha256 "REPLACE_WITH_CLI_ZIP_SHA256"
  end
  binary "#{staged_path}/dev-monitor", target: "dev-monitor"

  zap trash: [
    "~/Library/Application Support/DevMonitor",
  ]
end
