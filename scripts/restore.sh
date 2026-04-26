#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/helpers.sh"

RESTORE_JSON_AWK="$CURRENT_DIR/restore_json.awk"
RESTORE_VALIDATE_AWK="$CURRENT_DIR/restore_validate.awk"
RESTORE_STRUCTURE_AWK="$CURRENT_DIR/restore_structure.awk"
RESTORE_PROCESSES_AWK="$CURRENT_DIR/restore_processes.awk"

msg() {
	tmux display-message "$1"
}

resolve_last_save_file() {
	local dir="$1"
	local last="$2"
	local save_file first_line

	if [ -L "$last" ]; then
		save_file="$(readlink "$last" 2>/dev/null || true)"
		if [ -z "$save_file" ]; then
			msg "Tmux resurrect: save file link is unreadable: $last"
			return 1
		fi
	elif [ -f "$last" ]; then
		IFS= read -r first_line < "$last" || true
		case "$first_line" in
			'{"v":'*)
				printf '%s\n' "$last"
				return 0
				;;
			"")
				msg "Tmux resurrect: last save pointer is empty: $last"
				return 1
				;;
			*)
				save_file="$first_line"
				;;
		esac
	else
		msg "Tmux resurrect: no save file found!"
		return 1
	fi

	# Handle relative symlink target or pointer-file target.
	case "$save_file" in
		/*) ;; # absolute path, use as-is
		*)  save_file="$dir/$save_file" ;;
	esac
	if [ ! -f "$save_file" ]; then
		msg "Tmux resurrect: save file not found: $save_file"
		return 1
	fi

	printf '%s\n' "$save_file"
}

validate_save_file() {
	local save_file="$1"
	local validation code detail tab

	if validation="$(awk -f "$RESTORE_JSON_AWK" -f "$RESTORE_VALIDATE_AWK" "$save_file" 2>/dev/null)"; then
		return 0
	fi

	tab=$'\t'
	code="${validation%%"$tab"*}"
	detail="${validation#*"$tab"}"
	if [ "$detail" = "$validation" ]; then
		detail=""
	fi

	case "$code" in
		UNSUPPORTED)
			msg "Tmux resurrect: unsupported save format (version: ${detail:-unknown})"
			;;
		NO_PANES)
			msg "Tmux resurrect: save file contains no panes: $save_file"
			;;
		INVALID)
			msg "Tmux resurrect: invalid save file: ${detail:-$save_file}"
			;;
		*)
			msg "Tmux resurrect: invalid save file: $save_file"
			;;
	esac
	return 1
}

main() {
	local dir last save_file script existing_file actual_panes_file

	dir="$(resurrect_dir)"
	last="$dir/last"

	# Resolve save file
	if ! save_file="$(resolve_last_save_file "$dir" "$last")"; then
		return 1
	fi

	# Validate version and minimal schema before mutating tmux state.
	if ! validate_save_file "$save_file"; then
		return 1
	fi

	# Detect "from scratch" mode: only 1 pane = fresh tmux server
	local from_scratch="false"
	local total_panes
	total_panes="$(tmux list-panes -a -F x | wc -l | tr -d ' ')"
	if [ "$total_panes" -eq 1 ]; then
		from_scratch="true"
	fi

	msg "Restoring..."
	hook "pre-restore-all"

	# In from-scratch mode, rename the default session out of the way so the
	# awk generator can create everything fresh without name conflicts.
	local tmp_session="_resurrect_tmp_$$"
	if [ "$from_scratch" = "true" ]; then
		local default_session
		default_session="$(tmux display-message -p '#{client_session}')"
		tmux rename-session -t "$default_session" "$tmp_session"
	fi

	# Snapshot existing state (one tmux command) for idempotent restore
	existing_file="$(mktemp "${TMPDIR:-/tmp}/resurrect-existing.XXXXXX")"
	tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' > "$existing_file"

	# Read tmux settings needed by the awk generator
	local base_index pane_base_index
	base_index="$(tmux show-option -gqv base-index)"
	: "${base_index:=0}"
	pane_base_index="$(tmux show-option -gqv pane-base-index)"
	: "${pane_base_index:=0}"

	# Generate tmux command script from save file
	script="$(mktemp "${TMPDIR:-/tmp}/resurrect-restore.XXXXXX")"
	actual_panes_file=""
	trap 'rm -f "$script" "$existing_file" "$actual_panes_file"' EXIT

	awk -v base_index="$base_index" \
	    -v pane_base="$pane_base_index" \
	    -v existing_file="$existing_file" \
	    -f "$RESTORE_JSON_AWK" \
	    -f "$RESTORE_STRUCTURE_AWK" \
	    "$save_file" > "$script"

	# Execute the generated tmux command script
	if ! tmux source-file "$script"; then
		msg "Tmux resurrect: failed to restore tmux structure"
		return 1
	fi

	# From-scratch cleanup: kill the renamed default session
	if [ "$from_scratch" = "true" ]; then
		# Ensure there is another session before removing the startup session.
		local current_session replacement_session
		replacement_session="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | awk -v tmp="$tmp_session" '$0 != tmp { print; exit }')"
		if [ -z "$replacement_session" ]; then
			msg "Tmux resurrect: no restored sessions; keeping startup session"
			return 1
		fi
		current_session="$(tmux display-message -p '#{client_session}' 2>/dev/null || true)"
		if [ "$current_session" = "$tmp_session" ]; then
			tmux switch-client -t "$replacement_session" 2>/dev/null || true
		fi
		current_session="$(tmux display-message -p '#{client_session}' 2>/dev/null || true)"
		if [ "$current_session" != "$tmp_session" ]; then
			tmux kill-session -t "$tmp_session" 2>/dev/null || true
		fi
	fi

	# --- Process restoration (second pass) ---
	hook "pre-restore-pane-processes"

	local processes
	processes="$(tmux show-option -gqv '@resurrect-processes')"
	: "${processes:=vi vim view nvim emacs man less more tail top htop irssi weechat mutt}"

	if [ "$processes" != "false" ]; then
		local rules
		rules="$(tmux show-option -gqv '@resurrect-process-rules')"
		: "${rules:=vim:vim -S;nvim:nvim -S}"

		# Get actual pane map after structural restore
		actual_panes_file="$(mktemp "${TMPDIR:-/tmp}/resurrect-actual-panes.XXXXXX")"
		tmux list-panes -a -F '#{session_name}:#{window_index}:#{pane_index}' > "$actual_panes_file"

		awk -v actual_panes_file="$actual_panes_file" \
		    -v processes="$processes" \
		    -v rules="$rules" \
		    -v existing_file="$existing_file" \
		    -f "$RESTORE_JSON_AWK" \
		    -f "$RESTORE_PROCESSES_AWK" \
		    "$save_file" | while IFS=$'\t' read -r target cmd; do
			tmux send-keys -t "$target" "$cmd" C-m
		done
	fi

	hook "post-restore-all"
	msg "Tmux restore complete!"
}

main
