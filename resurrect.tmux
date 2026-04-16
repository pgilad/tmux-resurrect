#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
	local key

	# Save key binding(s)
	local save_keys
	save_keys="$(tmux show-option -gqv '@resurrect-save')"
	: "${save_keys:=C-s}"
	for key in $save_keys; do
		tmux bind-key "$key" run-shell "$CURRENT_DIR/scripts/save.sh"
	done

	# Restore key binding(s)
	local restore_keys
	restore_keys="$(tmux show-option -gqv '@resurrect-restore')"
	: "${restore_keys:=C-r}"
	for key in $restore_keys; do
		tmux bind-key "$key" run-shell "$CURRENT_DIR/scripts/restore.sh"
	done

	# Script paths for tmux-continuum integration
	tmux set-option -gq "@resurrect-save-script-path" "$CURRENT_DIR/scripts/save.sh"
	tmux set-option -gq "@resurrect-restore-script-path" "$CURRENT_DIR/scripts/restore.sh"
}

main
