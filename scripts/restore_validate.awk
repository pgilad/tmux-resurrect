# Validate a v2 tmux-resurrect save file before restore mutates tmux state.
# Uses helpers from restore_json.awk.  On failure, prints one tab-delimited
# diagnostic record to stdout and exits non-zero:
#   UNSUPPORTED<TAB>version
#   NO_PANES<TAB>
#   INVALID<TAB>human-readable detail

function fail(code, detail) {
	printf "%s\t%s\n", code, detail
	failed = 1
	exit 1
}

function require_key(key) {
	if (!has_json_key($0, key)) {
		fail("INVALID", "line " NR ": missing key \"" key "\"")
	}
}

function require_nonempty_key(key,    val) {
	require_key(key)
	val = jv($0, key)
	if (val == "") {
		fail("INVALID", "line " NR ": key \"" key "\" must not be empty")
	}
	return val
}

function require_int_key(key,    val) {
	require_key(key)
	val = jv($0, key)
	if (!is_int(val)) {
		fail("INVALID", "line " NR ": key \"" key "\" must be an integer")
	}
	return val
}

function require_nonnegative_int_key(key,    val) {
	val = require_int_key(key)
	if (!is_nonnegative_int(val)) {
		fail("INVALID", "line " NR ": key \"" key "\" must be a non-negative integer")
	}
	return val
}

function require_bool_number_key(key,    val) {
	val = require_int_key(key)
	if (!is_bool_number(val)) {
		fail("INVALID", "line " NR ": key \"" key "\" must be 0 or 1")
	}
	return val
}

function validate_pane(    ar) {
	require_nonempty_key("s")
	require_nonnegative_int_key("wi")
	require_nonnegative_int_key("pi")
	require_key("path")
	require_key("cmd")
	require_key("pcmd")
	require_bool_number_key("pa")
	require_key("wf")
	require_key("pt")
	require_nonempty_key("wl")
	require_key("wn")
	ar = require_nonempty_key("ar")
	if (ar != "on" && ar != "off") {
		fail("INVALID", "line " NR ": key \"ar\" must be \"on\" or \"off\"")
	}
}

function validate_group() {
	require_nonempty_key("s")
	require_nonempty_key("orig")
	require_int_key("aw")
	require_int_key("altw")
}

function validate_state() {
	require_key("active")
	require_key("last")
}

NR == 1 {
	if (!has_json_key($0, "v")) {
		fail("UNSUPPORTED", "unknown")
	}
	version = jv($0, "v")
	if (version == "") {
		version = "unknown"
	}
	# The only implemented format is numeric v2.  Reject older, newer, and
	# string-typed versions before any tmux state is changed.
	if (version != "2" || $0 !~ /"v":2([,}])/) {
		fail("UNSUPPORTED", version)
	}
	next
}

{
	if ($0 == "") {
		fail("INVALID", "line " NR ": empty line")
	}
	if (substr($0, 1, 1) != "{") {
		fail("INVALID", "line " NR ": expected JSON object")
	}
	require_key("t")
	type = jv($0, "t")
	if (type == "pane") {
		pane_count++
		validate_pane()
	} else if (type == "group") {
		validate_group()
	} else if (type == "state") {
		state_count++
		validate_state()
	} else {
		fail("INVALID", "line " NR ": unknown record type \"" type "\"")
	}
}

END {
	if (failed) {
		exit 1
	}
	if (NR == 0) {
		printf "UNSUPPORTED\tunknown\n"
		exit 1
	}
	if (pane_count == 0) {
		printf "NO_PANES\t\n"
		exit 1
	}
}
