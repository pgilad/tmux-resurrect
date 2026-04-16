#!/usr/bin/env bash

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
	local dir last save_file script existing_file actual_panes_file

	dir="$(resurrect_dir)"
	last="$dir/last"

	# Resolve save file
	if [ ! -L "$last" ] && [ ! -f "$last" ]; then
		msg "Tmux resurrect: no save file found!"
		return 1
	fi
	save_file="$(readlink "$last" 2>/dev/null || true)"
	# Handle relative symlink target
	case "$save_file" in
		/*) ;; # absolute path, use as-is
		*)  save_file="$dir/$save_file" ;;
	esac
	if [ ! -f "$save_file" ]; then
		msg "Tmux resurrect: save file not found: $save_file"
		return 1
	fi

	# Validate header
	local version
	version="$(head -1 "$save_file" | sed -n 's/.*"v":\([0-9]*\).*/\1/p')"
	if [ -z "$version" ] || [ "$version" -gt 2 ] 2>/dev/null; then
		msg "Tmux resurrect: unsupported save format (version: ${version:-unknown})"
		return 1
	fi
	if ! awk '/^\{"t":"pane"/ { found=1; exit } END { exit !found }' "$save_file"; then
		msg "Tmux resurrect: save file contains no panes: $save_file"
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

	awk -v from_scratch="$from_scratch" \
	    -v base_index="$base_index" \
	    -v pane_base="$pane_base_index" \
	    -v existing_file="$existing_file" \
	'
	# --- JSON helpers ---
	function jv(line, key,    pat, val, i, c, result, j) {
		pat = "\"" key "\":"
		i = index(line, pat)
		if (i == 0) return ""
		val = substr(line, i + length(pat))
		if (substr(val, 1, 1) == "\"") {
			val = substr(val, 2)
			result = ""
			for (j = 1; j <= length(val); j++) {
				c = substr(val, j, 1)
				if (c == "\\" && j < length(val)) {
					j++
					c = substr(val, j, 1)
					if (c == "\"") result = result "\""
					else if (c == "\\") result = result "\\"
					else result = result c
				} else if (c == "\"") {
					break
				} else {
					result = result c
				}
			}
			return result
		} else {
			sub(/[^0-9-].*/, "", val)
			return val
		}
	}

	# Quote a string for tmux source-file (double-quote syntax)
	function tq(s) {
		gsub(/\\/, "\\\\", s)
		gsub(/"/, "\\\"", s)
		gsub(/\$/, "\\$", s)
		gsub(/#/, "\\#", s)
		return "\"" s "\""
	}

	BEGIN {
		# Parse existing panes into session/window/pane lookup tables
		while ((getline existing_pane < existing_file) > 0) {
			if (existing_pane == "") continue
			exist_pane[existing_pane] = 1
			# Derive session and window from "sess:win.pane"
			dot = index(existing_pane, ".")
			if (dot > 0) {
				sw = substr(existing_pane, 1, dot - 1)
				exist_window[sw] = 1
				colon = index(sw, ":")
				if (colon > 0) {
					exist_session[substr(sw, 1, colon - 1)] = 1
				}
			}
		}
		close(existing_file)
	}

	# Skip header
	/^\{"v":/ { next }

	# Capture state line
	/^\{"t":"state"/ {
		state_active = jv($0, "active")
		state_last = jv($0, "last")
		next
	}

	# Capture grouped session lines
	/^\{"t":"group"/ {
		gc++
		group_name[gc] = jv($0, "s")
		group_orig[gc] = jv($0, "orig")
		group_aw[gc] = jv($0, "aw")
		group_altw[gc] = jv($0, "altw")
		next
	}

	# Process pane lines — emit tmux commands for structure creation
	/^\{"t":"pane"/ {
		s   = jv($0, "s")
		wi  = jv($0, "wi")
		pi  = jv($0, "pi")
		path = jv($0, "path")
		wa  = jv($0, "wa")
		pa  = jv($0, "pa")
		wf  = jv($0, "wf")
		pt  = jv($0, "pt")
		wl  = jv($0, "wl")
		wn  = jv($0, "wn")
		ar  = jv($0, "ar")

		sw = s ":" wi

		# Track ordinal within window (for pane index mapping)
		if (!(sw in win_pane_count)) win_pane_count[sw] = 0
		pane_ord = win_pane_count[sw]
		win_pane_count[sw]++
		actual_pi = pane_base + pane_ord

		# Determine what needs to be created
		need_session = 0
		need_window = 0
		need_pane = 0
		skip = 0

		if (!(s in save_seen_session)) {
			save_seen_session[s] = 1
			if (!(s in exist_session)) {
				need_session = 1
			}
		}

		if (!(sw in save_seen_window)) {
			save_seen_window[sw] = 1
			if (!need_session && !(sw in exist_window)) {
				need_window = 1
			}
		}

		if (!need_session && !need_window) {
			saved_target = s ":" wi "." pi
			if (saved_target in exist_pane) {
				skip = 1
			} else {
				need_pane = 1
			}
		}

		# Emit creation commands
		if (need_session) {
			printf "new-session -d -s %s -c %s\n", tq(s), tq(path)
			if (wi != base_index) {
				printf "move-window -s %s -t %s\n", tq(s ":" base_index), tq(s ":" wi)
			}
		} else if (need_window) {
			printf "new-window -d -t %s -c %s\n", tq(sw), tq(path)
		} else if (need_pane) {
			printf "split-window -t %s -c %s\n", tq(sw), tq(path)
			printf "resize-pane -t %s -U 999\n", tq(sw)
		}

		# Track window properties (last pane seen for each window wins)
		win_layout[sw] = wl
		win_name[sw] = wn
		win_ar[sw] = ar

		# Track active pane per window (use actual index after creation)
		if (pa == 1 && !skip) {
			win_active_pane_pi[sw] = actual_pi
		}

		# Track pane title
		if (pt != "" && !skip) {
			ntitles++
			title_sw[ntitles] = sw
			title_pi[ntitles] = actual_pi
			title_val[ntitles] = pt
		}

		# Track zoom (window flag Z on the active pane)
		if (index(wf, "Z") > 0 && pa == 1) {
			zoom_window[sw] = 1
		}

		# Track active/alternate windows per session
		if (index(wf, "*") > 0) {
			session_active_win[s] = wi
		}
		if (index(wf, "-") > 0) {
			session_alt_win[s] = wi
		}

		# Remember session order for state restoration
		if (!(s in session_order_seen)) {
			session_order_seen[s] = 1
			session_count++
			session_order[session_count] = s
		}
	}

	END {
		# Phase B: Window properties — layout, name, automatic-rename
		for (sw in save_seen_window) {
			if (win_layout[sw] != "") {
				printf "select-layout -t %s %s\n", tq(sw), tq(win_layout[sw])
			}
			if (win_name[sw] != "") {
				printf "rename-window -t %s %s\n", tq(sw), tq(win_name[sw])
			}
			if (win_ar[sw] == "on") {
				printf "set-option -t %s automatic-rename on\n", tq(sw)
			} else if (win_ar[sw] == "off") {
				printf "set-option -t %s automatic-rename off\n", tq(sw)
			}
		}

		# Phase C: Active panes
		for (sw in win_active_pane_pi) {
			printf "select-pane -t %s\n", tq(sw "." win_active_pane_pi[sw])
		}

		# Pane titles
		for (i = 1; i <= ntitles; i++) {
			printf "select-pane -t %s -T %s\n", tq(title_sw[i] "." title_pi[i]), tq(title_val[i])
		}

		# Phase E: Zoom restoration
		for (sw in zoom_window) {
			printf "resize-pane -Z -t %s\n", tq(sw)
		}

		# Phase F: Grouped sessions
		for (i = 1; i <= gc; i++) {
			if (!(group_name[i] in exist_session)) {
				printf "new-session -d -s %s -t %s\n", tq(group_name[i]), tq(group_orig[i])
			}
			if (group_altw[i] != "" && group_altw[i] != "-1") {
				printf "select-window -t %s\n", tq(group_name[i] ":" group_altw[i])
			}
			if (group_aw[i] != "" && group_aw[i] != "-1") {
				printf "select-window -t %s\n", tq(group_name[i] ":" group_aw[i])
			}
		}

		# Phase G: Active/alternate windows per session
		# Set alternate windows first, then active (so active ends up selected)
		for (i = 1; i <= session_count; i++) {
			s = session_order[i]
			if (s in session_alt_win) {
				printf "select-window -t %s\n", tq(s ":" session_alt_win[s])
			}
		}
		for (i = 1; i <= session_count; i++) {
			s = session_order[i]
			if (s in session_active_win) {
				printf "select-window -t %s\n", tq(s ":" session_active_win[s])
			}
		}

		# State: switch client to alternate then active session
		if (state_last != "") {
			printf "switch-client -t %s\n", tq(state_last)
		}
		if (state_active != "") {
			printf "switch-client -t %s\n", tq(state_active)
		}
	}
	' "$save_file" > "$script"

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
		    -v pane_base="$pane_base_index" \
		'
		function jv(line, key,    pat, val, i, c, result, j) {
			pat = "\"" key "\":"
			i = index(line, pat)
			if (i == 0) return ""
			val = substr(line, i + length(pat))
			if (substr(val, 1, 1) == "\"") {
				val = substr(val, 2)
				result = ""
				for (j = 1; j <= length(val); j++) {
					c = substr(val, j, 1)
					if (c == "\\" && j < length(val)) {
						j++
						c = substr(val, j, 1)
						if (c == "\"") result = result "\""
						else if (c == "\\") result = result "\\"
						else result = result c
					} else if (c == "\"") {
						break
					} else {
						result = result c
					}
				}
				return result
			} else {
				sub(/[^0-9-].*/, "", val)
				return val
			}
		}

		BEGIN {
			# Build actual pane map: session:window:ordinal → actual pane index
			while ((getline val < actual_panes_file) > 0) {
				if (val == "") continue
				# Split "session:window:pane" — but session may contain ":"
				# Use last two ":" separated fields as window and pane
				# Find last ":"
				last_colon = 0
				for (k = length(val); k >= 1; k--) {
					if (substr(val, k, 1) == ":") { last_colon = k; break }
				}
				if (last_colon == 0) continue
				pane_idx = substr(val, last_colon + 1)
				rest = substr(val, 1, last_colon - 1)
				# Find second-to-last ":"
				prev_colon = 0
				for (k = length(rest); k >= 1; k--) {
					if (substr(rest, k, 1) == ":") { prev_colon = k; break }
				}
				if (prev_colon == 0) continue
				sess = substr(rest, 1, prev_colon - 1)
				win = substr(rest, prev_colon + 1)

				sw = sess ":" win
				ord = actual_sw_count[sw]++
				actual_pane[sw ":" ord] = pane_idx
			}
			close(actual_panes_file)

			# Build process list
			if (processes == ":all:") {
				all_procs = 1
			} else {
				np = split(processes, proc_list, " ")
			}

			# Build rewrite rules
			nr = split(rules, rule_arr, ";")
			nrules = 0
			for (i = 1; i <= nr; i++) {
				ci = index(rule_arr[i], ":")
				if (ci > 0) {
					nrules++
					rule_match[nrules] = substr(rule_arr[i], 1, ci - 1)
					rule_cmd[nrules] = substr(rule_arr[i], ci + 1)
				}
			}

			# Existing panes (skip process restore for these)
			while ((getline existing_pane < existing_file) > 0) {
				if (existing_pane != "") exist_pane[existing_pane] = 1
			}
			close(existing_file)

			# Common shell names to skip
			shells["bash"] = 1; shells["fish"] = 1; shells["zsh"] = 1
			shells["sh"] = 1; shells["dash"] = 1; shells["ksh"] = 1
			shells["tcsh"] = 1; shells["csh"] = 1
		}

		/^\{"t":"pane"/ {
			s    = jv($0, "s")
			wi   = jv($0, "wi")
			pi   = jv($0, "pi")
			pcmd = jv($0, "pcmd")
			cmd  = jv($0, "cmd")

			sw = s ":" wi
			ord = window_ord[sw]++

			# Skip empty or shell-only processes
			if (pcmd == "") next
			base_cmd = pcmd
			sub(/ .*/, "", base_cmd)
			sub(/.*\//, "", base_cmd)
			if (base_cmd in shells) next

			# Skip panes that existed before restore (idempotency)
			saved_target = s ":" wi "." pi
			if (saved_target in exist_pane) next

			# Look up actual pane index via ordinal mapping
			api = actual_pane[sw ":" ord]
			if (api == "") next
			target = s ":" wi "." api

			# Check process list
			first_word = pcmd
			sub(/ .*/, "", first_word)

			if (!all_procs) {
				matched = 0
				for (i = 1; i <= np; i++) {
					p = proc_list[i]
					if (p == "") continue
					if (substr(p, 1, 1) == "~") {
						p = substr(p, 2)
						if (p != "" && index(pcmd, p) > 0) { matched = 1; break }
					} else if (first_word == p || base_cmd == p) {
						matched = 1
						break
					}
				}
				if (!matched) next
			}

			# Apply rewrite rules
			restore_cmd = pcmd
			for (i = 1; i <= nrules; i++) {
				m = rule_match[i]
				if (substr(m, 1, 1) == "~") {
					# Substring match
					m = substr(m, 2)
					if (index(pcmd, m) > 0) {
						restore_cmd = (rule_cmd[i] == "*") ? pcmd : rule_cmd[i]
						break
					}
				} else {
					# Word boundary match (first word of pcmd)
					if (first_word == m) {
						restore_cmd = (rule_cmd[i] == "*") ? pcmd : rule_cmd[i]
						break
					}
				}
			}

			# Output: target TAB command
			printf "%s\t%s\n", target, restore_cmd
		}
		' "$save_file" | while IFS=$'\t' read -r target cmd; do
			tmux send-keys -t "$target" "$cmd" C-m
		done
	fi

	hook "post-restore-all"
	msg "Tmux restore complete!"
}

main
