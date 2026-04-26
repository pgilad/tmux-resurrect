#!/usr/bin/env bash

resurrect_dir() {
	local opt host home_token hostname_token tilde_token
	opt="$(tmux show-option -gqv '@resurrect-dir')"
	if [ -n "$opt" ]; then
		host="$(hostname)"
		home_token="\$HOME"
		hostname_token="\$HOSTNAME"
		tilde_token='~'
		opt="${opt//$home_token/$HOME}"
		opt="${opt//$hostname_token/$host}"
		opt="${opt//$tilde_token/$HOME}"
		printf '%s\n' "$opt"
		return
	fi
	if [ -d "$HOME/.tmux/resurrect" ]; then
		printf '%s\n' "$HOME/.tmux/resurrect"
		return
	fi
	printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
}

hook() {
	local kind="$1"
	shift
	local cmd args=""
	cmd="$(tmux show-option -gqv "@resurrect-hook-$kind")"
	if [ -n "$cmd" ]; then
		if [ "$#" -gt 0 ]; then
			printf -v args "%q " "$@"
		fi
		eval "$cmd $args"
	fi
}
