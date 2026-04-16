# Restoring previously saved environment

None of the previous saves are deleted (unless they exceed the retention period).
All save files are kept in the save directory (see [save dir](save_dir.md) for
the default location).

Here are the steps to restore to a previous point in time:

- Make sure you start this with a "fresh" tmux instance.
- `cd` to your save directory (e.g., `~/.local/share/tmux/resurrect/`).
- Locate the save file you'd like to use for restore. Files are named
  `tmux_resurrect_YYYYMMDDTHHMMSS.jsonl` with a timestamp.
- Symlink the `last` file to the desired save file: `$ ln -sf <file_name> last`
- Do a restore with `tmux-resurrect` key: `prefix + Ctrl-r`

You should now be restored to the time when `<file_name>` save happened.

### Backup retention

By default, save files older than 30 days are cleaned up (keeping a minimum of
5 most recent saves). Change the retention period with:

    set -g @resurrect-delete-backup-after '60'

The value is in days.
