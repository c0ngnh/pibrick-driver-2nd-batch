#!/bin/bash
#
# install_zsh.sh
# Installs Oh My Zsh with Powerlevel10k theme and recommended plugins.
#

set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Do not run this script as root (sudo)."
    echo "Run as a normal user: ./install_zsh.sh"
    exit 1
fi

USER_HOME="$HOME"
USER_NAME="$USER"

echo "================================================="
echo "   Zsh + Oh My Zsh + Powerlevel10k Installer"
echo "================================================="

# Install system dependencies
echo "--> Step 1: Installing Zsh, Git, Curl..."
sudo apt update
sudo apt install zsh git curl -y

# Fix ownership if old .oh-my-zsh exists
if [ -d "$USER_HOME/.oh-my-zsh" ]; then
    echo "--> Step 2: Cleaning up existing Oh My Zsh installation..."
    sudo chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.oh-my-zsh"
    rm -rf "$USER_HOME/.oh-my-zsh"
fi

# Clone Oh My Zsh
echo "--> Step 3: Installing Oh My Zsh..."
git clone https://github.com/ohmyzsh/ohmyzsh.git "$USER_HOME/.oh-my-zsh"

# Clone Powerlevel10k theme
echo "--> Step 4: Installing Powerlevel10k theme..."
mkdir -p "$USER_HOME/.oh-my-zsh/custom/themes"
git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k"

# Install plugins
echo "--> Step 5: Installing plugins (autosuggestions, syntax-highlighting)..."
mkdir -p "$USER_HOME/.oh-my-zsh/custom/plugins"
git clone https://github.com/zsh-users/zsh-autosuggestions "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$USER_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"

# Create .zshrc
echo "--> Step 6: Creating .zshrc configuration..."
cat << 'EOF' > "$USER_HOME/.zshrc"
# Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"

# Powerlevel10k theme
ZSH_THEME="powerlevel10k/powerlevel10k"

# Update mode (notify only)
zstyle ':omz:update' mode reminder
zstyle ':omz:update' frequency 13

# Plugins
plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    extract
)

# PlatformIO (if installed)
if [ -d "$HOME/.platformio/penv/bin" ]; then
    export PATH="$HOME/.platformio/penv/bin:$PATH"
fi

# Local bin
export PATH="$HOME/.local/bin:$PATH"

source $ZSH/oh-my-zsh.sh
EOF

sudo chown "$USER_NAME:$USER_NAME" "$USER_HOME/.zshrc"

# Set Zsh as default shell
echo "--> Step 7: Setting Zsh as default shell for $USER_NAME..."
sudo chsh -s $(which zsh) "$USER_NAME"

echo "================================================="
echo "      Installation complete!"
echo " Restart your terminal or log out/in to apply."
echo "================================================="
