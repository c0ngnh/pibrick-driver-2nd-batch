# zsh

Installs Oh My Zsh + Powerlevel10k + autosuggestions / syntax-highlighting
for the active user, and switches their default login shell to zsh.

The original script (`install_zsh.sh`) refuses to run as root because it
manipulates `$HOME` files and `chsh`. This directory's `install.sh` detects
the active user (`$SUDO_USER` → `loginctl` → `who`, first non-root) and
re-executes the inner script under `sudo -u <user>` so the user sees the
right `$USER`, `$HOME`, and `EUID`.

## Install

```
sudo pibrick-tools --install zsh
```

Then close and re-open the terminal so the new `~/.zshrc` is sourced and
the shell change takes effect. Powerlevel10k's configuration wizard
(`p10k configure`) runs the first time zsh starts.

## Uninstall

```
sudo pibrick-tools --uninstall zsh
```

Restores the user's default shell to bash, removes `~/.oh-my-zsh`, and
renames `~/.zshrc` to `~/.zshrc.pibrick-backup-<timestamp>` so any
previous config can be recovered.