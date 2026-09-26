# Shared helpers for the dhis2-tools scripts.
# Service scripts source it with:
#   source "$(dirname "$(readlink -f "$0")")/../lib/dhis2-lib.sh"
#
# Command and flag rules: architecture.md section 12. In short:
# - prompts only when interactive (a terminal, and no -y); otherwise defaults are used and anything without a default
#   is collected with require/ask, then check_missing reports all of it at once (exit 3)
# - a summary before changing anything: confirm_summary (handles --dry-run, -y, no terminal)
# - secrets come from --secrets-stdin (secrets_load/secret) or are typed at a prompt, never from argv
# Prompts and errors go to stderr, so stdout stays clean for output other programs read.

YES=${YES:-false}          # -y: ask nothing
DRY_RUN=${DRY_RUN:-false}  # --dry-run: show the summary, change nothing
SECRETS=""                 # JSON object from --secrets-stdin
MISSING=()                 # inputs still needed, reported by check_missing
SUMMARY=()                 # lines shown by confirm_summary

die() { echo "Error: $*" >&2; exit 1; }
die_missing() { echo "Error: $*" >&2; exit 3; }

# interactive: may we ask? Only on a terminal, and never with -y.
interactive() { [[ -t 0 && $YES != true ]]; }

# require VALUE FLAG DESCRIPTION: note FLAG as missing when VALUE is empty
require() { [[ -n $1 ]] || MISSING+=("$(printf '%-34s  %s' "$2" "$3")"); }

# check_missing: stop with one error listing every missing input (exit 3)
check_missing() {
  [[ ${#MISSING[@]} -eq 0 ]] && return 0
  {
    echo "Error: missing input (needed with -y or without a terminal):"
    printf '  %s\n' "${MISSING[@]}"
  } >&2
  exit 3
}

# ask VAR "question" [default] [flag]: without a prompt, the default; with no default the flag is noted as missing
ask() {
  local __var=$1 __question=$2 __default=${3-} __option=${4-} __answer=""
  if ! interactive; then
    [[ -n $__default ]] || require "" "${__option:-?}" "$__question"
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  while [[ -z $__answer ]]; do
    read -r -p "$__question${__default:+ [$__default]}: " __answer
    __answer=${__answer:-$__default}
  done
  printf -v "$__var" '%s' "$__answer"
}

# ask_yes_no "question" y|n   -> returns 0 for yes. Without a prompt: the default.
ask_yes_no() {
  local __default=${2:-y} __answer
  if ! interactive; then [[ $__default == y ]]; return; fi
  if [[ $__default == y ]]; then
    read -r -p "$1 [Y/n] " __answer
    [[ ! $__answer =~ ^[Nn] ]]
  else
    read -r -p "$1 [y/N] " __answer
    [[ $__answer =~ ^[Yy] ]]
  fi
}

# summary LABEL TEXT: add a line to the summary shown by confirm_summary
summary() { SUMMARY+=("$(printf '%-12s %s' "$1" "$2")"); }

# confirm_summary QUESTION: show the summary, then go ahead only when confirmed.
# --dry-run: stop here (exit 0). -y: go ahead. No terminal: exit 3. "n": nothing changed (exit 1).
confirm_summary() {
  local __answer
  echo
  printf '  %s\n' "${SUMMARY[@]}"
  echo
  if [[ $DRY_RUN == true ]]; then echo "Dry run: nothing changed."; exit 0; fi
  [[ $YES == true ]] && return 0
  [[ -t 0 ]] || die_missing "no terminal to confirm: add -y to go ahead without asking"
  read -r -p "$1 [Y/n] " __answer
  if [[ $__answer =~ ^[Nn] ]]; then echo "Nothing changed." >&2; exit 1; fi
  return 0
}

# secrets_load ALLOWED_KEY...: read the --secrets-stdin JSON object; unknown keys are refused (so a typo can't pass unnoticed)
secrets_load() {
  local allowed bad
  SECRETS=$(cat)
  jq -e 'type == "object"' <<< "$SECRETS" >/dev/null 2>&1 || die "--secrets-stdin: stdin is not a JSON object"
  allowed=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  bad=$(jq -r --argjson ok "$allowed" 'keys - $ok | join(", ")' <<< "$SECRETS")
  [[ -z $bad ]] || die "--secrets-stdin: unknown key(s): $bad (allowed: $*)"
}

# secret PATH: a value from the secrets, e.g. secret glowroot_password, secret glowroot_passwords.hmis; returns 1 if absent
secret() {
  [[ -n $SECRETS ]] || return 1
  jq -er --arg p "$1" 'getpath($p | split(".")) | strings | select(length > 0)' <<< "$SECRETS" 2>/dev/null
}

# ask_password VAR "label" [secret_key]: the password from --secrets-stdin (secret_key), else typed twice at a prompt,
# else noted as missing. (Until 3b.15 moves its callers over, "true" as third argument still reads one line of stdin.)
ask_password() {
  local __var=$1 __label=$2 __key=${3-} __p1="" __p2=""
  if [[ $__key == true ]]; then
    IFS= read -r __p1 || true
    [[ -n $__p1 ]] || die "no $__label password on stdin"
  elif [[ -n $__key && $__key != false ]] && __p1=$(secret "$__key"); then
    :
  elif interactive; then
    while true; do
      IFS= read -r -s -p "$__label password: " __p1; echo >&2
      IFS= read -r -s -p "Repeat $__label password: " __p2; echo >&2
      if [[ -z $__p1 ]]; then echo "The password cannot be empty" >&2
      elif [[ $__p1 != "$__p2" ]]; then echo "The passwords do not match, try again" >&2
      else break
      fi
    done
  else
    require "" "--secrets-stdin  \"${__key:-password}\"" "the $__label password"
  fi
  printf -v "$__var" '%s' "$__p1"
}

# glowroot_hash: password on stdin -> Glowroot passwordHash on stdout.
# Same format as Glowroot's PasswordHash.java: PBKDF2WithHmacSHA1, 128-bit key and salt,
# "b64(hash):b64(salt):500000" in unpadded base64. The iteration count must stay 500000.
# Use: HASH=$(printf '%s\n' "$PASSWORD" | glowroot_hash)   (printf is a builtin, so the password never shows in ps)
glowroot_hash() {
  python3 -c '
import base64, hashlib, os, sys
password = sys.stdin.readline().rstrip("\n").encode("utf-8")
salt = os.urandom(16)
b64 = lambda b: base64.b64encode(b).decode().rstrip("=")
print(b64(hashlib.pbkdf2_hmac("sha1", password, salt, 500000, 16)) + ":" + b64(salt) + ":500000")'
}

########################################################################
# Glowroot logins
#
# Every instance with Glowroot has one login managed by these tools (its username is kept in the
# container label user.dhis2.glowroot.user). Other users added in Glowroot's own admin screens are kept.
# Mode "shared": one login for all instances, stored as a hash in $GLOWROOT_LOGIN_FILE.
# Mode "own": each instance has its own login. The instance's mode is in label user.dhis2.glowroot.

DHIS2_TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GLOWROOT_LOGIN_FILE=/usr/local/etc/dhis/glowroot-login

# glowroot_new_login USERNAME FROM_STDIN -> sets GR_USER, GR_HASH
# USERNAME empty: ask for it (default admin).
glowroot_new_login() {
  local password
  if [[ -n $1 ]]; then GR_USER=$1; else ask GR_USER "Glowroot username" admin -U; fi
  ask_password password Glowroot "${2:-false}"
  GR_HASH=$(printf '%s\n' "$password" | glowroot_hash)
}

# glowroot_load_shared -> sets GR_USER, GR_HASH from the shared login; returns 1 if there is none yet
glowroot_load_shared() {
  [[ -f $GLOWROOT_LOGIN_FILE ]] || return 1
  GR_USER=$(jq -r .username "$GLOWROOT_LOGIN_FILE")
  GR_HASH=$(jq -r .passwordHash "$GLOWROOT_LOGIN_FILE")
}

glowroot_save_shared() {
  ( umask 077; jq -n --arg u "$GR_USER" --arg h "$GR_HASH" '{username: $u, passwordHash: $h}' > "$GLOWROOT_LOGIN_FILE" )
}

# glowroot_write_admin NAME MODE: put GR_USER/GR_HASH into the instance's /opt/glowroot/admin.json.
# Removes the anonymous user and the previously managed login; a new instance starts from the template.
# Glowroot only reads admin.json at startup, so tomcat must be restarted afterwards.
glowroot_write_admin() {
  local name=$1 mode=$2 tmp previous
  tmp=$(mktemp)
  previous=$(lxc config get "$name" user.dhis2.glowroot.user)
  if ! lxc file pull "$name/opt/glowroot/admin.json" "$tmp" 2>/dev/null; then
    jq --arg ctx "/$name-glowroot" '.web.contextPath = $ctx' "$DHIS2_TOOLS/configs/glowroot-admin.json" > "$tmp"
  fi
  jq --arg u "$GR_USER" --arg h "$GR_HASH" --arg prev "$previous" \
    '.users = ([.users[]? | select(.username != "anonymous" and .username != $u and .username != $prev)]
               + [{username: $u, passwordHash: $h, roles: ["Administrator"]}])' "$tmp" > "$tmp.new"
  lxc file push "$tmp.new" "$name/opt/glowroot/admin.json"
  rm -f "$tmp" "$tmp.new"
  lxc exec "$name" -- chown tomcat:tomcat /opt/glowroot/admin.json
  lxc exec "$name" -- chmod 600 /opt/glowroot/admin.json
  lxc config set "$name" user.dhis2.glowroot "$mode"
  lxc config set "$name" user.dhis2.glowroot.user "$GR_USER"
}

########################################################################
# DHIS2 releases, from the official release feed.
# Every release has a full name (2.42.0, 2.42.5.2 for a hotfix) and users must type it exactly.

FEED_URL=https://releases.dhis2.org/v1/versions/stable.json
OLDEST_LINE=38   # 2.38 is the oldest DHIS2 version these tools install

feed_load() {
  [[ -n ${FEED:-} ]] && return 0
  FEED=$(curl -fsSL "$FEED_URL") || die "could not download the DHIS2 release list from $FEED_URL"
}

# feed_show [LINE] [CURRENT]: one row per version line (only LINE if given), CURRENT shown as [2.42.3]
feed_show() {
  jq -r --arg line "${1-}" --arg cur "${2-}" --argjson oldest $OLDEST_LINE '
    .versions[] | select((.name | split(".")[1] | tonumber) >= $oldest) | select($line == "" or .name == $line)
    | "  \(.name)  \(if .supported then "supported     " else "end of support" end)  "
      + ([.patchVersions[].name | if . == $cur then "[\(.)]" else . end] | join(" "))' <<< "$FEED"
}

# feed_release NAME: exact release name -> sets REL_NAME REL_URL REL_SHA REL_JDK REL_LINE; returns 1 if there is none
feed_release() {
  local row
  row=$(jq -r --arg n "$1" --argjson oldest $OLDEST_LINE '
    .versions[] | select((.name | split(".")[1] | tonumber) >= $oldest) as $v
    | $v.patchVersions[] | select(.name == $n)
    | [.name, .url, .sha256, ($v.jdk | tostring), $v.name] | @tsv' <<< "$FEED" | head -1)
  [[ -n $row ]] || return 1
  # shellcheck disable=SC2034  # REL_* are used by the calling scripts
  IFS=$'\t' read -r REL_NAME REL_URL REL_SHA REL_JDK REL_LINE <<< "$row"
}

# feed_line_jdk LINE: the Java version for a version line
feed_line_jdk() {
  jq -r --arg line "$1" '.versions[] | select(.name == $line) | .jdk' <<< "$FEED"
}

# feed_newest [LINE]: newest release overall, or in LINE
feed_newest() {
  jq -r --arg line "${1-}" --argjson oldest $OLDEST_LINE '
    [.versions[] | select((.name | split(".")[1] | tonumber) >= $oldest) | select($line == "" or .name == $line)]
    | .[0].patchVersions[-1].name' <<< "$FEED"
}

# ask_release VAR [LINE] [CURRENT] [GIVEN]: the release to use, from GIVEN (-V) or asked on the terminal.
# Only checks that the release exists (and is 2.38+); leaves REL_* set for it.
# Without a prompt and without GIVEN: notes -V as missing and returns 1.
ask_release() {
  local __var=$1 __line=${2-} __current=${3-} __given=${4-} __default __answer
  __default=$(feed_newest "$__line")
  if [[ -n $__given ]]; then
    feed_release "$__given" || die "$__given is not a DHIS2 release: give the exact name, e.g. -V $__default"
    printf -v "$__var" '%s' "$__given"
    return 0
  fi
  if ! interactive; then
    require "" "-V/--release <release>" "DHIS2 release, exact name (e.g. $__default)"
    return 1
  fi
  echo "DHIS2 releases (end of support = no more security fixes):" >&2
  feed_show "$__line" "$__current" >&2
  while true; do
    read -r -p "Release [$__default]: " __answer
    __answer=${__answer:-$__default}
    feed_release "$__answer" && break
    echo "$__answer is not in the list: type the exact release, e.g. $__default" >&2
  done
  printf -v "$__var" '%s' "$__answer"
}

release_line() { cut -d. -f1,2 <<< "$1"; }                                     # 2.42.5.2 -> 2.42
tomcat_for_line() { if (( ${1#2.} >= 42 )); then echo tomcat10; else echo tomcat9; fi; }   # 2.42+ is Jakarta
guestos_for_tomcat() { if [[ $1 == tomcat10 ]]; then echo 24.04; else echo 22.04; fi; }   # tomcat9 ends at 22.04
release_older() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$1" ]]; }  # is $1 < $2
# war_release WARFILE: the DHIS2 release inside a war, from its WEB-INF/lib/dhis-api-<release>.jar
war_release() { unzip -Z1 "$1" 2>/dev/null | sed -n 's|^WEB-INF/lib/dhis-api-\(.*\)\.jar$|\1|p' | head -1; }

########################################################################
# Instances and wars

# instance_tomcat NAME: tomcat9 or tomcat10 (instances from before the label existed are tomcat9)
instance_tomcat() {
  local t
  t=$(lxc config get "$1" user.dhis2.tomcat 2>/dev/null)
  echo "${t:-tomcat9}"
}

# download_war DIR: download the release in REL_* to DIR/dhis.war and check it against the published sha256.
# Tries 3 times, then asks: 1) try again 2) choose another release 3) stop. There is no "use it anyway".
# Returns 0 ok, 1 stop (also without a prompt), 2 choose another release.
download_war() {
  local dir=$1 attempt choice
  while true; do
    for attempt in 1 2 3; do
      echo "Downloading DHIS2 $REL_NAME (attempt $attempt of 3)" >&2
      if curl -fL --progress-bar -o "$dir/dhis.war" "$REL_URL" \
         && [[ $(sha256sum "$dir/dhis.war" | cut -d' ' -f1) == "$REL_SHA" ]]; then
        echo "Checksum ok" >&2
        return 0
      fi
      echo "The download failed or does not match its published checksum" >&2
    done
    interactive || return 1
    echo "The download of $REL_NAME does not match its published checksum (tried 3 times)." >&2
    echo "  1) Try again" >&2
    echo "  2) Choose another release" >&2
    echo "  3) Stop" >&2
    read -r -p "Choice [1]: " choice
    case ${choice:-1} in
      1) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
  done
}

# deploy_war NAME WARFILE RELEASE: replace the instance's DHIS2 with WARFILE and start it
deploy_war() {
  local name=$1 war=$2 release=$3 t
  t=$(instance_tomcat "$name")
  lxc exec "$name" -- service "$t" stop
  lxc exec "$name" -- sh -c "rm -rf /var/lib/$t/webapps/*"
  lxc file push "$war" "$name/tmp/dhis.war"
  lxc exec "$name" -- mkdir -p "/var/lib/$t/webapps/$name"
  lxc exec "$name" -- unzip -q -d "/var/lib/$t/webapps/$name" /tmp/dhis.war
  lxc exec "$name" -- rm /tmp/dhis.war
  lxc config set "$name" user.dhis2.version "$release"
  lxc exec "$name" -- service "$t" start
}

# server_base_url: https://<fqdn> once the proxy has a certificate, http://<fqdn> before that
server_base_url() {
  local fqdn
  fqdn=$(jq -r .fqdn /usr/local/etc/dhis/containers.json)
  if lxc exec proxy -- test -d "/etc/letsencrypt/live/$fqdn" 2>/dev/null; then echo "https://$fqdn"; else echo "http://$fqdn"; fi
}
