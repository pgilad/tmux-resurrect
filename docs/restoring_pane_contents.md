# Restoring pane contents

Saving and restoring visible tmux pane contents is not implemented in the v2
save format.

The older `@resurrect-capture-pane-contents` option is currently ignored:

    set -g @resurrect-capture-pane-contents 'on'

Do not rely on this option until pane-content support is reintroduced.
