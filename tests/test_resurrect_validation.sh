#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/helpers/test_helpers.sh
source "$CURRENT_DIR/helpers/test_helpers.sh"

trap teardown_test_env EXIT

create_saved_session() {
	local session="$1"

	tmux new-session -d -s "$session" -n main -c "$TEST_TMPDIR"
	run_save
	last_save_file
}

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

test_restore_supports_regular_last_jsonl_file() {
	setup_test_env

	local dir file
	file="$(create_saved_session regular_jsonl)"
	dir="$(save_dir)"
	rm -f "$dir/last"
	cp "$file" "$dir/last"

	tmux kill-server
	tmux new-session -d -s scratch

	run_restore
	assert_session_exists regular_jsonl
	assert_session_missing scratch
}

test_restore_supports_regular_last_relative_pointer() {
	setup_test_env

	local dir file
	file="$(create_saved_session regular_pointer)"
	dir="$(save_dir)"
	rm -f "$dir/last"
	printf '%s\n' "$(basename "$file")" > "$dir/last"

	tmux kill-server
	tmux new-session -d -s scratch

	run_restore
	assert_session_exists regular_pointer
	assert_session_missing scratch
}

test_restore_fails_for_broken_last_symlink() {
	setup_test_env

	local dir
	dir="$(save_dir)"
	mkdir -p "$dir"
	ln -sf missing.jsonl "$dir/last"

	tmux new-session -d -s scratch

	if run_restore; then
		fail "restore should fail when last points at a missing file"
	fi
	assert_session_exists scratch
}

test_restore_fails_for_empty_regular_last_pointer() {
	setup_test_env

	local dir
	dir="$(save_dir)"
	mkdir -p "$dir"
	: > "$dir/last"

	tmux new-session -d -s scratch

	if run_restore; then
		fail "restore should fail when last pointer is empty"
	fi
	assert_session_exists scratch
}

main() {
	test_restore_fails_when_no_save_exists
	test_restore_rejects_legacy_format
	test_restore_rejects_v2_file_without_panes
	test_restore_supports_regular_last_jsonl_file
	test_restore_supports_regular_last_relative_pointer
	test_restore_fails_for_broken_last_symlink
	test_restore_fails_for_empty_regular_last_pointer
}

main "$@"
