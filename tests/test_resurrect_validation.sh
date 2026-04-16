#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/test_helpers.sh
source "$CURRENT_DIR/helpers/test_helpers.sh"

trap teardown_test_env EXIT

test_restore_fails_when_no_save_exists() {
	setup_test_env

	tmux new-session -d -s scratch

	if run_restore; then
		fail "restore should fail when no save file exists"
	fi
	assert_session_exists scratch
}

test_restore_rejects_legacy_format() {
	setup_test_env

	local dir
	dir="$(save_dir)"
	mkdir -p "$dir"
	cp "$CURRENT_DIR/fixtures/legacy_restore_file.txt" "$dir/legacy_restore_file.txt"
	ln -sf legacy_restore_file.txt "$dir/last"

	tmux new-session -d -s scratch

	if run_restore; then
		fail "restore should reject legacy tab-delimited save files"
	fi
	assert_session_exists scratch
}

test_restore_rejects_v2_file_without_panes() {
	setup_test_env

	local dir
	dir="$(save_dir)"
	mkdir -p "$dir"
	cp "$CURRENT_DIR/fixtures/no_panes.jsonl" "$dir/no_panes.jsonl"
	ln -sf no_panes.jsonl "$dir/last"

	tmux new-session -d -s scratch

	if run_restore; then
		fail "restore should reject v2 save files without pane rows"
	fi
	assert_session_exists scratch
}

main() {
	test_restore_fails_when_no_save_exists
	test_restore_rejects_legacy_format
	test_restore_rejects_v2_file_without_panes
}

main "$@"
