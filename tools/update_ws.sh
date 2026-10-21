#!/usr/bin/env bash
# update_ws.sh -- bring every Argus repo up to date from GitHub, install new
# rosdeps, and rebuild the workspace when something changed. The everyday
# companion to setup-host.sh, for the workstation and the phone alike.
#
#   bash ~/argus_ws/src/argus_bringup/tools/update_ws.sh             # phone
#   bash ~/Documents/argus_ws/src/argus_bringup/tools/update_ws.sh   # workstation
#
# Repos: everything under the workspace's src/, plus any git repo named
# argus* next to the workspace (the setup-host.sh layout, so
# ~/Documents/argus-neural-codec, argus_safety_controller, argus_data and
# friends on the workstation). Those neighbors are updated, never cloned.
#
# Usage: bash update_ws.sh [options]
#
#   --ws PATH         Workspace root. Default: $ARGUS_WS, else ~/argus_ws,
#                     else ~/Documents/argus_ws.
#   --no-build        Update the repos only (no rosdep, no colcon).
#   --force-build     Build even if nothing changed since the last good build.
#   --test            Run colcon test and colcon test-result after building.
#   --refresh         Run apt-get update and rosdep update before installing
#                     dependencies (for when rosdep fails on stale lists).
#   --reset-diverged  When a branch has diverged from origin (for example
#                     after a history rewrite) and the repo has no local
#                     changes or untracked files, keep the old branch as
#                     backup/<branch>-<timestamp> and reset to origin.
#   -h, --help        Show this help.
#
# Environment:
#   ARGUS_WS           workspace root
#   ARGUS_REPOS        repos to clone into src/ when missing (space separated;
#                      default: argus_core argus_sensors argus_sim
#                      argus_inference argus_bringup)
#   ARGUS_GITHUB_BASE  clone URL prefix
#                      (default: git@github.com:Max-Gabriel-Susman)
#
# Safety: it fetches and fast-forwards only. It never pushes, commits,
# stashes or discards work. Unpushed commits, uncommitted changes and
# diverged branches are reported and left alone (--reset-diverged keeps a
# backup branch). A problem in one repo does not stop the others. It builds
# only when a repo's commit or tracked changes differ from the last good
# build, and inside the phone's proot container it builds with 2 workers
# and -j2.
#
# Exit status: 0 when nothing needs attention, 1 when something does
# (see the summary), 2 for usage errors.

SUM_NAME=()
SUM_BRANCH=()
SUM_STATE=()
SUM_LEVEL=()
SUM_NOTE=()
JUST_CLONED=""
STAMP=""
TMP_ERR=""
BUILD_STATE=""
BUILD_LEVEL=""
BUILD_NOTE=""
BUILT=0
DEPS_NOTE=""
TEST_STATE=""
TEST_LEVEL=""
TEST_NOTE=""
C_OK=""
C_WARN=""
C_BAD=""
C_DIM=""
C_OFF=""

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"
}

setup_colors() {
  if [ -t 1 ]; then
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_BAD=$'\033[31m'
    C_DIM=$'\033[2m'
    C_OFF=$'\033[0m'
  fi
}

# record NAME BRANCH STATE LEVEL NOTE   (LEVEL is ok, warn or bad)
record() {
  SUM_NAME+=("$1")
  SUM_BRANCH+=("$2")
  SUM_STATE+=("$3")
  SUM_LEVEL+=("$4")
  SUM_NOTE+=("$5")
}

# Join the non-empty arguments with "; ".
joinparts() {
  local out="" part
  for part in "$@"; do
    if [ -n "$part" ]; then out="${out:+$out; }$part"; fi
  done
  printf '%s' "$out"
}

# Most useful line of the last captured stderr.
first_error() {
  local line
  line="$(grep -m1 -E 'denied|fatal:|error:|Could not|timed out|unable to' "$TMP_ERR" 2>/dev/null)"
  if [ -z "$line" ]; then
    line="$(grep -m1 -v '^[[:space:]]*$' "$TMP_ERR" 2>/dev/null)"
  fi
  printf '%s' "${line:-no error output}"
}

# Why a fast-forward was refused, with the files git listed.
ff_block_reason() {
  local files
  files="$(grep $'^\t' "$TMP_ERR" 2>/dev/null | sed $'s/^\t//' | paste -sd ' ' -)"
  if grep -q 'Your local changes' "$TMP_ERR" 2>/dev/null; then
    printf 'uncommitted changes to %s conflict with the update; commit or stash them, then rerun' "${files:-some files}"
  elif grep -q 'untracked working tree files' "$TMP_ERR" 2>/dev/null; then
    printf 'untracked %s would be overwritten; move them aside, then rerun' "${files:-files}"
  else
    first_error
  fi
}

current_branch() {
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached'
}

clone_missing() {
  local ws="$1" base="${ARGUS_GITHUB_BASE:-git@github.com:Max-Gabriel-Susman}"
  local -a want
  read -r -a want <<< "${ARGUS_REPOS:-argus_core argus_sensors argus_sim argus_inference argus_bringup}"
  local name
  for name in "${want[@]}"; do
    if [ -e "$ws/src/$name" ]; then continue; fi
    printf '==> %s: cloning\n' "$name"
    if git clone --quiet "$base/$name.git" "$ws/src/$name" 2>"$TMP_ERR"; then
      JUST_CLONED="$JUST_CLONED $name"
      record "$name" "$(current_branch "$ws/src/$name")" "cloned" ok ""
    else
      record "$name" "" "CLONE FAILED" bad "$(first_error)"
    fi
  done
}

update_repo() {
  local dir="$1" name="$2" reset_diverged="$3"
  local branch upstream counts ahead behind before after dirty=""

  printf '==> %s\n' "$name"
  if ! git -C "$dir" fetch --prune --tags --force --quiet origin 2>"$TMP_ERR"; then
    record "$name" "$(current_branch "$dir")" "FETCH FAILED" bad "$(first_error)"
    return
  fi
  if ! branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD)"; then
    record "$name" "detached" "skipped" warn "detached HEAD, nothing to fast-forward"
    return
  fi
  if ! upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    record "$name" "$branch" "skipped" warn "no upstream branch (or it was deleted on origin)"
    return
  fi

  counts="$(git -C "$dir" rev-list --left-right --count 'HEAD...@{u}')"
  ahead="${counts%%[[:space:]]*}"
  behind="${counts##*[[:space:]]}"
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    dirty="uncommitted changes"
  fi
  before="$(git -C "$dir" rev-parse --short HEAD)"

  if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    record "$name" "$branch" "up to date" ok "$dirty"
  elif [ "$behind" -eq 0 ]; then
    record "$name" "$branch" "AHEAD" warn "$(joinparts "$ahead unpushed commit(s)" "$dirty")"
  elif [ "$ahead" -eq 0 ]; then
    if git -C "$dir" merge --ff-only --quiet '@{u}' >/dev/null 2>"$TMP_ERR"; then
      after="$(git -C "$dir" rev-parse --short HEAD)"
      git -C "$dir" log --oneline --no-decorate -n 5 "$before..$after" | sed 's/^/    /'
      record "$name" "$branch" "updated" ok "$(joinparts "$before..$after, $behind new commit(s)" "$dirty")"
    else
      record "$name" "$branch" "NOT UPDATED" bad "$(ff_block_reason)"
    fi
  elif [ "$reset_diverged" -eq 1 ]; then
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      record "$name" "$branch" "DIVERGED" bad "local changes or untracked files present, not resetting"
    else
      local backup="backup/$branch-$STAMP"
      if git -C "$dir" branch "$backup" HEAD 2>"$TMP_ERR" \
        && git -C "$dir" reset --hard --quiet '@{u}' 2>"$TMP_ERR"; then
        after="$(git -C "$dir" rev-parse --short HEAD)"
        record "$name" "$branch" "RESET" warn "now at $after from $upstream; old branch kept as $backup"
      else
        record "$name" "$branch" "RESET FAILED" bad "$(first_error)"
      fi
    fi
  else
    record "$name" "$branch" "DIVERGED" bad "$ahead local vs $behind remote commit(s); if origin is right, rerun with --reset-diverged"
  fi
}

# One line per repo: name, HEAD, and a checksum of tracked changes.
workspace_state() {
  local ws="$1" d
  for d in "$ws"/src/*/; do
    d="${d%/}"
    if [ ! -e "$d/.git" ]; then continue; fi
    printf '%s %s %s\n' "${d##*/}" \
      "$(git -C "$d" rev-parse HEAD 2>/dev/null)" \
      "$(git -C "$d" diff HEAD 2>/dev/null | cksum | cut -d' ' -f1)"
  done
}

install_deps() {
  local ws="$1" refresh="$2"
  if ! command -v rosdep >/dev/null 2>&1; then
    DEPS_NOTE="rosdep not found; dependencies not checked"
    return
  fi
  if [ "$refresh" -eq 1 ]; then
    printf '==> apt-get update\n'
    if [ "$(id -u)" -eq 0 ]; then apt-get update </dev/null; else sudo apt-get update; fi \
      || DEPS_NOTE="apt-get update failed"
    printf '==> rosdep update\n'
    rosdep update || DEPS_NOTE="$(joinparts "$DEPS_NOTE" "rosdep update failed")"
  fi
  printf '==> rosdep install\n'
  if ! (cd "$ws" && DEBIAN_FRONTEND=noninteractive rosdep install --from-paths src --ignore-src -y </dev/null); then
    if [ "$refresh" -eq 1 ]; then
      DEPS_NOTE="$(joinparts "$DEPS_NOTE" "rosdep install failed; see its output above")"
    else
      DEPS_NOTE="$(joinparts "$DEPS_NOTE" "rosdep install failed; if the package lists are stale, rerun with --refresh")"
    fi
  fi
}

build_ws() {
  local ws="$1" force="$2" refresh="$3" in_proot="$4"
  local state_file="$ws/build/.update_ws_state" current t0

  if [ -n "${XILINX_VIVADO:-}${XILINX_VITIS:-}" ]; then
    BUILD_STATE="skipped"
    BUILD_LEVEL=bad
    BUILD_NOTE="Vivado/Vitis settings are sourced in this shell and break colcon; rerun from a fresh terminal"
    return
  fi
  if [ -z "${ROS_DISTRO:-}" ] && [ -f /opt/ros/humble/setup.bash ]; then
    # shellcheck disable=SC1091
    . /opt/ros/humble/setup.bash
  fi
  if ! command -v colcon >/dev/null 2>&1; then
    BUILD_STATE="skipped"
    BUILD_LEVEL=bad
    BUILD_NOTE="colcon not found; is ROS 2 installed?"
    return
  fi

  current="$(workspace_state "$ws")"
  if [ "$force" -eq 0 ] && [ -d "$ws/install" ] && [ -f "$state_file" ] \
    && [ "$(cat "$state_file")" = "$current" ]; then
    BUILD_STATE="up to date"
    BUILD_LEVEL=ok
    BUILD_NOTE="nothing changed since the last good build; --force-build to rebuild"
    return
  fi

  install_deps "$ws" "$refresh"

  printf '==> colcon build\n'
  local -a args=(--symlink-install)
  if [ "$in_proot" -eq 1 ]; then
    args+=(--parallel-workers 2)
    export MAKEFLAGS="${MAKEFLAGS:--j2}"
  fi
  t0=$SECONDS
  if (cd "$ws" && colcon build "${args[@]}"); then
    mkdir -p "$ws/build" && printf '%s\n' "$current" > "$state_file"
    BUILD_STATE="ok"
    BUILD_LEVEL=ok
    BUILT=1
    BUILD_NOTE="$(( (SECONDS - t0) / 60 ))m $(( (SECONDS - t0) % 60 ))s"
  else
    rm -f "$state_file"
    BUILD_STATE="FAILED"
    BUILD_LEVEL=bad
    BUILD_NOTE="see $ws/log/latest_build"
  fi
}

test_ws() {
  local ws="$1" in_proot="$2" summary
  if [ "$BUILD_LEVEL" = bad ]; then
    TEST_STATE="skipped"
    TEST_LEVEL=warn
    TEST_NOTE="the build did not succeed"
    return
  fi
  printf '==> colcon test\n'
  local -a args=()
  if [ "$in_proot" -eq 1 ]; then args+=(--parallel-workers 2); fi
  (cd "$ws" && colcon test "${args[@]}")
  if summary="$(cd "$ws" && colcon test-result --verbose)"; then
    TEST_STATE="passed"
    TEST_LEVEL=ok
  else
    TEST_STATE="FAILED"
    TEST_LEVEL=bad
    printf '%s\n' "$summary"
  fi
  TEST_NOTE="$(printf '%s\n' "$summary" | grep -m1 '^Summary:' | sed 's/^Summary: //')"
}

level_color() {
  case "$1" in
    ok) printf '%s' "$C_OK" ;;
    warn) printf '%s' "$C_WARN" ;;
    *) printf '%s' "$C_BAD" ;;
  esac
}

print_summary() {
  local ws="$1" do_build="$2" do_test="$3" i status=0
  printf '\nSummary for %s\n' "$ws"
  for i in "${!SUM_NAME[@]}"; do
    if [ "${SUM_LEVEL[$i]}" = bad ]; then status=1; fi
    printf '  %s %s%s%s%s%s\n' "${SUM_NAME[$i]}" \
      "${SUM_BRANCH[$i]:+${C_DIM}[${SUM_BRANCH[$i]}]${C_OFF} }" \
      "$(level_color "${SUM_LEVEL[$i]}")" "${SUM_STATE[$i]}" "$C_OFF" \
      "${SUM_NOTE[$i]:+: ${SUM_NOTE[$i]}}"
  done
  if [ "$do_build" -eq 1 ]; then
    if [ "$BUILD_LEVEL" = bad ]; then status=1; fi
    printf '  build: %s%s%s%s\n' "$(level_color "$BUILD_LEVEL")" "$BUILD_STATE" "$C_OFF" \
      "${BUILD_NOTE:+ ($BUILD_NOTE)}"
    if [ -n "$DEPS_NOTE" ]; then
      printf '  deps: %s%s%s\n' "$C_WARN" "$DEPS_NOTE" "$C_OFF"
    fi
    if [ "$do_test" -eq 1 ]; then
      if [ "$TEST_LEVEL" = bad ]; then status=1; fi
      printf '  tests: %s%s%s%s\n' "$(level_color "$TEST_LEVEL")" "$TEST_STATE" "$C_OFF" \
        "${TEST_NOTE:+ ($TEST_NOTE)}"
    fi
  else
    printf '  build: skipped (--no-build)\n'
  fi
  if [ -z "$(git config --get user.email 2>/dev/null)" ]; then
    printf '  note: git has no user.email on this machine; set it before committing here\n'
  fi
  if [ "$BUILT" -eq 1 ]; then
    printf '  In shells that were already open: source %s/install/setup.bash\n' "$ws"
  fi
  return "$status"
}

main() {
  local ws="${ARGUS_WS:-}" do_build=1 force_build=0 do_test=0 refresh=0 reset_diverged=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --ws)
        if [ $# -lt 2 ]; then echo "--ws needs a path" >&2; return 2; fi
        ws="$2"
        shift 2
        ;;
      --ws=*) ws="${1#--ws=}"; shift ;;
      --no-build) do_build=0; shift ;;
      --force-build) force_build=1; shift ;;
      --test) do_test=1; shift ;;
      --refresh) refresh=1; shift ;;
      --reset-diverged) reset_diverged=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "Unknown option: $1 (try --help)" >&2; return 2 ;;
    esac
  done

  if ! command -v git >/dev/null 2>&1; then
    echo "git is not installed" >&2
    return 2
  fi
  if [ -z "$ws" ]; then
    local cand
    for cand in "$HOME/argus_ws" "$HOME/Documents/argus_ws"; do
      if [ -d "$cand/src" ]; then ws="$cand"; break; fi
    done
  fi
  if [ -z "$ws" ]; then
    echo "No workspace found (looked for ~/argus_ws/src and ~/Documents/argus_ws/src); pass --ws PATH." >&2
    return 2
  fi
  if [ ! -d "$ws/src" ]; then
    echo "No src/ directory in $ws; pass the workspace root with --ws." >&2
    return 2
  fi
  ws="$(cd "$ws" && pwd)"

  shopt -s nullglob
  setup_colors
  STAMP="$(date +%Y%m%d-%H%M%S)"
  TMP_ERR="$(mktemp)"
  trap 'rm -f "$TMP_ERR"' EXIT

  local in_proot=0
  if [ -n "${PD_CONTAINER:-}" ]; then in_proot=1; fi
  case "$(uname -r)" in *PRoot*) in_proot=1 ;; esac

  export GIT_TERMINAL_PROMPT=0
  if [ -z "${GIT_SSH_COMMAND:-}" ]; then
    export GIT_SSH_COMMAND="ssh -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
  fi

  if [ "$in_proot" -eq 1 ]; then
    printf 'Workspace: %s (proot: 2 build workers)\n' "$ws"
  else
    printf 'Workspace: %s\n' "$ws"
  fi

  clone_missing "$ws"

  local dir name
  for dir in "$ws"/src/*/; do
    dir="${dir%/}"
    name="${dir##*/}"
    case " $JUST_CLONED " in *" $name "*) continue ;; esac
    if [ ! -e "$dir/.git" ]; then
      record "$name" "" "skipped" warn "not a git repo"
      continue
    fi
    update_repo "$dir" "$name" "$reset_diverged"
  done

  # Neighbors of the workspace: updated when present, never cloned.
  for dir in "${ws%/*}"/argus[-_]*/; do
    dir="${dir%/}"
    if [ "$dir" = "$ws" ] || [ ! -e "$dir/.git" ]; then continue; fi
    update_repo "$dir" "${dir##*/}" "$reset_diverged"
  done

  if [ "$do_build" -eq 1 ]; then
    build_ws "$ws" "$force_build" "$refresh" "$in_proot"
    if [ "$do_test" -eq 1 ]; then test_ws "$ws" "$in_proot"; fi
  fi

  print_summary "$ws" "$do_build" "$do_test"
}

# Refuse to be sourced: that would leak settings into your shell.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run this with: bash ${BASH_SOURCE[0]}" >&2
  return 1
fi
# Kept on one line so bash has read it before main runs, which keeps the
# run safe even when the update rewrites this file.
main "$@"; exit $?
