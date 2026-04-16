#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/test_helpers.sh
source "$CURRENT_DIR/helpers/test_helpers.sh"

trap teardown_test_env EXIT

assert_saved_jsonl_covers_tmux_state() {
	local file="$1"
	local project_dir="$2"
	local src_dir="$3"
	local logs_dir="$4"

	jq -e -s \
		--arg project_dir "$project_dir" \
		--arg src_dir "$src_dir" \
		--arg logs_dir "$logs_dir" \
		'
		.[0].v == 2 and
		(.[0].ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
		(.[0].tmux | type == "string") and
		(any(.[]; .t == "state")) and
		(any(.[]; .t == "pane" and .s == "alpha" and .wi == 0 and .pi == 0 and .path == $project_dir and .wn == "work \"main\"" and .ar == "off")) and
		(any(.[]; .t == "pane" and .s == "alpha" and .wi == 0 and .pi == 1 and .path == $src_dir and .pt == "right \"quoted\" pane")) and
		(any(.[]; .t == "pane" and .s == "alpha" and .wi == 1 and .path == $logs_dir and .wn == "logs")) and
		(any(.[]; .t == "pane" and .s == "beta" and (.pcmd | test("sleep 300"))))
		' "$file" >/dev/null
}

test_save_writes_v2_jsonl_and_dedupes_unchanged_state() {
	setup_test_env

	local project_dir="$TEST_TMPDIR/project one"
	local src_dir="$project_dir/src"
	local logs_dir="$TEST_TMPDIR/logs"
	mkdir -p "$src_dir" "$logs_dir"
	project_dir="$(canonical_path "$project_dir")"
	src_dir="$(canonical_path "$src_dir")"
	logs_dir="$(canonical_path "$logs_dir")"

	tmux new-session -d -s alpha -n editor -c "$project_dir"
	tmux rename-window -t alpha:0 'work "main"'
	tmux set-window-option -t alpha:0 automatic-rename off >/dev/null
	tmux split-window -t alpha:0 -h -c "$src_dir"
	tmux select-pane -t alpha:0.1 -T 'right "quoted" pane'
	tmux new-window -d -t alpha:1 -n logs -c "$logs_dir"
	tmux new-session -d -s beta -n sleeper -c "$logs_dir"
	tmux send-keys -t beta:0.0 'sleep 300' C-m
	wait_for "sleep command to start" pane_command_is beta:0.0 sleep

	run_save

	local dir file
	dir="$(save_dir)"
	file="$(last_save_file "$dir")"
	assert_file_exists "$file"
	assert_eq "1" "$(count_save_files "$dir")" "initial save file count"
	assert_saved_jsonl_covers_tmux_state "$file" "$project_dir" "$src_dir" "$logs_dir"

	sleep 1
	run_save
	assert_eq "1" "$(count_save_files "$dir")" "unchanged saves should be deduplicated"
	assert_eq "$file" "$(last_save_file "$dir")" "last symlink should remain on unchanged save"
}

test_save_respects_configured_resurrect_dir_expansion() {
	setup_test_env

	local project_dir="$TEST_TMPDIR/project"
	local configured_dir="$HOME/custom saves/\$HOSTNAME"
	local expected_dir
	expected_dir="$HOME/custom saves/$(hostname)"
	mkdir -p "$project_dir"

	tmux new-session -d -s custom -n main -c "$project_dir"
	tmux set-option -gq '@resurrect-dir' "$configured_dir"

	run_save

	local file
	file="$(last_save_file "$expected_dir")"
	assert_file_exists "$file"
	jq -e -s '.[0].v == 2 and any(.[]; .t == "pane" and .s == "custom")' "$file" >/dev/null
}

test_save_writes_group_metadata_for_secondary_grouped_sessions() {
	setup_test_env

	local project_dir="$TEST_TMPDIR/grouped"
	mkdir -p "$project_dir"

	tmux new-session -d -s primary -n shared -c "$project_dir"
	tmux new-session -d -s mirror -t primary

	run_save

	local file
	file="$(last_save_file)"
	jq -e -s '
		(any(.[]; .t == "pane" and .s == "primary")) and
		(all(.[]; .t != "pane" or .s != "mirror")) and
		(any(.[]; .t == "group" and .s == "mirror" and .orig == "primary"))
		' "$file" >/dev/null
}

main() {
	test_save_writes_v2_jsonl_and_dedupes_unchanged_state
	test_save_respects_configured_resurrect_dir_expansion
	test_save_writes_group_metadata_for_secondary_grouped_sessions
}

main "$@"
