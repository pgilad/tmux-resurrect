# Tmux Resurrect

Restore `tmux` environment after system restart.

Tmux is great, except when you have to restart the computer. You lose all the
running programs, working directories, pane layouts etc.
There are helpful management tools out there, but they require initial
configuration and continuous updates as your workflow evolves or you start new
projects.

`tmux-resurrect` saves all the little details from your tmux environment so it
can be completely restored after a system restart (or when you feel like it).
No configuration is required. You should feel like you never quit tmux.

It even (optionally)
[restores vim and neovim sessions](docs/restoring_vim_and_neovim_sessions.md)!

Automatic restoring and continuous saving of tmux env is also possible with
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) plugin.

### Screencast

[![screencast screenshot](/video/screencast_img.png)](https://vimeo.com/104763018)

### Key bindings

- `prefix + Ctrl-s` - save
- `prefix + Ctrl-r` - restore

### About

This plugin goes to great lengths to save and restore all the details from your
`tmux` environment. Here's what's been taken care of:

- all sessions, windows, panes and their order
- current working directory for each pane
- **exact pane layouts** within windows (even when zoomed)
- active and alternative session
- active and alternative window for each session
- windows with focus
- active pane for each window
- pane titles
- "grouped sessions" (useful feature when using tmux with multiple monitors)
- programs running within a pane! More details in the
  [restoring programs doc](docs/restoring_programs.md).

Optional:

- [restoring vim and neovim sessions](docs/restoring_vim_and_neovim_sessions.md)
- [restoring pane contents](docs/restoring_pane_contents.md)
- [restoring a previously saved environment](docs/restoring_previously_saved_environment.md)

Requirements / dependencies: `tmux 3.2` or higher, `bash`.

Tested and working on Linux and macOS.

`tmux-resurrect` is idempotent! It will not try to restore panes or windows that
already exist.
The single exception to this is when tmux is started with only 1 pane in order
to restore previous tmux env. Only in this case will the default session be
replaced.

### Installation with [tpm-rs](https://github.com/pgilad/tpm-rs) (recommended)

Add plugin to your `.tmux.conf`:

    set -g @plugin 'tmux-plugins/tmux-resurrect'

Then install with `prefix + I`.

### Manual Installation

Clone the repo:

    $ git clone https://github.com/tmux-plugins/tmux-resurrect ~/clone/path

Add this line to the bottom of `.tmux.conf`:

    run-shell ~/clone/path/resurrect.tmux

Reload tmux environment with: `$ tmux source-file ~/.tmux.conf`.
You should now be able to use the plugin.

### Docs

- [Guide for migrating from tmuxinator](docs/migrating_from_tmuxinator.md)

**Configuration**

- [Changing the default key bindings](docs/custom_key_bindings.md).
- [Setting up hooks on save & restore](docs/hooks.md).
- Only a conservative list of programs is restored by default:
  `vi vim view nvim emacs man less more tail top htop irssi weechat mutt`.
  [Restoring programs doc](docs/restoring_programs.md) explains how to restore
  additional programs.
- [Change the save directory](docs/save_dir.md) where `tmux-resurrect` saves
  tmux environment.

**Optional features**

- [Restoring vim and neovim sessions](docs/restoring_vim_and_neovim_sessions.md)
  is nice if you're a vim/neovim user.
- [Restoring pane contents](docs/restoring_pane_contents.md) feature.

### Save format

Save files use NDJSON (newline-delimited JSON) with a `.jsonl` extension. The
format is versioned (currently v2) and self-describing. Save files are stored
in `~/.local/share/tmux/resurrect/` by default (following XDG conventions), or
in `~/.tmux/resurrect/` if that directory already exists from a previous
installation.

### Save performance

The v2 save process is designed to be fast and lightweight:

- **Single process snapshot** — one `ps` call captures all pane processes upfront,
  replacing the old per-pane strategy lookups (pgrep, /proc, gdb).
- **Single tmux query** — `tmux list-panes -a` retrieves all pane data in one
  call, piped through a single AWK pass that joins process data in-memory and
  emits NDJSON directly.
- **No visual overhead** — no spinner or progress display; the save completes in
  under a second on typical setups and is imperceptible.
- **Deduplication** — if the environment hasn't changed since the last save, the
  duplicate file is discarded and no new backup is written.

These improvements make frequent saves practical. If you use
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for automatic
saving, a shorter interval such as 5 minutes works well:

    set -g @continuum-save-interval '5'

The previous default of 15 minutes was chosen when saving was heavier; with v2
there is no performance reason to keep it that long.

### Other goodies

- [tmux-copycat](https://github.com/tmux-plugins/tmux-copycat) - a plugin for
  regex searches in tmux and fast match selection
- [tmux-yank](https://github.com/tmux-plugins/tmux-yank) - enables copying
  highlighted text to system clipboard
- [tmux-open](https://github.com/tmux-plugins/tmux-open) - a plugin for quickly
  opening highlighted file or a url
- [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) - automatic
  restoring and continuous saving of tmux env

### Reporting bugs and contributing

Both contributing and bug reports are welcome. Please check out
[contributing guidelines](CONTRIBUTING.md).

### Credits

[Mislav Marohnić](https://github.com/mislav) - the idea for the plugin came from his
[tmux-session script](https://github.com/mislav/dotfiles/blob/2036b5e03fb430bbcbc340689d63328abaa28876/bin/tmux-session).

This project is based on the original
[tmux-plugins/tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect).

### License

[MIT](LICENSE)
