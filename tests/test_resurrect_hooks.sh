#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/test_helpers.sh
source "$CURRENT_DIR/helpers/test_helpers.sh"

trap teardown_test_env EXIT

install_hook_recorder() {
	TEST_HOOK_LOG="$TEST_TMPDIR/hooks.log"
	TEST_HOOK_RECORDER="$TEST_TMPDIR/record-hook"
	export TEST_HOOK_LOG TEST_HOOK_RECORDER

	cat > "$TEST_HOOK_RECORDER" <<'HOOK_RECORDER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_HOOK_LOG"
HOOK_RECORDER
	chmod +x "$TEST_HOOK_RECORDER"
}

assert_hook_logged() {
	local expected="$1"
	grep -F "$expected" "$TEST_HOOK_LOG" >/dev/null || fail "missing hook log entry: $expected"
}

test_save_and_restore_hooks_are_called_with_expected_arguments() {
	setup_test_env
	install_hook_recorder

	local project_dir="$TEST_TMPDIR/project"
	mkdir -p "$project_dir"

	tmux new-session -d -s hooks -n main -c "$project_dir"
	tmux set-option -gq '@resurrect-hook-post-save-layout' "$TEST_HOOK_RECORDER post-save-layout"
	tmux set-option -gq '@resurrect-hook-post-save-all' "$TEST_HOOK_RECORDER post-save-all"

	run_save

	local save_file
	save_file="$(last_save_file)"
	assert_hook_logged "post-save-layout $save_file"
	assert_hook_logged "post-save-all"

	tmux kill-server
	tmux new-session -d -s scratch
	tmux set-option -gq '@resurrect-hook-pre-restore-all' "$TEST_HOOK_RECORDER pre-restore-all"
	tmux set-option -gq '@resurrect-hook-pre-restore-pane-processes' "$TEST_HOOK_RECORDER pre-restore-pane-processes"
	tmux set-option -gq '@resurrect-hook-post-restore-all' "$TEST_HOOK_RECORDER post-restore-all"

	run_restore

	assert_hook_logged "pre-restore-all"
	assert_hook_logged "pre-restore-pane-processes"
	assert_hook_logged "post-restore-all"
}

main() {
	test_save_and_restore_hooks_are_called_with_expected_arguments
}

main "$@"
