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

tmux_value() {
	local format="$1"
	local marker raw

	marker="__tmux_resurrect_value_${BASHPID:-$$}_${RANDOM}_${RANDOM}__"
	raw="$(tmux display-message -p "$format"; printf '%s' "$marker")"
	raw="${raw%"$marker"}"
	raw="${raw%$'\n'}"
	printf '%s' "$raw"
}

tmux_target_value() {
	local target="$1"
	local format="$2"
	local marker raw

	marker="__tmux_resurrect_value_${BASHPID:-$$}_${RANDOM}_${RANDOM}__"
	raw="$(tmux display-message -p -t "$target" "$format"; printf '%s' "$marker")"
	raw="${raw%"$marker"}"
	raw="${raw%$'\n'}"
	printf '%s' "$raw"
}

json_escape() {
	local s="${1-}"
	local out="" c code escaped
	local LC_ALL=C
	local i

	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		if [ "$c" = "\\" ]; then
			out="${out}\\\\"
		elif [ "$c" = '"' ]; then
			out="${out}\\\""
		else
			printf -v code '%d' "'$c"
			case "$code" in
				8) out="${out}\\b" ;;
				9) out="${out}\\t" ;;
				10) out="${out}\\n" ;;
				12) out="${out}\\f" ;;
				13) out="${out}\\r" ;;
				[0-9] | [12][0-9] | 3[01])
					printf -v escaped '\\u%04X' "$code"
					out="${out}${escaped}"
					;;
				*) out="${out}${c}" ;;
			esac
		fi
	done

	printf '%s' "$out"
}

pane_process_command() {
	local pane_pid="$1"
	local ps_file="$2"

	awk -v pane_pid="$pane_pid" '
		{
			n = index($0, " ")
			if (n <= 0) next
			if (substr($0, 1, n - 1) == pane_pid) {
				print substr($0, n + 1)
				exit
			}
		}
	' "$ps_file"
}

is_grouped_secondary_session_id() {
	local session_id="$1"

	[[ "$grouped_secondary_session_ids" == *$'\n'"$session_id"$'\n'* ]]
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
	local grouped_secondary_session_ids=$'\n' group_lines="" prev_group="" orig=""
	local session_group session_id session_name
	while IFS=$'\t' read -r session_group session_id; do
		[ -n "$session_id" ] || continue
		session_name="$(tmux_target_value "${session_id}:" "#{session_name}")"
		if [ "$session_group" != "$prev_group" ]; then
			prev_group="$session_group"
			orig="$session_name"
		else
			grouped_secondary_session_ids="${grouped_secondary_session_ids}${session_id}"$'\n'
			# Per-session window lookups (grouped sessions are rare: usually 0)
			local aw altw
			aw="$(tmux list-windows -t "$session_id" -F '#{window_flags} #{window_index}' 2>/dev/null | awk '$1 ~ /\*/ {print $2}')"
			altw="$(tmux list-windows -t "$session_id" -F '#{window_flags} #{window_index}' 2>/dev/null | awk '$1 ~ /-/ {print $2}')"
			aw="${aw:--1}"
			altw="${altw:--1}"
			group_lines="${group_lines}$(printf '{"t":"group","s":"%s","orig":"%s","aw":%s,"altw":%s}' \
				"$(json_escape "$session_name")" \
				"$(json_escape "$orig")" \
				"$aw" \
				"$altw")"$'\n'
		fi
	done < <(tmux list-sessions -F "#{session_grouped}${d}#{session_group}${d}#{session_id}" 2>/dev/null | awk -F'\t' '$1 == "1" { print $2 "\t" $3 }' | sort -t "$d" -k1,1 -k2,2)

	# Emit NDJSON: header + panes + grouped sessions + client state
	{
		# Header
		printf '{"v":2,"ts":"%s","tmux":"%s"}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$(json_escape "$(tmux -V | cut -d' ' -f2)")"

		# Panes. Use pane IDs as stable targets and read each tmux string
		# field separately so user-controlled tabs/newlines cannot corrupt
		# field boundaries before JSON escaping.
		local pane_target pane_session_id session_name window_index pane_index
		local pane_current_path pane_current_command pane_pid
		local window_active pane_active window_flags pane_title window_layout
		local window_name automatic_rename pane_command
		while IFS=$'\t' read -r pane_session_id window_index pane_index; do
			[ -n "$pane_session_id" ] || continue

			if is_grouped_secondary_session_id "$pane_session_id"; then
				continue
			fi
			pane_target="${pane_session_id}:${window_index}.${pane_index}"

			session_name="$(tmux_target_value "$pane_target" "#{session_name}")"
			pane_current_path="$(tmux_target_value "$pane_target" "#{pane_current_path}")"
			pane_current_command="$(tmux_target_value "$pane_target" "#{pane_current_command}")"
			pane_pid="$(tmux_target_value "$pane_target" "#{pane_pid}")"
			window_active="$(tmux_target_value "$pane_target" "#{window_active}")"
			pane_active="$(tmux_target_value "$pane_target" "#{pane_active}")"
			window_flags="$(tmux_target_value "$pane_target" "#{window_flags}")"
			pane_title="$(tmux_target_value "$pane_target" "#{pane_title}")"
			window_layout="$(tmux_target_value "$pane_target" "#{window_layout}")"
			window_name="$(tmux_target_value "$pane_target" "#{window_name}")"
			automatic_rename="$(tmux_target_value "$pane_target" "#{?automatic-rename,on,off}")"
			pane_command="$(pane_process_command "$pane_pid" "$ps_file")"

			printf '{"t":"pane","s":"%s","wi":%s,"pi":%s,"path":"%s","cmd":"%s","pcmd":"%s","wa":%s,"pa":%s,"wf":"%s","pt":"%s","wl":"%s","wn":"%s","ar":"%s"}\n' \
				"$(json_escape "$session_name")" \
				"$window_index" \
				"$pane_index" \
				"$(json_escape "$pane_current_path")" \
				"$(json_escape "$pane_current_command")" \
				"$(json_escape "$pane_command")" \
				"$window_active" \
				"$pane_active" \
				"$(json_escape "$window_flags")" \
				"$(json_escape "$pane_title")" \
				"$(json_escape "$window_layout")" \
				"$(json_escape "$window_name")" \
				"$(json_escape "$automatic_rename")"
		done < <(tmux list-panes -a -F "#{session_id}${d}#{window_index}${d}#{pane_index}")

		# Grouped session lines
		if [ -n "$group_lines" ]; then
			printf '%s' "$group_lines"
		fi

		# Client state
		local active_session last_session
		active_session="$(tmux_value "#{client_session}")"
		last_session="$(tmux_value "#{client_last_session}")"
		printf '{"t":"state","active":"%s","last":"%s"}\n' \
			"$(json_escape "$active_session")" \
			"$(json_escape "$last_session")"
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
