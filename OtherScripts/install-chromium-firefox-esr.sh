#!/bin/bash
#
# install_browsers.sh
# Installs Chromium and Firefox ESR with official Mozilla repo on ARM64.
#

set -e

echo "=========================================================="
echo "    Chromium + Firefox ESR Installer (ARM64)"
echo "=========================================================="

# Install basic dependencies
echo "--> Step 1: Installing wget and curl..."
sudo apt update
sudo apt install wget curl -y

# Install Chromium from system repo
echo "--> Step 2: Installing Chromium..."
sudo apt install chromium chromium-l10n -y

# Setup Mozilla repository
echo "--> Step 3: Setting up Mozilla APT repository..."
sudo install -d -m 0755 /etc/apt/keyrings

wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null

sudo tee /etc/apt/sources.list.d/mozilla.sources > /dev/null << 'MOZEOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
MOZEOF

# Pin Mozilla packages with highest priority
sudo tee /etc/apt/preferences.d/mozilla > /dev/null << 'MOZEOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
MOZEOF

# Install Firefox
echo "--> Step 4: Installing Firefox..."
sudo apt-get update
sudo apt-get install firefox -y

echo "=========================================================="
echo "      Installation complete!"
echo "=========================================================="
echo "Open Chromium or Firefox from your desktop menu."
echo "=========================================================="
