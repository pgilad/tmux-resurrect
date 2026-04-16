#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/test_helpers.sh
source "$CURRENT_DIR/helpers/test_helpers.sh"

trap teardown_test_env EXIT

test_process_whitelist_matches_executable_basename() {
	setup_test_env

	local marker_file="$TEST_TMPDIR/whitelist-basename.log"
	local tail_bin
	tail_bin="$(command -v tail)"
	: > "$marker_file"

	tmux new-session -d -s exact -n main -c "$TEST_TMPDIR"
	tmux send-keys -t exact:0.0 "$tail_bin -f $marker_file" C-m
	wait_for "tail command to start" pane_command_is exact:0.0 tail

	run_save

	tmux kill-server
	tmux new-session -d -s scratch -n scratch -c "$TEST_TMPDIR"
	tmux set-option -gq '@resurrect-processes' 'tail'
	tmux set-option -gq '@resurrect-process-rules' ''

	run_restore
	wait_for "tail command to restore from basename whitelist" pane_command_is exact:0.0 tail
}

test_process_whitelist_supports_tilde_substring_matches() {
	setup_test_env

	local marker_file="$TEST_TMPDIR/whitelist-substring.log"
	local tail_bin
	tail_bin="$(command -v tail)"
	: > "$marker_file"

	tmux new-session -d -s substring -n main -c "$TEST_TMPDIR"
	tmux send-keys -t substring:0.0 "$tail_bin -f $marker_file" C-m
	wait_for "tail command to start" pane_command_is substring:0.0 tail

	run_save

	tmux kill-server
	tmux new-session -d -s scratch -n scratch -c "$TEST_TMPDIR"
	tmux set-option -gq '@resurrect-processes' '~whitelist-substring.log'
	tmux set-option -gq '@resurrect-process-rules' ''

	run_restore
	wait_for "tail command to restore from substring whitelist" pane_command_is substring:0.0 tail
}

main() {
	test_process_whitelist_matches_executable_basename
	test_process_whitelist_supports_tilde_substring_matches
}

main "$@"
