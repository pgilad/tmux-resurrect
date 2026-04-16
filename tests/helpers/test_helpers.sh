#!/usr/bin/env bash

TEST_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT_DIR="$(cd "$TEST_HELPERS_DIR/../.." && pwd)"
TEST_ORIGINAL_PATH="$PATH"
TEST_ORIGINAL_SHELL="${SHELL:-}"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

require_command() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"
}

setup_test_env() {
	teardown_test_env

	require_command tmux
	require_command jq

	TEST_REAL_TMUX="$(command -v tmux)"
	TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/tmux-resurrect-test.XXXXXX")"
	TEST_HOME="$TEST_TMPDIR/home"
	TEST_XDG_DATA_HOME="$TEST_TMPDIR/xdg"
	TEST_BIN="$TEST_TMPDIR/bin"
	TEST_TMUX_SOCKET_NAME="tmux-resurrect-test-$$-$RANDOM"

	mkdir -p "$TEST_HOME" "$TEST_XDG_DATA_HOME" "$TEST_BIN"

	cat > "$TEST_BIN/tmux" <<'TMUX_WRAPPER'
#!/usr/bin/env bash
exec "$TEST_REAL_TMUX" -f /dev/null -L "$TEST_TMUX_SOCKET_NAME" "$@"
TMUX_WRAPPER
	chmod +x "$TEST_BIN/tmux"

	export TEST_REAL_TMUX TEST_TMPDIR TEST_HOME TEST_XDG_DATA_HOME TEST_BIN TEST_TMUX_SOCKET_NAME
	export HOME="$TEST_HOME"
	export XDG_DATA_HOME="$TEST_XDG_DATA_HOME"
	export PATH="$TEST_BIN:$TEST_ORIGINAL_PATH"
	export SHELL=/bin/sh
}

teardown_test_env() {
	if [ -n "${TEST_TMUX_SOCKET_NAME:-}" ] && [ -n "${TEST_REAL_TMUX:-}" ]; then
		"$TEST_REAL_TMUX" -f /dev/null -L "$TEST_TMUX_SOCKET_NAME" kill-server >/dev/null 2>&1 || true
	fi
	if [ -n "${TEST_TMPDIR:-}" ]; then
		rm -rf "$TEST_TMPDIR"
	fi
	unset TEST_TMPDIR TEST_HOME TEST_XDG_DATA_HOME TEST_BIN TEST_TMUX_SOCKET_NAME TEST_REAL_TMUX
	export PATH="$TEST_ORIGINAL_PATH"
	if [ -n "$TEST_ORIGINAL_SHELL" ]; then
		export SHELL="$TEST_ORIGINAL_SHELL"
	else
		unset SHELL
	fi
}

save_dir() {
	printf '%s/tmux/resurrect\n' "$XDG_DATA_HOME"
}

last_save_file() {
	local dir="${1:-$(save_dir)}"
	local last="$dir/last"
	local target

	[ -L "$last" ] || fail "missing last symlink: $last"
	target="$(readlink "$last")" || fail "could not read last symlink: $last"
	case "$target" in
		/*) printf '%s\n' "$target" ;;
		*)  printf '%s/%s\n' "$dir" "$target" ;;
	esac
}

count_save_files() {
	local dir="${1:-$(save_dir)}"

	if [ ! -d "$dir" ]; then
		printf '0\n'
		return
	fi
	find "$dir" -type f -name 'tmux_resurrect_*.jsonl' | wc -l | tr -d ' '
}

canonical_path() {
	local path="$1"

	(cd "$path" && pwd -P)
}

run_save() {
	"$TEST_ROOT_DIR/scripts/save.sh" quiet
}

run_restore() {
	"$TEST_ROOT_DIR/scripts/restore.sh"
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"

	if [ "$expected" != "$actual" ]; then
		fail "$message: expected [$expected], got [$actual]"
	fi
}

assert_file_exists() {
	local file="$1"
	[ -f "$file" ] || fail "missing file: $file"
}

assert_session_exists() {
	local session="$1"
	tmux has-session -t "$session" 2>/dev/null || fail "missing tmux session: $session"
}

assert_session_missing() {
	local session="$1"
	if tmux has-session -t "$session" 2>/dev/null; then
		fail "unexpected tmux session exists: $session"
	fi
}

assert_tmux_format_eq() {
	local target="$1"
	local format="$2"
	local expected="$3"
	local message="$4"
	local actual

	actual="$(tmux display-message -p -t "$target" "$format")"
	assert_eq "$expected" "$actual" "$message"
}

wait_for() {
	local description="$1"
	shift
	local attempts=50

	until "$@"; do
		attempts=$((attempts - 1))
		if [ "$attempts" -le 0 ]; then
			fail "timed out waiting for $description"
		fi
		sleep 0.1
	done
}

pane_command_is() {
	local target="$1"
	local expected="$2"
	local actual

	actual="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)"
	[ "$actual" = "$expected" ]
}

pane_count() {
	tmux list-panes -a -F x | wc -l | tr -d ' '
}
