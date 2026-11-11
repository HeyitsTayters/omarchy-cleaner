#!/bin/bash
# shellcheck shell=bash
#
# Checkup: read-only checks that answer "is my work backed up, and is anything
# wrong with this system?". Nothing here changes a file. Each check prints
# items as
#   <status>\t<label>\t<detail>\t<path>
# where status is ok, info, warn or error. bin/omarchy-cleaner turns them into
# JSON (see cmd_checkup) and stores the result next to the last scan.
#
# This file is sourced by bin/omarchy-cleaner; it never runs on its own.

OC_CHECKUP_FILE="$OC_STATE_DIR/checkup.json"

# id|title|description
OC_CHECKS=(
  "projects|Projects|Git repositories under your project folders: committed, and pushed to a remote."
  "config-backup|Config backup|When your config backup repository last saved and pushed a backup."
  "failed-units|Failed services|System and user services that failed."
  "crashes|Recent crashes|Programs that crashed and dumped core in the last 7 days."
  "pacnew|Pending config merges|.pacnew and .pacsave files that pacman left in /etc for you to merge (sudo pacdiff)."
  "config-drift|Changed from Omarchy defaults|Files in ~/.config that differ from the copies Omarchy ships. Expected for anything you customised."
)

oc_check_emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}"; }

# "3 h ago", "12 days ago" for a Unix timestamp.
oc_ago() {
  local s=$(($(date +%s) - $1))
  ((s < 0)) && s=0
  if ((s < 90)); then echo "just now"
  elif ((s < 5400)); then echo "$((s / 60)) min ago"
  elif ((s < 129600)); then echo "$((s / 3600)) h ago"
  else echo "$((s / 86400)) days ago"; fi
}

oc_tilde() { local p=$1; [[ $p == "$HOME"/* ]] && p="~/${p#"$HOME"/}"; echo "$p"; }

# --- projects ---------------------------------------------------------------

# Project folders to check: config "projectRoots" (JSON array), else ~/Work,
# ~/Projects, ~/projects, ~/src, ~/code and ~/dev when they exist.
oc_project_roots() {
  local roots
  roots=$(jq -r '.projectRoots // empty | .[]' "$OC_CONFIG_FILE" 2>/dev/null || true)
  if [[ -n $roots ]]; then
    sed "s|^~|$HOME|" <<<"$roots"
    return 0
  fi
  local d
  for d in Work Projects projects src code dev; do
    [[ -d $HOME/$d ]] && echo "$HOME/$d"
  done
  return 0
}

# Newest modification time among the paths `git status` lists, so a project
# being edited right now is not reported as forgotten work.
oc_repo_last_edit() {
  local repo=$1 newest=0 t path
  while IFS= read -r -d '' path; do
    t=$(stat -c %Y -- "$repo/$path" 2>/dev/null) || continue
    ((t > newest)) && newest=$t
  done < <(git -C "$repo" status --porcelain=v1 -z --untracked-files=normal 2>/dev/null |
    tr '\0' '\n' | sed -E 's/^.{3}//' | grep -v '^$' | tr '\n' '\0')
  echo "$newest"
}

oc_check_repo() {
  local repo=$1 name dirty ahead last
  name=$(oc_tilde "$repo")
  if ! git -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    oc_check_emit error "$name" "never committed: only on this computer" "$repo"
    return
  fi
  if [[ -z $(git -C "$repo" remote 2>/dev/null) ]]; then
    oc_check_emit error "$name" "no remote: only on this computer" "$repo"
    return
  fi
  local -a problems=()
  local status=ok
  if ! git -C "$repo" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    problems+=("branch $(git -C "$repo" branch --show-current 2>/dev/null) was never pushed")
    status=warn
  else
    ahead=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    if ((ahead > 0)); then
      problems+=("$ahead commit(s) not pushed")
      status=warn
    fi
  fi
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | grep -c . || true)
  if ((dirty > 0)); then
    last=$(oc_repo_last_edit "$repo")
    if ((last > 0 && $(date +%s) - last < 3600)); then
      problems+=("$dirty change(s) being edited")
    else
      problems+=("$dirty uncommitted change(s), last edited $(oc_ago "${last:-0}")")
      status=warn
    fi
  fi
  if ((${#problems[@]} == 0)); then
    oc_check_emit ok "$name" "committed and pushed" "$repo"
  else
    local IFS=';'
    oc_check_emit "$status" "$name" "$(sed 's/;/ · /g' <<<"${problems[*]}")" "$repo"
  fi
}

# True when $1 sits inside a git repository that ignores it (vendored
# upstream checkouts, build folders).
oc_ignored_by_parent() {
  local dir=$1 parent
  parent=$(git -C "$(dirname -- "$dir")" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ $parent != "$dir" ]] && git -C "$parent" check-ignore -q -- "$dir" 2>/dev/null
}

# Walks a project folder: repositories are checked; folders without git that
# hold repositories are descended into (once); other non-empty folders are
# reported as not in git.
oc_walk_projects() {
  local dir=$1 depth=$2 child
  while IFS= read -r -d '' child; do
    [[ -L $child ]] && continue
    oc_is_ignored "$child" && continue
    if [[ -e $child/.git ]]; then
      [[ -f $child/.git ]] && continue  # submodule: covered by its parent
      oc_check_repo "$child"
    elif [[ -n $(find "$child" -mindepth 2 -maxdepth 3 -name .git -print -quit 2>/dev/null) ]] && ((depth < 2)); then
      oc_walk_projects "$child" $((depth + 1))
    elif [[ -n $(find "$child" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
      oc_check_emit warn "$(oc_tilde "$child")" "not in git: no backup ($(oc_human "$(oc_path_bytes "$child")"))" "$child"
    fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | sort -z)
}

oc_check_projects() {
  local root found=0
  while IFS= read -r root; do
    [[ -d $root ]] || continue
    found=1
    if [[ -e $root/.git ]]; then oc_check_repo "$root"; else oc_walk_projects "$root" 1; fi
  done < <(oc_project_roots)
  ((found == 1)) ||
    oc_check_emit info "No project folders found" "set them with: omarchy-cleaner config set projectRoots '[\"~/Work\"]'" ""
}

# --- config-backup ----------------------------------------------------------

# The config backup repository: config "configBackupRepo", else
# ~/omarchy-backup when it is a git repository.
oc_config_backup_repo() {
  local repo
  repo=$(oc_config_get configBackupRepo "")
  repo=${repo/#\~/$HOME}
  [[ -z $repo && -d $HOME/omarchy-backup/.git ]] && repo=$HOME/omarchy-backup
  [[ -n $repo && -d $repo/.git ]] && echo "$repo"
  return 0
}

# Command that makes a new config backup: config "backupCommand", else an
# executable backup.sh at the top of the backup repository.
oc_config_backup_command() {
  local cmd repo
  cmd=$(oc_config_get backupCommand "")
  if [[ -n $cmd ]]; then echo "${cmd/#\~/$HOME}"; return 0; fi
  repo=$(oc_config_backup_repo)
  [[ -n $repo && -x $repo/backup.sh ]] && echo "$repo/backup.sh"
  return 0
}

oc_check_config_backup() {
  local repo last age days ahead status=ok detail
  repo=$(oc_config_backup_repo)
  if [[ -z $repo ]]; then
    oc_check_emit warn "No config backup found" "point to your backup repo: omarchy-cleaner config set configBackupRepo PATH" ""
    return
  fi
  last=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 0)
  age=$(($(date +%s) - last))
  days=$((age / 86400))
  detail="last backup $(oc_ago "$last")"
  if ((days >= 30)); then status=error; elif ((days >= 7)); then status=warn; fi
  if [[ -z $(git -C "$repo" remote 2>/dev/null) ]]; then
    detail+=" · no remote: only on this computer"
    status=error
  elif git -C "$repo" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    ahead=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    if ((ahead > 0)); then
      detail+=" · $ahead backup(s) not pushed"
      [[ $status == ok ]] && status=warn
    else
      detail+=" · pushed"
    fi
  fi
  oc_check_emit "$status" "$(oc_tilde "$repo")" "$detail" "$repo"
}

# --- failed-units -----------------------------------------------------------

oc_check_failed_units() {
  local unit scope
  for scope in system user; do
    while read -r unit _; do
      [[ -n $unit ]] || continue
      oc_check_emit error "$unit" "$scope service failed · journalctl $([[ $scope == user ]] && echo "--user ")-u $unit" ""
    done < <(systemctl $([[ $scope == user ]] && echo --user) --failed --plain --no-legend 2>/dev/null | sed 's/^[●* ]*//')
  done
  return 0
}

# --- crashes ----------------------------------------------------------------

oc_check_crashes() {
  command -v coredumpctl >/dev/null 2>&1 || return 0
  coredumpctl list --since=-7d --json=short --no-pager 2>/dev/null |
    jq -r 'group_by(.exe) | map({exe: .[0].exe, n: length, last: (map(.time) | max)})
      | sort_by(-.n) | .[] | "\(.exe)\t\(.n)\t\(.last / 1000000 | floor)"' 2>/dev/null |
    while IFS=$'\t' read -r exe n last; do
      oc_check_emit warn "$(basename -- "$exe")" "$n crash(es), last $(oc_ago "$last") · $(oc_tilde "$exe")" ""
    done
  return 0
}

# --- pacnew -----------------------------------------------------------------

oc_check_pacnew() {
  local f
  while IFS= read -r -d '' f; do
    oc_check_emit warn "$f" "merge it with: sudo pacdiff" ""
  done < <(find /etc -xdev \( -name '*.pacnew' -o -name '*.pacsave' \) -print0 2>/dev/null)
  return 0
}

# --- config-drift -----------------------------------------------------------

oc_omarchy_defaults_dir() {
  local d
  for d in "${OMARCHY_PATH:-}/config" /usr/share/omarchy/config "$HOME/.local/share/omarchy/config"; do
    [[ -d $d ]] && { echo "$d"; return 0; }
  done
  return 1
}

oc_check_config_drift() {
  local defaults rel cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  defaults=$(oc_omarchy_defaults_dir) || return 0
  while IFS= read -r -d '' rel; do
    rel=${rel#./}
    [[ -f $cfg/$rel ]] || continue
    cmp -s -- "$defaults/$rel" "$cfg/$rel" && continue
    oc_check_emit info "$rel" "differs from $(oc_tilde "$defaults")/$rel" "$cfg/$rel"
  done < <(cd "$defaults" && find . -type f -print0 2>/dev/null | sort -z)
  return 0
}
