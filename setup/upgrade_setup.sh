#!/usr/bin/env bash
#       ____  __  ______________
#      / __ \/ / / /  _/ ___/__ \
#     / / / / /_/ // / \__ \__/ /
#    / /_/ / __  // / ___/ / __/
#   /_____/_/ /_/___//____/____/
#
#   Bring a server installed with older dhis2-tools-ng scripts up to date.
#   Safe to re-run: each step checks whether it is needed first.
#
#   Usage: sudo dhis2-upgrade-setup [options]   (see --help)
#   Without a terminal it behaves as with -y. Steps that need a password then use --secrets-stdin,
#   or are skipped with a warning.

cd "$(dirname "$(readlink -f "$0")")" || exit 1
# shellcheck source=lib/dhis2-lib.sh
source lib/dhis2-lib.sh

usage() {
  cat <<EOF
Usage: dhis2-upgrade-setup [options]
Repairs and migrates a server set up with older versions of these tools. Safe to run again.
Options:
      --dry-run                    show what each step would change, change nothing (nothing is asked)
  -y, --yes                        answer every question with its default (tomcat restarts still need --restart yes)
      --restart yes|no             restart instances whose fixes need it (default no)
      --renew yes|no               renew the certificate automatically (default yes)
      --glowroot-login shared|own  login mode for Glowroot pages that are still open (default: containers.json, else shared)
      --glowroot-user <name>       Glowroot username (default admin)
      --munin-user <name>          Munin username (default admin)
      --secrets-stdin              passwords as JSON on stdin: {"munin_password": "...", "glowroot_password": "...",
                                   "glowroot_passwords": {"<instance>": "..."}} (the last one for own logins)
  -h, --help                       this help
EOF
  exit "${1:-1}"
}

RESTART_OPT=""
RENEW_OPT=""
MODE_OPT=""
GR_USER_OPT=""
MUNIN_USER_OPT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    -y|--yes) YES=true ;;
    --restart) RESTART_OPT=${2-}; shift; [[ $RESTART_OPT =~ ^(yes|no)$ ]] || die "--restart takes yes or no" ;;
    --renew) RENEW_OPT=${2-}; shift; [[ $RENEW_OPT =~ ^(yes|no)$ ]] || die "--renew takes yes or no" ;;
    --glowroot-login) MODE_OPT=${2-}; shift; [[ $MODE_OPT =~ ^(shared|own)$ ]] || die "--glowroot-login takes shared or own" ;;
    --glowroot-user) GR_USER_OPT=${2-}; shift ;;
    --munin-user) MUNIN_USER_OPT=${2-}; shift ;;
    --secrets-stdin) secrets_load munin_password glowroot_password glowroot_passwords ;;
    -h|--help) usage 0 ;;
    *) die "unknown option $1 (see dhis2-upgrade-setup --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "please run with sudo"
[[ -f /usr/local/etc/dhis/containers.json ]] || die "no /usr/local/etc/dhis/containers.json: this server was not set up with dhis2-tools-ng"
[[ -f VERSION ]] || die "run the installed dhis2-upgrade-setup (install it with install.sh first)"
[[ -t 0 ]] || YES=true   # no terminal: behave as -y
[[ $DRY_RUN == true ]] && echo "Dry run: every step checks and reports what it would change; nothing is changed."

dry() { [[ $DRY_RUN == true ]]; }

# confirm "question" [default y|n]: without a prompt (-y, no terminal, --dry-run) the default
confirm() {
  local DEFAULT=${2:-y} ANSWER
  if dry || ! interactive; then [[ $DEFAULT == y ]]; return; fi
  if [[ $DEFAULT == y ]]; then
    read -r -p "$1 [Y/n] " ANSWER
    [[ ! $ANSWER =~ ^[Nn] ]]
  else
    read -r -p "$1 [y/N] " ANSWER
    [[ $ANSWER =~ ^[Yy] ]]
  fi
}

# the postgres12 container type was removed (it was identical to postgres); rename it before the config is read
CONF=/usr/local/etc/dhis/containers.json
if grep -Eq '"type"[[:space:]]*:[[:space:]]*"postgres12"' $CONF; then
  if dry; then
    echo "would: rename container type postgres12 to postgres in $CONF"
    DHIS2_CONF=$(mktemp)   # read a renamed copy, so the checks below still work
    sed -E 's/("type"[[:space:]]*:[[:space:]]*)"postgres12"/\1"postgres"/' $CONF > "$DHIS2_CONF"
    export DHIS2_CONF
  else
    sed -i -E 's/("type"[[:space:]]*:[[:space:]]*)"postgres12"/\1"postgres"/' $CONF
  fi
fi

source parse_config.sh
RESTART=()           # instances that need a tomcat restart, asked about at the end
GLOWROOT_PENDING=()  # of those, the ones whose Glowroot stays open until then

########################################################################
echo
echo "== 1. dhis2-* commands in /usr/local/bin"
# older versions copied the service scripts into /usr/local/bin; now they are links into this directory
OLD_COPIES=""
for F in /usr/local/bin/dhis2-*; do
  # only copies of scripts we ship; an admin's own dhis2-* scripts are left alone
  [[ -f $F && ! -L $F && -f service/$(basename "$F") ]] && OLD_COPIES="$OLD_COPIES $(basename "$F")"
done
if [[ -z $OLD_COPIES ]]; then
  echo "Already links"
elif dry; then
  echo "would: move the old copies$OLD_COPIES to /usr/local/etc/dhis/old-scripts and link the installed versions"
elif echo "Old copies:$OLD_COPIES" && confirm "Replace them with links to the installed versions (the old files are kept in /usr/local/etc/dhis/old-scripts)?"; then
  mkdir -p /usr/local/etc/dhis/old-scripts
  for F in $OLD_COPIES; do mv "/usr/local/bin/$F" /usr/local/etc/dhis/old-scripts/; done
  echo "Moved"
fi
dry || ./install.sh --relink

########################################################################
echo
echo "== 2. JAVA_HOME in DHIS2 instances"
# older dhis2-create-instance wrote JAVA_HOME="/usr/lib/jvm/java-{{ ... }}-openjdk-amd64/"
for ROW in $(lxc list -c ns --format csv); do
  C=${ROW%,*} STATE=${ROW#*,}
  lxc config get "$C" user.type | grep -q Tomcat || continue
  if [[ $STATE != RUNNING ]]; then
    echo "$C: skipped (not running), start it and re-run to check it"
    continue
  fi
  T=$(instance_tomcat "$C")
  lxc exec "$C" -- grep -q '^JAVA_HOME=.*{{' /etc/default/$T 2>/dev/null || { echo "$C: ok"; continue; }
  JH=$(lxc exec "$C" -- sh -c 'dirname "$(dirname "$(readlink -f "$(command -v java)")")"')
  if dry; then echo "would: $C: set the broken JAVA_HOME to $JH"; RESTART+=("$C"); continue; fi
  echo "$C: JAVA_HOME is broken, setting it to $JH"
  lxc exec "$C" -- sed -i "s|^JAVA_HOME=.*|JAVA_HOME=\"$JH/\"|" /etc/default/$T
  RESTART+=("$C")
done

########################################################################
echo
echo "== 3. SSL certificate renewal"
# older ssl_setup.sh wrote a renewal cron job on the host instead of in the proxy container
if [[ -f /etc/cron.d/certbot ]] && grep -q -- '--standalone --pre-hook=' /etc/cron.d/certbot; then
  if dry; then echo "would: remove the misplaced /etc/cron.d/certbot from the host"
  else rm /etc/cron.d/certbot; echo "Removed the misplaced /etc/cron.d/certbot from the host"; fi
fi

RENEWAL_CONF=/etc/letsencrypt/renewal/${FQDN}.conf
if ! lxc exec proxy -- test -f "$RENEWAL_CONF"; then
  echo "No certificate for $FQDN on the proxy, nothing to do (run ./ssl_setup.sh to get one)"
else
  # certbot --standalone needs port 80, so the proxy must stop while it renews
  if lxc exec proxy -- grep -q '^pre_hook' "$RENEWAL_CONF"; then
    echo "Renewal hooks already set"
  elif dry; then
    echo "would: add stop/start hooks for $PROXY to $RENEWAL_CONF"
  else
    lxc exec proxy -- sed -i "/^\[renewalparams\]/a pre_hook = service $PROXY stop\npost_hook = service $PROXY start" "$RENEWAL_CONF"
    echo "Added stop/start hooks for $PROXY to $RENEWAL_CONF"
  fi
  if [[ -n $RENEW_OPT ]]; then [[ $RENEW_OPT == yes ]] && RENEWAL=enable || RENEWAL=disable
  elif confirm "Renew the certificate automatically?"; then RENEWAL=enable; else RENEWAL=disable; fi
  if dry; then
    echo "would: ${RENEWAL} automatic renewal"
  else
    # certbot.timer (apt) or snap.certbot.renew.timer (snap)
    for TIMER in certbot.timer snap.certbot.renew.timer; do
      lxc exec proxy -- systemctl $RENEWAL --now $TIMER 2>/dev/null
    done
    echo "Automatic renewal: ${RENEWAL}d. Test with: lxc exec proxy -- certbot renew --dry-run"
  fi
fi

########################################################################
echo
echo "== 4. Kernel settings"
if dry; then
  cmp -s configs/sysctl /etc/sysctl.d/60-dhis2-lxd.conf || echo "would: install and apply /etc/sysctl.d/60-dhis2-lxd.conf"
  grep -q 'max_user_watchesi' /etc/sysctl.conf && echo "would: remove the old appended settings from /etc/sysctl.conf (keeping a backup)"
else
cp configs/sysctl /etc/sysctl.d/60-dhis2-lxd.conf
# older lxd_setup.sh appended (with a typo) to /etc/sysctl.conf on every run
if grep -q 'max_user_watchesi' /etc/sysctl.conf; then
  BACKUP=/etc/sysctl.conf.bak-$(date +%Y%m%d%H%M%S)
  cp /etc/sysctl.conf "$BACKUP"
  grep -vxF -f <(grep -v '^$' configs/sysctl; echo 'fs.inotify.max_user_watchesi = 1048576') "$BACKUP" > /etc/sysctl.conf
  echo "Removed the old appended settings from /etc/sysctl.conf (backup: $BACKUP)"
fi
sysctl --system >/dev/null || echo "Warning: some kernel settings could not be applied"
echo "Settings in /etc/sysctl.d/60-dhis2-lxd.conf applied"
fi

########################################################################
echo
echo "== 5. NAT rule for the lxd network"
# older create_containers.sh always wrote 192.168.0.0/24
OLD_NET=$(grep -oP -- '-A POSTROUTING -s \K\S+' /etc/ufw/before.rules | head -1)
if [[ -z $OLD_NET ]]; then
  echo "No NAT rule found in /etc/ufw/before.rules, nothing to do"
elif [[ $OLD_NET == "$LXD_NET" ]]; then
  echo "Already correct ($LXD_NET)"
elif dry; then
  echo "would: change the NAT rule from $OLD_NET to $LXD_NET (keeping a backup of /etc/ufw/before.rules)"
elif confirm "NAT rule uses $OLD_NET but lxdbr0 is $LXD_NET. Fix it?"; then
  BACKUP=/etc/ufw/before.rules.bak-$(date +%Y%m%d%H%M%S)
  cp /etc/ufw/before.rules "$BACKUP"
  sed -i "/POSTROUTING/s|${OLD_NET}|${LXD_NET}|g" /etc/ufw/before.rules
  ufw reload
  echo "Fixed (backup: $BACKUP)"
fi

########################################################################
echo
echo "== 6. rsyslog logger containers"
FOUND=false
for CONTAINER in $CONTAINERS; do
  [[ $(echo "$CONTAINER" | jq -r .type) == rsyslog_logger ]] || continue
  FOUND=true
  NAME=$(echo "$CONTAINER" | jq -r .name)
  if dry; then
    echo "would: $NAME: redo the rsyslog setup"
  elif confirm "$NAME: redo the rsyslog setup (the old one used the wrong subnet and config)?"; then
    # old setup uncommented the legacy imudp/imtcp lines, which clash with the new config
    lxc exec "$NAME" -- sed -i -E '/^[^#].*(imudp|imtcp|UDPServerRun|InputTCPServerRun)/s/^/#/' /etc/rsyslog.conf
    source containers/rsyslog_logger_postsetup
  fi
done
[[ $FOUND == true ]] || echo "None configured"

########################################################################
echo
echo "== 7. Munin login"
# older setups served /munin to anyone
if ! lxc info monitor >/dev/null 2>&1; then
  echo "Munin is not installed"
else
  [[ $PROXY == nginx ]] && SITE=/etc/nginx/upstream/munin.conf PASSWD_FILE=/etc/nginx/munin.htpasswd \
                        || SITE=/etc/apache2/upstream/munin PASSWD_FILE=/etc/apache2/munin.htpasswd
  if lxc exec proxy -- grep -q "$PASSWD_FILE" "$SITE" && lxc exec proxy -- test -s "$PASSWD_FILE"; then
    echo "Already has a login"
  elif dry; then
    echo "would: set a Munin login (/munin is open to anyone)"
  elif PW=$(secret munin_password); then
    echo "/munin is open to anyone: setting the Munin login from --secrets-stdin"
    jq -n --arg p "$PW" '{munin_password: $p}' \
      | service/dhis2-munin-login --secrets-stdin -y ${MUNIN_USER_OPT:+--munin-user "$MUNIN_USER_OPT"}
  elif interactive; then
    echo "/munin is open to anyone: set a login for it"
    service/dhis2-munin-login ${MUNIN_USER_OPT:+--munin-user "$MUNIN_USER_OPT"}
  else
    echo "WARNING: /munin is open to anyone. Set a login: run sudo dhis2-upgrade-setup in a terminal, or give munin_password in --secrets-stdin."
  fi
fi

########################################################################
echo
echo "== 8. Glowroot logins"
# older setups gave Glowroot's anonymous user admin rights on every instance
OPEN=()
for ROW in $(lxc list -c ns --format csv); do
  C=${ROW%,*} STATE=${ROW#*,}
  lxc config get "$C" user.type | grep -q Tomcat || continue
  if [[ $STATE != RUNNING ]]; then
    echo "$C: skipped (not running), start it and re-run to check it"
  elif ! lxc exec "$C" -- test -f /opt/glowroot/admin.json; then
    [[ -n $(lxc config get "$C" user.dhis2.glowroot) ]] || lxc config set "$C" user.dhis2.glowroot off
  elif lxc exec "$C" -- grep -q '"anonymous"' /opt/glowroot/admin.json; then
    OPEN+=("$C")
  fi
done
if [[ ${#OPEN[@]} -eq 0 ]]; then
  echo "No open Glowroot pages"
else
  MODE=${MODE_OPT:-$(jq -r '.glowroot_login // empty' $CONF)}
  if dry; then
    echo "would: set Glowroot logins (${MODE:-shared or own, asked}) on ${OPEN[*]}, which are open to anyone"
    RESTART+=("${OPEN[@]}")
    GLOWROOT_PENDING+=("${OPEN[@]}")
  elif ! interactive && [[ -z $SECRETS ]]; then
    echo "WARNING: Glowroot on ${OPEN[*]} is open to anyone. Set logins: run sudo dhis2-upgrade-setup in a terminal,"
    echo "         or give the passwords in --secrets-stdin (glowroot_password, or glowroot_passwords per instance)."
  else
    echo "Glowroot on ${OPEN[*]} is open to anyone: it needs a login"
    while [[ ! $MODE =~ ^(shared|own)$ ]]; do
      ask MODE "Glowroot login: 'shared' (one login for all instances) or 'own' (one per instance)" shared
    done
    jq --arg m "$MODE" '.glowroot_login = $m' $CONF > $CONF.new && cat $CONF.new > $CONF && rm $CONF.new
    if [[ $MODE == shared ]] && ! glowroot_load_shared; then
      interactive && echo "Set the shared Glowroot login"
      glowroot_new_login "$GR_USER_OPT" glowroot_password
      [[ -z $GR_HASH ]] || glowroot_save_shared
    fi
    for C in "${OPEN[@]}"; do
      if [[ $MODE == own ]]; then
        interactive && echo "Glowroot login for $C"
        glowroot_new_login "$GR_USER_OPT" "glowroot_passwords.$C"
      fi
      if [[ -z $GR_HASH ]]; then
        echo "WARNING: $C: no Glowroot password given (--secrets-stdin), so its Glowroot stays open to anyone"
        MISSING=()
        continue
      fi
      glowroot_write_admin "$C" "$MODE"
      RESTART+=("$C")
      GLOWROOT_PENDING+=("$C")
    done
  fi
fi

########################################################################
echo
echo "== 9. Template fixes in /usr/local/etc/dhis"
# templates are copied once and may hold local edits, so only the known lines are patched
TS=/usr/local/etc/dhis/tomcat_setup
if [[ -f $TS ]] && grep -q -e '^echo "tomcat" >> /at.deny' -e '^ufw enable' -e 'tomcat9' $TS && dry; then
  echo "would: fix tomcat_setup (at.deny path, non-interactive ufw, tomcat9 or tomcat10 per instance)"
elif [[ -f $TS ]] && grep -q -e '^echo "tomcat" >> /at.deny' -e '^ufw enable' -e 'tomcat9' $TS; then
  # tomcat9 -> TOMCAT placeholder: new instances get tomcat9 or tomcat10 depending on the DHIS2 version
  sed -i -e 's|^echo "tomcat" >> /at.deny|echo "tomcat" >> /etc/at.deny|' -e 's|^ufw enable|ufw --force enable|' \
         -e 's|tomcat9|TOMCAT|g' $TS
  echo "Fixed tomcat_setup (at.deny path, non-interactive ufw, tomcat9 or tomcat10 per instance)"
else
  echo "Nothing to fix"
fi

########################################################################
echo
echo "== 10. Labels on existing instances"
# dhis2-list-instances and dhis2-deploy-war read these; instances from older versions never had them
label() {   # label KEY VALUE: set user.dhis2.KEY on $C unless it already has a value
  [[ -z $(lxc config get "$C" "user.dhis2.$1") ]] || return 0
  dry || lxc config set "$C" "user.dhis2.$1" "$2"
  SET="$SET $1=$2"
}
for ROW in $(lxc list -c ns --format csv); do
  C=${ROW%,*} STATE=${ROW#*,}
  lxc config get "$C" user.type | grep -q Tomcat || continue
  if [[ $STATE != RUNNING ]]; then
    echo "$C: skipped (not running), start it and re-run to label it"
    continue
  fi
  SET=""
  T=$(instance_tomcat "$C")
  label tomcat "$T"
  V=$(lxc exec "$C" -- sh -c "ls /var/lib/$T/webapps/*/WEB-INF/lib/dhis-api-*.jar 2>/dev/null" \
      | sed -n 's|.*/dhis-api-\(.*\)\.jar$|\1|p' | head -1)
  label version "${V:-none}"
  J=$(lxc exec "$C" -- sh -c 'readlink -f "$(command -v java)"' | sed -n 's|.*/java-\([0-9]*\)-openjdk.*|\1|p')
  [[ -z $J ]] || label java "$J"
  lxc exec "$C" -- test -f /opt/glowroot/admin.json || label glowroot off
  if lxc exec "$C" -- test -x /usr/sbin/munin-node; then label munin yes; else label munin no; fi
  if [[ -z $SET ]]; then echo "$C: already labelled"
  elif dry; then echo "would: label $C:$SET"
  else echo "$C:$SET"; fi
done

########################################################################
if [[ ${#RESTART[@]} -gt 0 ]]; then
  echo
  echo "== Restarts"
  for C in $(printf '%s\n' "${RESTART[@]}" | sort -u); do
    if dry; then
      echo "would: $C needs a tomcat restart (done only with --restart yes, or when you answer yes)"
    elif [[ $RESTART_OPT == yes ]] || { [[ -z $RESTART_OPT ]] && confirm "$C: restart tomcat now so the fixes take effect (DHIS2 will be down for a few minutes)?" n; }; then
      lxc exec "$C" -- service "$(instance_tomcat "$C")" restart
    elif [[ " ${GLOWROOT_PENDING[*]} " == *" $C "* ]]; then
      echo "WARNING: $C: Glowroot stays open to anyone until tomcat restarts"
    else
      echo "$C: fixes apply on the next tomcat restart"
    fi
  done
fi

echo
if dry; then echo "Dry run: nothing changed."; exit 0; fi
echo "Done. Things this script cannot repair:"
echo " - instances created with -n (no database) still got a database created; remove it with dropdb if unwanted"
echo " - dhis2-delete-instance may have removed lines ending in a space from /etc/hosts"
