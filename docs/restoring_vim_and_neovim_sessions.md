# Restoring vim and neovim sessions

- Save vim/neovim sessions. I recommend
  [tpope/vim-obsession](https://github.com/tpope/vim-obsession) (as almost every
  plugin, it works for both vim and neovim).
- `tmux-resurrect` restores vim and neovim with `vim -S` / `nvim -S` by default
  via the built-in process rewrite rules.

The default `@resurrect-process-rules` option includes:

    vim:vim -S;nvim:nvim -S

This means when vim or neovim is detected in a pane, it will be restored with
the `-S` flag, which loads `Session.vim` if present.

If you don't use `Session.vim` files and want to restore vim/neovim without
the `-S` flag, override the rules:

    set -g @resurrect-process-rules 'vim:vim;nvim:nvim'

Or to replay the original vim/neovim commands exactly as saved:

    set -g @resurrect-process-rules 'vim:*;nvim:*'

> If you're using a different executable name, such as `mvim`, include that
> exact command name in `@resurrect-processes`, for example:
> ```
> set -g @resurrect-processes 'vi vim view nvim mvim'
> set -g @resurrect-process-rules 'vim:vim -S;nvim:nvim -S;mvim:vim -S'
> ```
