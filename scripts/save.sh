#!/usr/bin/env bash

QUIET="$1"

resurrect_dir() {
	local opt
	opt="$(tmux show-option -gqv '@resurrect-dir')"
	if [ -n "$opt" ]; then
		echo "$opt" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g"
		return
	fi
	if [ -d "$HOME/.tmux/resurrect" ]; then
		echo "$HOME/.tmux/resurrect"
		return
	fi
	echo "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
}

msg() {
	[ "$QUIET" = "quiet" ] && return
	tmux display-message "$1"
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

main() {
	local dir file tmp last ps_file d pane_count

	dir="$(resurrect_dir)"
	mkdir -p "$dir"

	pane_count="$(tmux list-panes -a -F x 2>/dev/null | wc -l | tr -d ' ')"
	if ! [[ "$pane_count" =~ ^[0-9]+$ ]] || [ "$pane_count" -eq 0 ]; then
		msg "Tmux resurrect: no panes to save"
		return 1
	fi

	file="$dir/tmux_resurrect_$(date +%Y%m%dT%H%M%S).jsonl"
	tmp="$(mktemp "$dir/.save-tmp.XXXXXX")"
	last="$dir/last"
	ps_file="$(mktemp "${TMPDIR:-/tmp}/resurrect-ps.XXXXXX")"
	d=$'\t'

	trap 'rm -f "$tmp" "$ps_file"' EXIT

	msg "Saving..."

	# One ps snapshot for all panes
	ps -ao ppid=,args= | sed 's/^ *//' > "$ps_file"

	# Identify grouped (secondary) sessions. For each group, the first session
	# (by session_id sort order) is the original; the rest are secondary.
	local grouped_secondary="" group_lines="" prev_group="" orig=""
	while IFS=$'\t' read -r session_group _session_id session_name; do
		if [ "$session_group" != "$prev_group" ]; then
			prev_group="$session_group"
			orig="$session_name"
		else
			grouped_secondary="${grouped_secondary}${d}${session_name}${d}"
			# Per-session window lookups (grouped sessions are rare: usually 0)
			local aw altw
			aw="$(tmux list-windows -t "$session_name" -F '#{window_flags} #{window_index}' 2>/dev/null | awk '$1 ~ /\*/ {print $2}')"
			altw="$(tmux list-windows -t "$session_name" -F '#{window_flags} #{window_index}' 2>/dev/null | awk '$1 ~ /-/ {print $2}')"
			aw="${aw:--1}"
			altw="${altw:--1}"
			local je_name je_orig
			je_name="$(printf '%s' "$session_name" | sed 's/\\/\\\\/g; s/"/\\"/g')"
			je_orig="$(printf '%s' "$orig" | sed 's/\\/\\\\/g; s/"/\\"/g')"
			group_lines="${group_lines}{\"t\":\"group\",\"s\":\"${je_name}\",\"orig\":\"${je_orig}\",\"aw\":${aw},\"altw\":${altw}}
"
		fi
	done < <(tmux list-sessions -F "#{session_grouped}${d}#{session_group}${d}#{session_id}${d}#{session_name}" 2>/dev/null | grep "^1" | cut -c3- | sort)

	# Pane format: all fields in one tmux call
	local fmt="#{session_name}${d}#{window_index}${d}#{pane_index}${d}#{pane_current_path}${d}#{pane_current_command}${d}#{pane_pid}${d}#{window_active}${d}#{pane_active}${d}#{window_flags}${d}#{pane_title}${d}#{window_layout}${d}#{window_name}${d}#{?automatic-rename,on,off}"

	# Emit NDJSON: header + panes + grouped sessions + client state
	{
		# Header
		printf '{"v":2,"ts":"%s","tmux":"%s"}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$(tmux -V | cut -d' ' -f2)"

		# Panes — one tmux command, one awk process joins with ps data
		tmux list-panes -a -F "$fmt" | \
			awk -F'\t' -v ps_file="$ps_file" -v grouped="$grouped_secondary" '
			function je(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
			BEGIN {
				while ((getline line < ps_file) > 0) {
					n = index(line, " ")
					if (n > 0) {
						pid = substr(line, 1, n-1)
						cmd = substr(line, n+1)
						if (!(pid in C)) C[pid] = cmd
					}
				}
				close(ps_file)
			}
			{
				# Skip panes from secondary grouped sessions
				if (grouped != "" && index(grouped, "\t" $1 "\t") > 0) next

				pcmd = ($6 in C) ? C[$6] : ""
				printf "{\"t\":\"pane\",\"s\":\"%s\",\"wi\":%s,\"pi\":%s,\"path\":\"%s\",\"cmd\":\"%s\",\"pcmd\":\"%s\",\"wa\":%s,\"pa\":%s,\"wf\":\"%s\",\"pt\":\"%s\",\"wl\":\"%s\",\"wn\":\"%s\",\"ar\":\"%s\"}\n",
					je($1), $2, $3, je($4), je($5), je(pcmd), $7, $8, je($9), je($10), je($11), je($12), $13
			}'

		# Grouped session lines
		if [ -n "$group_lines" ]; then
			printf '%s' "$group_lines"
		fi

		# Client state (pipe through awk for JSON escaping)
		tmux display-message -p "#{client_session}${d}#{client_last_session}" | \
			awk -F'\t' '
			function je(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
			{ printf "{\"t\":\"state\",\"active\":\"%s\",\"last\":\"%s\"}\n", je($1), je($2) }'
	} > "$tmp"

	# Atomic rename
	mv "$tmp" "$file"
	trap 'rm -f "$ps_file"' EXIT

	hook "post-save-layout" "$file"

	# Update last symlink only if content changed (skip header for comparison)
	local prev prev_file
	prev="$(readlink "$last" 2>/dev/null || true)"
	if [ -n "$prev" ]; then
		prev_file="$dir/$prev"
	fi
	if [ -z "$prev" ] || [ ! -f "$prev_file" ] || \
	   ! cmp -s <(tail -n +2 "$file") <(tail -n +2 "$prev_file"); then
		ln -sf "$(basename "$file")" "$last"
	else
		rm -f "$file"
	fi

	hook "post-save-all"

	# Cleanup old backups: keep files from last N days, minimum 5 copies
	local delete_after
	delete_after="$(tmux show-option -gqv '@resurrect-delete-backup-after')"
	: "${delete_after:=30}"
	local old_file
	local -a old_files=()
	# Save filenames are generated by this script; ls -t is used here for portable mtime sorting.
	# shellcheck disable=SC2012
	while IFS= read -r old_file; do
		old_files+=("$old_file")
	done < <(ls -t "$dir"/tmux_resurrect_*.jsonl 2>/dev/null | tail -n +6)
	if [ ${#old_files[@]} -gt 0 ]; then
		find "${old_files[@]}" -type f -mtime "+${delete_after}" -exec rm -f {} \; 2>/dev/null
	fi

	msg "Tmux environment saved!"
}

main
