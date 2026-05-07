# ~/.bash_profile — read by bash for LOGIN shells (wsl.exe, `bash -l`, ssh).
#
# Login shells skip ~/.bashrc by design, so without delegation here, every
# wsl.exe-spawned pane starts without `cc`, `pull-all`, `projects`, NVM,
# cargo, or the auto-`cd ~/dev`. Standard convention every distro ships:
# .bash_profile sources .bashrc so login shells get the same env as
# non-login interactive shells.
#
# Tracked in dotfiles and symlinked into $HOME by setup.sh — single source
# of truth, version controlled, audit-able. Do not let the PAI installer
# (or any other tool) overwrite this file without preserving the .bashrc
# delegation block at the bottom.

# Make Bun reachable for hook subprocesses (kept here so the PAI installer's
# `grep -q '\.bun/bin'` skip-check finds it and does not re-append on re-runs).
export PATH="$HOME/.bun/bin:$PATH"

# Source .bashrc for login shells (the actual fix for "cc not found in wsl6").
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
