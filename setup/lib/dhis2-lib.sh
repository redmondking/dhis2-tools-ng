# Shared helpers for the dhis2-tools scripts.
# Service scripts source it with:
#   source "$(dirname "$(readlink -f "$0")")/../lib/dhis2-lib.sh"
#
# Prompts only happen on a terminal. Without one (Ansible, the management app, cron) a value
# falls back to its default, or the script stops and names the option that supplies it.
# Prompts go to stderr, so stdout stays clean for output other programs read.

die() { echo "Error: $*" >&2; exit 1; }

# ask VAR "question" [default] [option]
ask() {
  local __var=$1 __question=$2 __default=${3-} __option=${4-} __answer=""
  if [[ ! -t 0 ]]; then
    [[ -n $__default ]] || die "no value for \"$__question\"${__option:+, give it with $__option}"
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  while [[ -z $__answer ]]; do
    read -r -p "$__question${__default:+ [$__default]}: " __answer
    __answer=${__answer:-$__default}
  done
  printf -v "$__var" '%s' "$__answer"
}

# ask_yes_no "question" y|n   -> returns 0 for yes. Without a terminal: the default.
ask_yes_no() {
  local __default=${2:-y} __answer
  if [[ ! -t 0 ]]; then [[ $__default == y ]]; return; fi
  if [[ $__default == y ]]; then
    read -r -p "$1 [Y/n] " __answer
    [[ ! $__answer =~ ^[Nn] ]]
  else
    read -r -p "$1 [y/N] " __answer
    [[ $__answer =~ ^[Yy] ]]
  fi
}

# ask_password VAR "label" [from_stdin]
# from_stdin=true: read one line from stdin (--password-stdin). Otherwise ask twice on the terminal.
ask_password() {
  local __var=$1 __label=$2 __from_stdin=${3:-false} __p1="" __p2=""
  if [[ $__from_stdin == true ]]; then
    IFS= read -r __p1 || true
    [[ -n $__p1 ]] || die "no $__label password on stdin"
  else
    [[ -t 0 ]] || die "no terminal to ask for the $__label password, give it with --password-stdin"
    while true; do
      IFS= read -r -s -p "$__label password: " __p1; echo >&2
      IFS= read -r -s -p "Repeat $__label password: " __p2; echo >&2
      if [[ -z $__p1 ]]; then echo "The password cannot be empty" >&2
      elif [[ $__p1 != "$__p2" ]]; then echo "The passwords do not match, try again" >&2
      else break
      fi
    done
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
