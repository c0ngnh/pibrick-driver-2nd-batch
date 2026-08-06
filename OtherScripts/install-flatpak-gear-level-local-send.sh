#!/bin/bash
#
# install_flatpak_apps.sh
# Installs Flatpak, Gear Lever, and LocalSend on ARM64 Linux.
#

set -e

echo "=========================================================="
echo " Flatpak + Gear Lever + LocalSend Installer (ARM64)"
echo "=========================================================="

# Install Flatpak
echo "--> Step 1: Installing Flatpak..."
sudo apt update
sudo apt install flatpak -y

# Add Flathub repository
echo "--> Step 2: Adding Flathub repository..."
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Configure Flatpak environment
echo "--> Step 3: Configuring Flatpak environment variables..."
if [ -f "$HOME/.bashrc" ]; then
    if ! grep -q 'XDG_DATA_DIRS' "$HOME/.bashrc"; then
        echo 'export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:$XDG_DATA_DIRS"' >> "$HOME/.bashrc"
    fi
fi
if [ -f "$HOME/.zshrc" ]; then
    if ! grep -q 'XDG_DATA_DIRS' "$HOME/.zshrc"; then
        echo 'export XDG_DATA_DIRS="$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:$XDG_DATA_DIRS"' >> "$HOME/.zshrc"
    fi
fi

# Install apps
echo "--> Step 4: Installing Gear Lever..."
sudo flatpak install flathub it.mijorus.gearlever -y

echo "--> Step 5: Installing LocalSend..."
sudo flatpak install flathub org.localsend.localsend_app -y

echo "=========================================================="
echo "      Installation complete!"
echo "=========================================================="
echo "Restart your terminal, then run apps from your desktop menu or:"
echo "  flatpak run it.mijorus.gearlever"
echo "  flatpak run org.localsend.localsend_app"
echo "=========================================================="
