# Restoring pane contents

This plugin supports saving and restoring tmux pane contents.

This feature can be enabled by adding this line to `.tmux.conf`:

    set -g @resurrect-capture-pane-contents 'on'

When enabled, the visible pane contents are captured on save and replayed on
restore.

**Note:** This is an optional feature that is not yet implemented in the v2
redesign. It will be added in a future release.
