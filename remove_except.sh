#!/usr/bin/env bash
# remove_except.sh
# Remove all local user accounts EXCEPT the safelist (skulllord, dreadpirate).
#
# WARNING: Destructive. This will delete user accounts. Dry-run by default.
# REQUIRED: run as root (sudo).
#
# Usage:
#   sudo ./remove_except.sh                 # dry-run: shows what would be done
#   sudo ./remove_except.sh --execute       # actually delete users
#   sudo ./remove_except.sh --execute --archive --remove-home
#   sudo ./remove_except.sh --execute --force
#   sudo ./remove_except.sh --lock-only     # lock accounts instead of deleting (still dry-run unless --execute)
#
# Options:
#   --execute     Perform deletions (default is dry-run)
#   --archive     Archive each user's home to /root/user_archives/<user>.tar.gz before deletion
#   --remove-home Remove home directory when deleting (implies --archive unless --no-archive)
#   --no-archive  Skip archiving even if --remove-home is specified
#   --force       Allow deleting accounts with UID < $MIN_UID (dangerous)
#   --min-uid N   Consider users with UID >= N for deletion (default 1000)
#   --lock-only   Lock the accounts instead of deleting them (usermod -L / expire)
#   -h|--help     Show this help
#
# Safety behavior:
#  - The script will NEVER delete:
#      - root
#      - the account running the script (whoami)
#      - any user in the SAFELIST below
#  - By default, only targets UID >= MIN_UID (1000) to avoid removing system accounts.
#  - Use --force to override UID check.
#
set -euo pipefail

LOGFILE="/var/log/remove_except.log"
EXECUTE=0
ARCHIVE=0
REMOVE_HOME=0
NO_ARCHIVE=0
FORCE=0
LOCK_ONLY=0
MIN_UID=1000

# SAFELIST: accounts to keep (case-sensitive)
SAFELIST=("skulllord" "dreadpirate" "sqluser")

# Logger
log() {
  local ts msg
  ts="$(date -Iseconds)"
  msg="$1"
  echo "[$ts] $msg" | tee -a "$LOGFILE"
}

usage() {
  cat <<EOF
Usage: sudo $0 [options]
Options:
  --execute       Actually perform deletions (default: dry-run)
  --archive       Archive /home/<user> to /root/user_archives/<user>.tar.gz before deletion
  --remove-home   Remove the user's home during deletion (implies archive unless --no-archive)
  --no-archive    Don't archive even if --remove-home specified
  --force         Allow deleting UID < $MIN_UID (dangerous)
  --min-uid N     Consider users with UID >= N for deletion (default 1000)
  --lock-only     Lock accounts instead of deleting (still requires --execute to make changes)
  -h|--help       Show this help
EOF
  exit 1
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (sudo)." >&2
  exit 2
fi

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=1; shift ;;
    --archive) ARCHIVE=1; shift ;;
    --remove-home) REMOVE_HOME=1; ARCHIVE=1; shift ;;
    --no-archive) NO_ARCHIVE=1; shift ;;
    --force) FORCE=1; shift ;;
    --lock-only) LOCK_ONLY=1; shift ;;
    --min-uid) shift; [[ -z "${1:-}" ]] && { echo "--min-uid requires a value"; exit 1; }; MIN_UID="$1"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

log "Run started. EXECUTE=$EXECUTE ARCHIVE=$ARCHIVE REMOVE_HOME=$REMOVE_HOME NO_ARCHIVE=$NO_ARCHIVE FORCE=$FORCE MIN_UID=$MIN_UID LOCK_ONLY=$LOCK_ONLY"
log "Safelist: ${SAFELIST[*]}"
log "Log file: $LOGFILE"

# Prepare archive dir if needed
if [[ $ARCHIVE -eq 1 && $NO_ARCHIVE -ne 1 ]]; then
  mkdir -p /root/user_archives
  chmod 700 /root/user_archives
fi

# helper: check safelist
is_safelisted() {
  local u="$1"
  for s in "${SAFELIST[@]}"; do
    if [[ "$u" == "$s" ]]; then
      return 0
    fi
  done
  return 1
}

# helper: archive home
archive_home() {
  local user="$1" home="$2" out
  if [[ -d "$home" ]]; then
    out="/root/user_archives/${user}.tar.gz"
    if [[ $EXECUTE -eq 0 ]]; then
      log "DRY: would archive $home -> $out"
      return 0
    fi
    log "Archiving $home -> $out"
    tar --warning=no-file-changed -czf "$out" -C "$(dirname "$home")" "$(basename "$home")" && \
      log "Archived home for $user to $out" || log "ERROR archiving $home for $user"
    chmod 600 "$out" || true
  else
    log "No home dir for $user at $home (skipping archive)"
  fi
}

# helper: remove crontab
remove_crontab() {
  local u="$1"
  if crontab -l -u "$u" &>/dev/null; then
    if [[ $EXECUTE -eq 0 ]]; then
      log "DRY: would remove crontab for $u"
    else
      crontab -r -u "$u" && log "Removed crontab for $u" || log "No crontab to remove or failed for $u"
    fi
  fi
}

# helper: kill processes owned by user
kill_procs() {
  local u="$1"
  if [[ $EXECUTE -eq 0 ]]; then
    log "DRY: would kill processes for $u (pkill -u $u)"
  else
    pkill -u "$u" || true
    log "Killed processes for $u (if any)"
  fi
}

# helper: cleanup sudoers mentions
cleanup_sudoers() {
  local u="$1" tmp
  tmp="$(mktemp)"
  if grep -qE "^[^#]*\b${u}\b" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
    if [[ $EXECUTE -eq 0 ]]; then
      log "DRY: would remove sudoers entries for $u from /etc/sudoers and /etc/sudoers.d/*"
    else
      for f in /etc/sudoers.d/*; do
        [[ -e "$f" ]] || continue
        if grep -qE "^[^#]*\b${u}\b" "$f" 2>/dev/null; then
          sed -E "/\b${u}\b/d" "$f" > "${tmp}" && mv "${tmp}" "$f" && log "Cleaned sudoers file: $f"
        fi
      done
      if grep -qE "^[^#]*\b${u}\b" /etc/sudoers 2>/dev/null; then
        cp /etc/sudoers /etc/sudoers.bak."$(date +%s)"
        sed -E "/\b${u}\b/d" /etc/sudoers > "${tmp}" && visudo -c -f "${tmp}" >/dev/null 2>&1 && mv "${tmp}" /etc/sudoers && log "Removed $u entries from /etc/sudoers (validated)" || { log "ERROR: sudoers validation failed for ${u}; restoring"; mv /etc/sudoers.bak.* /etc/sudoers || true; }
      fi
    fi
  fi
  [[ -f "$tmp" ]] && rm -f "$tmp" || true
}

# function: lock account
lock_account() {
  local u="$1"
  if [[ $EXECUTE -eq 0 ]]; then
    log "DRY: would lock account $u (usermod -L and expire)"
  else
    usermod -L "$u" && usermod -e 1 "$u" && log "Locked account $u" || log "ERROR locking $u"
  fi
}

# function: delete user
delete_user() {
  local u="$1" info uid home
  if ! info="$(getent passwd "$u")"; then
    log "NOTICE: user $u does not exist on this system — skipping"
    return 0
  fi
  IFS=: read -r _ _ uid _ _ home _ <<< "$info"

  # safety checks
  if [[ "$u" == "root" ]]; then
    log "SKIP: refusing to remove root"
    return 0
  fi
  if [[ "$u" == "$(whoami)" ]]; then
    log "SKIP: refusing to remove the user running the script ($u)"
    return 0
  fi
  if is_safelisted "$u"; then
    log "SKIP: $u is in safelist"
    return 0
  fi
  if [[ $FORCE -ne 1 && "$uid" -lt "$MIN_UID" ]]; then
    log "SKIP: $u UID=$uid < MIN_UID=$MIN_UID (likely system account) - use --force to override"
    return 0
  fi

  log "Targeting user: $u (UID=$uid HOME=$home)"

  # archive if requested
  if [[ $ARCHIVE -eq 1 && $NO_ARCHIVE -ne 1 ]]; then
    archive_home "$u" "$home"
  fi

  # remove crontab, kill procs, cleanup sudoers
  remove_crontab "$u"
  kill_procs "$u"
  cleanup_sudoers "$u"

  if [[ $LOCK_ONLY -eq 1 ]]; then
    lock_account "$u"
    return 0
  fi

  # deletion (dry-run unless --execute)
  if [[ $EXECUTE -eq 0 ]]; then
    log "DRY: would delete user $u (remove-home=$REMOVE_HOME)"
    return 0
  fi

  # perform delete
  if command -v deluser >/dev/null 2>&1; then
    if [[ $REMOVE_HOME -eq 1 ]]; then
      deluser --remove-home "$u" && log "Deleted user $u and removed home" || log "ERROR: deluser failed for $u"
    else
      deluser "$u" && log "Deleted user $u (home preserved)" || log "ERROR: deluser failed for $u"
    fi
  else
    if [[ $REMOVE_HOME -eq 1 ]]; then
      userdel -r "$u" && log "userdel -r: deleted $u and removed home" || log "ERROR: userdel -r failed for $u"
    else
      userdel "$u" && log "userdel: deleted $u (home preserved)" || log "ERROR: userdel failed for $u"
    fi
  fi
}

# Build list of candidate users from /etc/passwd (UID >= MIN_UID)
CANDIDATES=()
while IFS=: read -r username _ uid _ _ home shell; do
  # Skip empty names
  [[ -z "$username" ]] && continue
  # Only consider users with numeric UID
  if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
    continue
  fi
  if [[ "$uid" -ge "$MIN_UID" ]]; then
    CANDIDATES+=("$username")
  fi
done < /etc/passwd

log "Candidates (UID >= $MIN_UID): ${CANDIDATES[*]}"

# Remove safelisted accounts from candidates
TO_DELETE=()
for u in "${CANDIDATES[@]}"; do
  if is_safelisted "$u"; then
    log "Keeping safelisted user: $u"
    continue
  fi
  # Also skip the current user and root (double-safety)
  if [[ "$u" == "$(whoami)" ]] || [[ "$u" == "root" ]]; then
    log "Skipping current/root user: $u"
    continue
  fi
  TO_DELETE+=("$u")
done

if [[ ${#TO_DELETE[@]} -eq 0 ]]; then
  log "No users to remove (after safelist/UID filters). Exiting."
  exit 0
fi

log "Final removal list (${#TO_DELETE[@]}): ${TO_DELETE[*]}"
log "If you want to proceed, re-run with --execute. Current run: EXECUTE=$EXECUTE"

# Execute removals (or lock)
for u in "${TO_DELETE[@]}"; do
  delete_user "$u"
done

log "Run finished. Check $LOGFILE for details."
if [[ $EXECUTE -eq 0 ]]; then
  echo "DRY RUN complete. To actually remove the users, re-run with --execute (and optionally --archive --remove-home)."
fi

exit 0
