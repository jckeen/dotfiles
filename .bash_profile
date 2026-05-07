# ~/.bash_profile — read by bash for LOGIN shells (wsl.exe, `bash -l`, ssh).
#
# Login shells skip ~/.bashrc by design, so without delegation here, every
# wsl.exe-spawned pane (and every fresh ssh / Terminal.app bash session)
# starts without the aliases, functions, and PATH entries defined in
# .bashrc / .bash_aliases. Standard distro convention every distro ships:
# .bash_profile sources .bashrc so login shells get the same env as
# non-login interactive shells.
#
# Tracked in dotfiles and symlinked into $HOME by setup.sh — single source
# of truth, version controlled, audit-able. Safe to use whether or not
# you use PAI: the bun-PATH line below is a no-op when bun isn't installed.

# Put bun on PATH if installed (harmless when ~/.bun/bin doesn't exist).
# The literal `.bun/bin` substring also satisfies the PAI installer's
# idempotent skip-check (`grep -q '\.bun/bin'`) so re-running that
# installer won't append a duplicate export to this file.
[ -d "$HOME/.bun/bin" ] && export PATH="$HOME/.bun/bin:$PATH"

# Source .bashrc for login shells. This is the actual fix for the
# "cc / aliases / NVM / cargo / dev cd not loaded in fresh login shell"
# problem; everything else in this file is window-dressing.
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
