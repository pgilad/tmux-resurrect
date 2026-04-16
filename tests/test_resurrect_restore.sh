#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/test_helpers.sh
source "$CURRENT_DIR/helpers/test_helpers.sh"

trap teardown_test_env EXIT

create_source_environment() {
	local project_dir="$1"
	local src_dir="$2"
	local logs_dir="$3"
	local grouped_dir="$4"

	tmux new-session -d -s alpha -n main -c "$project_dir"
	tmux rename-window -t alpha:0 work
	tmux split-window -t alpha:0 -h -c "$src_dir"
	tmux select-pane -t alpha:0.1 -T 'right pane'
	tmux select-pane -t alpha:0.1
	tmux select-layout -t alpha:0 even-horizontal >/dev/null
	tmux new-window -d -t alpha:1 -n logs -c "$logs_dir"

	tmux new-session -d -s beta -n sleeper -c "$logs_dir"
	tmux send-keys -t beta:0.0 'sleep 300' C-m
	wait_for "sleep command to start" pane_command_is beta:0.0 sleep

	tmux new-session -d -s primary -n shared -c "$grouped_dir"
	tmux new-session -d -s mirror -t primary

	tmux set-option -gq '@resurrect-processes' ':all:'
	tmux set-option -gq '@resurrect-process-rules' ''
}

assert_restored_environment() {
	local project_dir="$1"
	local src_dir="$2"
	local logs_dir="$3"
	local grouped_dir="$4"

	assert_session_missing scratch
	assert_session_exists alpha
	assert_session_exists beta
	assert_session_exists primary
	assert_session_exists mirror

	assert_tmux_format_eq alpha:0.0 '#{pane_current_path}' "$project_dir" "alpha first pane path"
	assert_tmux_format_eq alpha:0.1 '#{pane_current_path}' "$src_dir" "alpha split pane path"
	assert_tmux_format_eq alpha:0.1 '#{pane_title}' 'right pane' "pane title"
	assert_tmux_format_eq alpha:1.0 '#{window_name}' logs "second window name"
	assert_tmux_format_eq alpha:1.0 '#{pane_current_path}' "$logs_dir" "second window path"
	assert_tmux_format_eq primary:0.0 '#{pane_current_path}' "$grouped_dir" "grouped source path"

	local primary_group mirror_group
	primary_group="$(tmux display-message -p -t primary '#{session_group}')"
	mirror_group="$(tmux display-message -p -t mirror '#{session_group}')"
	assert_eq "$primary_group" "$mirror_group" "grouped sessions should share a group"

	wait_for "restored sleep command" pane_command_is beta:0.0 sleep
}

test_restore_round_trips_structure_processes_groups_and_idempotency() {
	setup_test_env

	local project_dir="$TEST_TMPDIR/project one"
	local src_dir="$project_dir/src"
	local logs_dir="$TEST_TMPDIR/logs"
	local grouped_dir="$TEST_TMPDIR/grouped"
	mkdir -p "$src_dir" "$logs_dir" "$grouped_dir"
	project_dir="$(canonical_path "$project_dir")"
	src_dir="$(canonical_path "$src_dir")"
	logs_dir="$(canonical_path "$logs_dir")"
	grouped_dir="$(canonical_path "$grouped_dir")"

	create_source_environment "$project_dir" "$src_dir" "$logs_dir" "$grouped_dir"
	run_save

	tmux kill-server
	tmux new-session -d -s scratch -n scratch -c "$TEST_TMPDIR"
	tmux set-option -gq '@resurrect-processes' ':all:'
	tmux set-option -gq '@resurrect-process-rules' ''

	run_restore
	assert_restored_environment "$project_dir" "$src_dir" "$logs_dir" "$grouped_dir"

	local before after
	before="$(pane_count)"
	run_restore
	after="$(pane_count)"
	assert_eq "$before" "$after" "idempotent restore should not create duplicate panes"
}

main() {
	test_restore_round_trips_structure_processes_groups_and_idempotency
}

main "$@"
