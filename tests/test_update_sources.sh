#!/usr/bin/env bash
# Tests for build.sh update-sources functionality.
#
# Uses local bare git repos as fake remotes so tests run offline and fast.
# pip-compile and pybuild-deps must be on PATH for lockfile tests.
#
# Usage:
#   PATH=".tox/update-sources/bin:$PATH" bash tests/test_update_sources.sh
#   tox -e test
#
set -uo pipefail

# ── Test runner ──────────────────────────────────────────────────────────

_PASS=0
_FAIL=0
_SKIP=0

assert() {
  local desc="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "    ASSERTION FAILED: ${desc}"
  echo "      command: $*"
  return 1
}

assert_file_exists() { assert "file exists: $1" test -f "$1"; }
assert_symlink()     { assert "symlink exists: $1" test -L "$1"; }
assert_no_symlink()  { assert "no symlink: $1" test ! -L "$1"; }
assert_grep()        { assert "grep '$1' in $2" grep -q "$1" "$2"; }
assert_no_grep() {
  if grep -q "$1" "$2" 2>/dev/null; then
    echo "    ASSERTION FAILED: '$1' should not appear in $2"
    return 1
  fi
}

assert_link_target() {
  local link="$1" expected="$2"
  local actual
  actual="$(readlink "$1")"
  assert "symlink $1 -> $2 (actual: ${actual})" test "${actual}" = "${expected}"
}

assert_field() {
  local file="$1" stream="$2" name="$3" field="$4" expected="$5"
  local actual
  actual=$(awk -v s="${stream}" -v n="${name}" '$1==s && $2==n {print $'${field}'}' "${file}")
  assert "sources.txt ${name} field ${field} == ${expected} (actual: ${actual})" \
    test "${actual}" = "${expected}"
}

run_test() {
  local name="$1"

  _setup_fixture

  local rc=0
  # Run in subshell with set -e so first failed assertion stops the test
  ( set -e; "${name}" ) || rc=$?

  if [[ ${rc} -eq 0 ]]; then
    echo "  PASS  ${name}"
    ((_PASS++))
  elif [[ ${rc} -eq 99 ]]; then
    echo "  SKIP  ${name}"
    ((_SKIP++))
  else
    echo "  FAIL  ${name}"
    ((_FAIL++))
    if [[ -f "${TEST_DIR}/build.log" ]]; then
      echo "    --- build.log (last 20 lines) ---"
      tail -20 "${TEST_DIR}/build.log" | sed 's/^/    /'
      echo "    ---"
    fi
  fi

  _teardown_fixture
}

skip_test() {
  echo "    skipping: $1"
  return 99
}

# ── Fixture ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""
UPSTREAM_REQ=""
UPSTREAM_SVC=""
REQ_HASH_OLD=""
REQ_HASH_NEW=""
SVC_HASH_OLD=""
SVC_HASH_NEW=""

_init_work_repo() {
  local dir="$1"
  git init -b master "${dir}" >/dev/null 2>&1
  git -C "${dir}" config user.email "test@test.com"
  git -C "${dir}" config user.name "Test"
}

_setup_fixture() {
  TEST_DIR="$(mktemp -d)"
  local work

  # ── Upstream requirements repo (2 commits) ──
  UPSTREAM_REQ="${TEST_DIR}/upstream/requirements.git"
  mkdir -p "${TEST_DIR}/upstream"
  work="$(mktemp -d)"
  _init_work_repo "${work}"

  echo "six==1.17.0" > "${work}/upper-constraints.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1

  printf 'six==1.17.0\npbr==7.0.3\n' > "${work}/upper-constraints.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1

  git clone --bare "${work}" "${UPSTREAM_REQ}" >/dev/null 2>&1
  rm -rf "${work}"

  REQ_HASH_OLD="$(git -C "${UPSTREAM_REQ}" rev-parse master~1)"
  REQ_HASH_NEW="$(git -C "${UPSTREAM_REQ}" rev-parse master)"

  # ── Upstream service repo (2 commits) ──
  UPSTREAM_SVC="${TEST_DIR}/upstream/test-svc.git"
  work="$(mktemp -d)"
  _init_work_repo "${work}"

  echo "six" > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v1" >/dev/null 2>&1

  printf 'six\npbr\n' > "${work}/requirements.txt"
  git -C "${work}" add -A >/dev/null && git -C "${work}" commit -m "v2" >/dev/null 2>&1

  git clone --bare "${work}" "${UPSTREAM_SVC}" >/dev/null 2>&1
  rm -rf "${work}"

  SVC_HASH_OLD="$(git -C "${UPSTREAM_SVC}" rev-parse master~1)"
  SVC_HASH_NEW="$(git -C "${UPSTREAM_SVC}" rev-parse master)"

  # ── Symlink build.sh ──
  ln -s "${SCRIPT_DIR}/build.sh" "${TEST_DIR}/build.sh"

  # ── Containers tree ──
  mkdir -p "${TEST_DIR}/containers/test-svc/src"
  mkdir -p "${TEST_DIR}/containers/test-svc/test-svc/src"

  cat > "${TEST_DIR}/containers/test-svc/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} master ${REQ_HASH_OLD}
master test-svc ${UPSTREAM_SVC} master ${SVC_HASH_OLD}
EOF

  echo "FROM scratch" > "${TEST_DIR}/containers/test-svc/test-svc/Containerfile"
  echo "python3"      > "${TEST_DIR}/containers/test-svc/test-svc/bindeps.txt"
  echo "gcc"          > "${TEST_DIR}/containers/test-svc/test-svc/builddeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc/test-svc/pythondeps.txt"
  touch                 "${TEST_DIR}/containers/test-svc/test-svc/pythonbuilddeps.txt"
}

_teardown_fixture() {
  [[ -n "${TEST_DIR}" ]] && rm -rf "${TEST_DIR}"
}

# Helper: run build.sh inside TEST_DIR with env vars passed as arguments.
# Usage: _run_build STREAM=master [SKIP_HASH_UPDATE=1 ...]
_run_build() {
  (cd "${TEST_DIR}" && env "$@" ./build.sh update-sources test-svc) >"${TEST_DIR}/build.log" 2>&1
}

# ── Tests ────────────────────────────────────────────────────────────────

test_updates_hashes_to_branch_tip() {
  _run_build STREAM=master

  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  assert_field "${src}" master upper-constraints 5 "${REQ_HASH_NEW}"
  assert_field "${src}" master test-svc 5 "${SVC_HASH_NEW}"
}

test_fetches_upper_constraints() {
  _run_build STREAM=master

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "six==1.17.0" "${uc}"
  assert_grep "pbr==7.0.3" "${uc}"
}

test_generates_rpms_in_yaml() {
  _run_build STREAM=master

  local rpms="${TEST_DIR}/containers/test-svc/rpms.in.yaml"
  assert_file_exists "${rpms}"
  assert_grep "python3" "${rpms}"
  assert_grep "gcc" "${rpms}"
}

test_generates_requirements_lock() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master

  local lock="${TEST_DIR}/containers/test-svc/requirements.lock.master"
  assert_file_exists "${lock}"
  assert_grep "six" "${lock}"
}

test_generates_buildrequirements_lock() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master

  assert_file_exists "${TEST_DIR}/containers/test-svc/buildrequirements.lock.master"
}

test_creates_default_stream_symlinks() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master DEFAULT_STREAM=master

  local d="${TEST_DIR}/containers/test-svc"
  assert_symlink "${d}/upper-constraints.txt"
  assert_symlink "${d}/requirements.lock"
  assert_symlink "${d}/buildrequirements.lock"
  assert_link_target "${d}/requirements.lock" "requirements.lock.master"
  assert_link_target "${d}/buildrequirements.lock" "buildrequirements.lock.master"
  assert_link_target "${d}/upper-constraints.txt" "upper-constraints.txt.master"
}

test_skips_symlinks_for_non_default_stream() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"
  command -v pybuild-deps >/dev/null 2>&1 || skip_test "pybuild-deps not on PATH"

  _run_build STREAM=master DEFAULT_STREAM=other

  local d="${TEST_DIR}/containers/test-svc"
  assert_no_symlink "${d}/requirements.lock"
  assert_no_symlink "${d}/buildrequirements.lock"
  assert_no_symlink "${d}/upper-constraints.txt"
}

test_skip_hash_update_preserves_hashes() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  _run_build STREAM=master SKIP_HASH_UPDATE=1

  local src="${TEST_DIR}/containers/test-svc/sources.txt"
  assert_field "${src}" master upper-constraints 5 "${REQ_HASH_OLD}"
  assert_field "${src}" master test-svc 5 "${SVC_HASH_OLD}"

  assert_file_exists "${TEST_DIR}/containers/test-svc/requirements.lock.master"
}

test_skip_hash_update_fetches_constraints_at_pinned_hash() {
  _run_build STREAM=master SKIP_HASH_UPDATE=1

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "six==1.17.0" "${uc}"
  assert_no_grep "pbr" "${uc}"
}

test_hash_in_branch_field_upper_constraints() {
  cat > "${TEST_DIR}/containers/test-svc/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} ${REQ_HASH_OLD} ${REQ_HASH_NEW}
master test-svc ${UPSTREAM_SVC} master ${SVC_HASH_OLD}
EOF

  _run_build STREAM=master

  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" master upper-constraints 5 "${REQ_HASH_OLD}"

  local uc="${TEST_DIR}/containers/test-svc/upper-constraints.txt.master"
  assert_file_exists "${uc}"
  assert_grep "six==1.17.0" "${uc}"
  assert_no_grep "pbr" "${uc}"
}

test_hash_in_branch_field_regular_repo() {
  command -v pip-compile >/dev/null 2>&1 || skip_test "pip-compile not on PATH"

  cat > "${TEST_DIR}/containers/test-svc/sources.txt" <<EOF
master upper-constraints ${UPSTREAM_REQ} master ${REQ_HASH_OLD}
master test-svc ${UPSTREAM_SVC} ${SVC_HASH_OLD} ${SVC_HASH_NEW}
EOF

  _run_build STREAM=master

  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" master test-svc 5 "${SVC_HASH_OLD}"
  assert_file_exists "${TEST_DIR}/containers/test-svc/requirements.lock.master"
}

test_preexisting_checkout_is_preserved() {
  local src_dir="${TEST_DIR}/containers/test-svc/src/test-svc"
  mkdir -p "${src_dir}"
  echo "local-dev" > "${src_dir}/MARKER"
  echo "six" > "${src_dir}/requirements.txt"

  _run_build STREAM=master

  assert_file_exists "${src_dir}/MARKER"
  assert_grep "local-dev" "${src_dir}/MARKER"
  assert_field "${TEST_DIR}/containers/test-svc/sources.txt" master test-svc 5 "${SVC_HASH_OLD}"
}

# ── Run all tests ────────────────────────────────────────────────────────

echo "=== update-sources tests ==="
echo ""

TESTS=(
  test_updates_hashes_to_branch_tip
  test_fetches_upper_constraints
  test_generates_rpms_in_yaml
  test_generates_requirements_lock
  test_generates_buildrequirements_lock
  test_creates_default_stream_symlinks
  test_skips_symlinks_for_non_default_stream
  test_skip_hash_update_preserves_hashes
  test_skip_hash_update_fetches_constraints_at_pinned_hash
  test_hash_in_branch_field_upper_constraints
  test_hash_in_branch_field_regular_repo
  test_preexisting_checkout_is_preserved
)

for t in "${TESTS[@]}"; do
  run_test "${t}"
done

echo ""
echo "=== ${_PASS} passed, ${_FAIL} failed, ${_SKIP} skipped ==="

[[ ${_FAIL} -eq 0 ]]
