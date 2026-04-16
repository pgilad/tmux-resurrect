# Resurrect save dir

By default, the tmux environment is saved following XDG conventions:

- If `~/.tmux/resurrect/` exists, it is used (legacy path for existing users).
- Otherwise, `~/.local/share/tmux/resurrect/` is used (or `$XDG_DATA_HOME/tmux/resurrect/` if `XDG_DATA_HOME` is set).

To override the save directory:

    set -g @resurrect-dir '/some/path'

Using environment variables or shell interpolation in this option is not
allowed as the string is used literally. So the following won't do what is
expected:

    set -g @resurrect-dir '/path/$MY_VAR/$(some_executable)'

Only the following variables and special chars are allowed:
`$HOME`, `$HOSTNAME`, and `~`.
