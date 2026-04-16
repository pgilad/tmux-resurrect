# Save & Restore Hooks

Hooks allow you to set custom commands that will be executed during session save
and restore. Most hooks are called with zero arguments, unless explicitly
stated otherwise.

Currently the following hooks are supported:

- `@resurrect-hook-post-save-layout`

  Called after all sessions, panes and windows have been saved.

  Passed single argument of the state file path.

- `@resurrect-hook-post-save-all`

  Called at end of save process.

- `@resurrect-hook-pre-restore-all`

  Called before any tmux state is altered.

- `@resurrect-hook-pre-restore-pane-processes`

  Called before running processes are restored.

- `@resurrect-hook-post-restore-all`

  Called after the full restore is complete.

### Examples

Here is an example how to save and restore window geometry for most terminals in X11.
Add this to `.tmux.conf`:

    set -g @resurrect-hook-post-save-all 'eval $(xdotool getwindowgeometry --shell $WINDOWID); echo 0,$X,$Y,$WIDTH,$HEIGHT > $HOME/.local/share/tmux/resurrect/geometry'
    set -g @resurrect-hook-pre-restore-all 'wmctrl -i -r $WINDOWID -e $(cat $HOME/.local/share/tmux/resurrect/geometry)'
