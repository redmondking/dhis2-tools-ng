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
#   Usage: sudo dhis2-upgrade-setup [-y]
#     -y  answer yes to every question (restarts are never done without asking)
#   Without a terminal it behaves as with -y, and skips steps that need a password.

[[ $EUID -eq 0 ]] || { echo "Please run with sudo"; exit 1; }
[[ -f /usr/local/etc/dhis/containers.json ]] || { echo "No /usr/local/etc/dhis/containers.json: this server was not set up with dhis2-tools-ng"; exit 1; }
cd "$(dirname "$(readlink -f "$0")")" || exit 1
[[ -f VERSION ]] || { echo "Run the installed dhis2-upgrade-setup (install it with install.sh first)"; exit 1; }

YES=false
[[ $1 == "-y" || ! -t 0 ]] && YES=true

# confirm "question" [default y|n]
confirm() {
  local DEFAULT=${2:-y} ANSWER
  if [[ $YES == true && $DEFAULT == y ]]; then return 0; fi
  if [[ $DEFAULT == y ]]; then
    read -r -p "$1 [Y/n] " ANSWER
    [[ ! $ANSWER =~ ^[Nn] ]]
  else
    read -r -p "$1 [y/N] " ANSWER
    [[ $ANSWER =~ ^[Yy] ]]
  fi
}

source parse_config.sh
source lib/dhis2-lib.sh
CONF=/usr/local/etc/dhis/containers.json
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
elif echo "Old copies:$OLD_COPIES" && confirm "Replace them with links to the installed versions (the old files are kept in /usr/local/etc/dhis/old-scripts)?"; then
  mkdir -p /usr/local/etc/dhis/old-scripts
  for F in $OLD_COPIES; do mv "/usr/local/bin/$F" /usr/local/etc/dhis/old-scripts/; done
  echo "Moved"
fi
./install.sh --relink

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
  lxc exec "$C" -- grep -q '^JAVA_HOME=.*{{' /etc/default/tomcat9 2>/dev/null || { echo "$C: ok"; continue; }
  JH=$(lxc exec "$C" -- sh -c 'dirname "$(dirname "$(readlink -f "$(command -v java)")")"')
  echo "$C: JAVA_HOME is broken, setting it to $JH"
  lxc exec "$C" -- sed -i "s|^JAVA_HOME=.*|JAVA_HOME=\"$JH/\"|" /etc/default/tomcat9
  RESTART+=("$C")
done

########################################################################
echo
echo "== 3. SSL certificate renewal"
# older ssl_setup.sh wrote a renewal cron job on the host instead of in the proxy container
if [[ -f /etc/cron.d/certbot ]] && grep -q -- '--standalone --pre-hook=' /etc/cron.d/certbot; then
  rm /etc/cron.d/certbot
  echo "Removed the misplaced /etc/cron.d/certbot from the host"
fi

RENEWAL_CONF=/etc/letsencrypt/renewal/${FQDN}.conf
if ! lxc exec proxy -- test -f "$RENEWAL_CONF"; then
  echo "No certificate for $FQDN on the proxy, nothing to do (run ./ssl_setup.sh to get one)"
else
  # certbot --standalone needs port 80, so the proxy must stop while it renews
  if lxc exec proxy -- grep -q '^pre_hook' "$RENEWAL_CONF"; then
    echo "Renewal hooks already set"
  else
    lxc exec proxy -- sed -i "/^\[renewalparams\]/a pre_hook = service $PROXY stop\npost_hook = service $PROXY start" "$RENEWAL_CONF"
    echo "Added stop/start hooks for $PROXY to $RENEWAL_CONF"
  fi
  if confirm "Renew the certificate automatically?"; then RENEWAL=enable; else RENEWAL=disable; fi
  # certbot.timer (apt) or snap.certbot.renew.timer (snap)
  for TIMER in certbot.timer snap.certbot.renew.timer; do
    lxc exec proxy -- systemctl $RENEWAL --now $TIMER 2>/dev/null
  done
  echo "Automatic renewal: ${RENEWAL}d. Test with: lxc exec proxy -- certbot renew --dry-run"
fi

########################################################################
echo
echo "== 4. Kernel settings"
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

########################################################################
echo
echo "== 5. NAT rule for the lxd network"
# older create_containers.sh always wrote 192.168.0.0/24
OLD_NET=$(grep -oP -- '-A POSTROUTING -s \K\S+' /etc/ufw/before.rules | head -1)
if [[ -z $OLD_NET ]]; then
  echo "No NAT rule found in /etc/ufw/before.rules, nothing to do"
elif [[ $OLD_NET == "$LXD_NET" ]]; then
  echo "Already correct ($LXD_NET)"
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
  if confirm "$NAME: redo the rsyslog setup (the old one used the wrong subnet and config)?"; then
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
  elif [[ ! -t 0 ]]; then
    echo "WARNING: /munin is open to anyone. Run sudo dhis2-upgrade-setup in a terminal to set a login."
  else
    echo "/munin is open to anyone: set a login for it"
    service/dhis2-munin-login
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
elif [[ ! -t 0 ]]; then
  echo "WARNING: Glowroot on ${OPEN[*]} is open to anyone. Run sudo dhis2-upgrade-setup in a terminal to set logins."
else
  echo "Glowroot on ${OPEN[*]} is open to anyone: it needs a login"
  MODE=$(jq -r '.glowroot_login // empty' $CONF)
  while [[ ! $MODE =~ ^(shared|own)$ ]]; do
    ask MODE "Glowroot login: 'shared' (one login for all instances) or 'own' (one per instance)" shared
  done
  jq --arg m "$MODE" '.glowroot_login = $m' $CONF > $CONF.new && cat $CONF.new > $CONF && rm $CONF.new
  if [[ $MODE == shared ]] && ! glowroot_load_shared; then
    echo "Set the shared Glowroot login"
    glowroot_new_login "" false
    glowroot_save_shared
  fi
  for C in "${OPEN[@]}"; do
    if [[ $MODE == own ]]; then
      echo "Glowroot login for $C"
      glowroot_new_login "" false
    fi
    glowroot_write_admin "$C" "$MODE"
    RESTART+=("$C")
    GLOWROOT_PENDING+=("$C")
  done
fi

########################################################################
echo
echo "== 9. Template fixes in /usr/local/etc/dhis"
# templates are copied once and may hold local edits, so only the known lines are patched
TS=/usr/local/etc/dhis/tomcat_setup
if [[ -f $TS ]] && grep -q -e '^echo "tomcat" >> /at.deny' -e '^ufw enable' $TS; then
  sed -i -e 's|^echo "tomcat" >> /at.deny|echo "tomcat" >> /etc/at.deny|' -e 's|^ufw enable|ufw --force enable|' $TS
  echo "Fixed tomcat_setup (at.deny path, non-interactive ufw)"
else
  echo "Nothing to fix"
fi

########################################################################
if [[ ${#RESTART[@]} -gt 0 ]]; then
  echo
  echo "== Restarts"
  for C in $(printf '%s\n' "${RESTART[@]}" | sort -u); do
    if confirm "$C: restart tomcat now so the fixes take effect (DHIS2 will be down for a few minutes)?" n; then
      lxc exec "$C" -- service tomcat9 restart
    elif [[ " ${GLOWROOT_PENDING[*]} " == *" $C "* ]]; then
      echo "WARNING: $C: Glowroot stays open to anyone until tomcat restarts"
    else
      echo "$C: fixes apply on the next tomcat restart"
    fi
  done
fi

echo
echo "Done. Things this script cannot repair:"
echo " - instances created with -n (no database) still got a database created; remove it with dropdb if unwanted"
echo " - dhis2-delete-instance may have removed lines ending in a space from /etc/hosts"
