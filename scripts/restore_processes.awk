# Emit target/command pairs for process restoration.
# Variables supplied by restore.sh:
#   actual_panes_file - pane map after structural restore
#   processes         - @resurrect-processes value
#   rules             - @resurrect-process-rules value
#   existing_file     - snapshot of panes that existed before restore

BEGIN {
	init_json_helpers()

	# Build actual pane map: session:window:ordinal → actual pane index.
	while ((getline val < actual_panes_file) > 0) {
		if (val == "") continue
		# Split "session:window:pane" — but session may contain ":".
		# Use last two ":" separated fields as window and pane.
		last_colon = 0
		for (k = length(val); k >= 1; k--) {
			if (substr(val, k, 1) == ":") { last_colon = k; break }
		}
		if (last_colon == 0) continue
		pane_idx = substr(val, last_colon + 1)
		rest = substr(val, 1, last_colon - 1)

		prev_colon = 0
		for (k = length(rest); k >= 1; k--) {
			if (substr(rest, k, 1) == ":") { prev_colon = k; break }
		}
		if (prev_colon == 0) continue
		sess = substr(rest, 1, prev_colon - 1)
		win = substr(rest, prev_colon + 1)

		sw = sess ":" win
		pane_ord = actual_sw_count[sw]++
		actual_pane[sw ":" pane_ord] = pane_idx
	}
	close(actual_panes_file)

	# Build process list.
	if (processes == ":all:") {
		all_procs = 1
	} else {
		np = split(processes, proc_list, " ")
	}

	# Build rewrite rules.
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

	# Existing panes (skip process restore for these).
	while ((getline existing_pane < existing_file) > 0) {
		if (existing_pane != "") exist_pane[existing_pane] = 1
	}
	close(existing_file)

	# Common shell names to skip.
	shells["bash"] = 1; shells["fish"] = 1; shells["zsh"] = 1
	shells["sh"] = 1; shells["dash"] = 1; shells["ksh"] = 1
	shells["tcsh"] = 1; shells["csh"] = 1
}

/^\{"t":"pane"/ {
	s    = jv($0, "s")
	wi   = jv($0, "wi")
	pi   = jv($0, "pi")
	pcmd = jv($0, "pcmd")

	sw = s ":" wi
	pane_ord = window_ord[sw]++

	# Skip empty or shell-only processes.
	if (pcmd == "") next
	base_cmd = pcmd
	sub(/ .*/, "", base_cmd)
	sub(/.*\//, "", base_cmd)
	if (base_cmd in shells) next

	# Skip panes that existed before restore (idempotency).
	saved_target = s ":" wi "." pi
	if (saved_target in exist_pane) next

	# Look up actual pane index via ordinal mapping.
	api = actual_pane[sw ":" pane_ord]
	if (api == "") next
	target = s ":" wi "." api

	# Check process list.
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

	# Apply rewrite rules.
	restore_cmd = pcmd
	for (i = 1; i <= nrules; i++) {
		m = rule_match[i]
		if (substr(m, 1, 1) == "~") {
			# Substring match.
			m = substr(m, 2)
			if (index(pcmd, m) > 0) {
				restore_cmd = (rule_cmd[i] == "*") ? pcmd : rule_cmd[i]
				break
			}
		} else {
			# Word boundary match (first word of pcmd).
			if (first_word == m) {
				restore_cmd = (rule_cmd[i] == "*") ? pcmd : rule_cmd[i]
				break
			}
		}
	}

	# Output: target TAB command.
	printf "%s\t%s\n", target, restore_cmd
}
