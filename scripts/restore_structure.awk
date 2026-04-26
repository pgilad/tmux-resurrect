# Generate tmux commands that recreate the saved session/window/pane structure.
# Variables supplied by restore.sh:
#   base_index    - tmux base-index option
#   pane_base     - tmux pane-base-index option
#   existing_file - snapshot of panes that existed before restore

BEGIN {
	init_json_helpers()

	# Parse existing panes into session/window/pane lookup tables.
	while ((getline existing_pane < existing_file) > 0) {
		if (existing_pane == "") continue
		exist_pane[existing_pane] = 1
		# Derive session and window from "sess:win.pane".
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

# Skip header.
/^\{"v":/ { next }

# Capture state line.
/^\{"t":"state"/ {
	state_active = jv($0, "active")
	state_last = jv($0, "last")
	next
}

# Capture grouped session lines.
/^\{"t":"group"/ {
	gc++
	group_name[gc] = jv($0, "s")
	group_orig[gc] = jv($0, "orig")
	group_aw[gc] = jv($0, "aw")
	group_altw[gc] = jv($0, "altw")
	next
}

# Process pane lines — emit tmux commands for structure creation.
/^\{"t":"pane"/ {
	s   = jv($0, "s")
	wi  = jv($0, "wi")
	pi  = jv($0, "pi")
	path = jv($0, "path")
	pa  = jv($0, "pa")
	wf  = jv($0, "wf")
	pt  = jv($0, "pt")
	wl  = jv($0, "wl")
	wn  = jv($0, "wn")
	ar  = jv($0, "ar")

	sw = s ":" wi

	# Track ordinal within window (for pane index mapping).
	if (!(sw in win_pane_count)) win_pane_count[sw] = 0
	pane_ord = win_pane_count[sw]
	win_pane_count[sw]++
	actual_pi = pane_base + pane_ord

	# Determine what needs to be created.
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

	# Emit creation commands.
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

	# Track window properties (last pane seen for each window wins).
	win_layout[sw] = wl
	win_name[sw] = wn
	win_ar[sw] = ar

	# Track active pane per window (use actual index after creation).
	if (pa == 1 && !skip) {
		win_active_pane_pi[sw] = actual_pi
	}

	# Track pane title.
	if (pt != "" && !skip) {
		ntitles++
		title_sw[ntitles] = sw
		title_pi[ntitles] = actual_pi
		title_val[ntitles] = pt
	}

	# Track zoom (window flag Z on the active pane).
	if (index(wf, "Z") > 0 && pa == 1) {
		zoom_window[sw] = 1
	}

	# Track active/alternate windows per session.
	if (index(wf, "*") > 0) {
		session_active_win[s] = wi
	}
	if (index(wf, "-") > 0) {
		session_alt_win[s] = wi
	}

	# Remember session order for state restoration.
	if (!(s in session_order_seen)) {
		session_order_seen[s] = 1
		session_count++
		session_order[session_count] = s
	}
}

END {
	# Phase B: Window properties — layout, name, automatic-rename.
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

	# Phase C: Active panes.
	for (sw in win_active_pane_pi) {
		printf "select-pane -t %s\n", tq(sw "." win_active_pane_pi[sw])
	}

	# Pane titles.
	for (i = 1; i <= ntitles; i++) {
		printf "select-pane -t %s -T %s\n", tq(title_sw[i] "." title_pi[i]), tq(title_val[i])
	}

	# Phase E: Zoom restoration.
	for (sw in zoom_window) {
		printf "resize-pane -Z -t %s\n", tq(sw)
	}

	# Phase F: Grouped sessions.
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

	# Phase G: Active/alternate windows per session.
	# Set alternate windows first, then active (so active ends up selected).
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

	# State: switch client to alternate then active session.
	if (state_last != "") {
		printf "switch-client -t %s\n", tq(state_last)
	}
	if (state_active != "") {
		printf "switch-client -t %s\n", tq(state_active)
	}
}
