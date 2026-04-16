# Restoring programs

### Default behavior

Only a conservative list of programs is restored by default:
`vi vim view nvim emacs man less more tail top htop irssi weechat mutt`.

This can be configured with `@resurrect-processes` option in `.tmux.conf`. It
contains the full space-separated list of programs to restore.

- Example restoring a custom program list:

        set -g @resurrect-processes 'ssh psql mysql sqlite3'

- Don't restore any programs:

        set -g @resurrect-processes 'false'

- Restore **all** programs (dangerous!):

        set -g @resurrect-processes ':all:'

  Be *very careful* with this: tmux-resurrect cannot know which programs take
  which context, and a `sudo mkfs.vfat /dev/sdb` that was just formatting an
  external USB stick could wipe your backup hard disk if that's what's attached
  after rebooting.

### Process rewrite rules

When a program is restored, you may want to change the command that gets
replayed. This is controlled with the `@resurrect-process-rules` option, which
contains semicolon-separated `match:command` pairs.

Default:

    set -g @resurrect-process-rules 'vim:vim -S;nvim:nvim -S'

**Plain match** - the match string is compared against the first word of the
saved process command:

    set -g @resurrect-process-rules 'vim:vim -S;nvim:nvim -S'

This means: if the process started with `vim`, restore it as `vim -S`. If it
started with `nvim`, restore it as `nvim -S`.

**Tilde match** (`~`) - the match string is searched as a substring anywhere in
the full saved command:

    set -g @resurrect-process-rules '~rails server:*'

This means: if the saved command contains `rails server` anywhere, replay the
original full command as-is (the `*` means "use original command").

**Using `*` for the command** replays the exact original command that was saved:

    set -g @resurrect-process-rules '~rails server:*;~bin/webpack-dev-server:*'

### Examples

Restore `rails server` with original arguments:

    set -g @resurrect-process-rules '~rails server:*'

Restore vim/neovim with session file support:

    set -g @resurrect-process-rules 'vim:vim -S;nvim:nvim -S'

Replay original vim/neovim commands exactly as saved:

    set -g @resurrect-process-rules 'vim:*;nvim:*'

### How to debug

- Save your tmux environment (`prefix + Ctrl-s`).
- Open the save file (the `last` symlink in your save directory points to the
  most recent save). It's a JSONL file with one JSON object per line.
- Look for `"pcmd"` fields in pane lines to see the full process commands that
  were captured.
- The `"cmd"` field shows the short process name.
