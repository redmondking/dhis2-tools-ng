#!/usr/bin/env bash
#
#   Get a letsencrypt certificate for the fqdn and switch the proxy to https.
#   Usage: sudo dhis2-ssl-setup [options]   (see --help)

cd "$(dirname "$(readlink -f "$0")")" || exit 1
# shellcheck source=lib/dhis2-lib.sh
source lib/dhis2-lib.sh

usage() {
  cat <<EOF
Usage: dhis2-ssl-setup [options]
Gets a Let's Encrypt certificate for the fqdn in containers.json and switches the proxy to https.
Options:
      --renew yes|no  renew the certificate automatically (default yes)
      --dry-run       test with Let's Encrypt's staging server: checks DNS and port 80 without a real certificate
                      and without using up the real request limits; changes nothing (the proxy stops for a few seconds)
  -y, --yes           ask nothing
  -h, --help          this help
Exit codes: 0 ok, 1 failure, 3 missing input (e.g. no terminal to confirm: add -y).
EOF
  exit "${1:-1}"
}

RENEW=""
TEST=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --renew) RENEW=${2-}; shift
        [[ $RENEW =~ ^(yes|no)$ ]] || die "--renew takes yes or no" ;;
    --dry-run) TEST=true ;;
    -y|--yes) YES=true ;;
    -h|--help) usage 0 ;;
    *) die "unknown option $1 (see dhis2-ssl-setup --help)" ;;
  esac
  shift
done
[[ $EUID -eq 0 ]] || die "please run with sudo"

# Parse json config file
source parse_config.sh

if [[ -z $RENEW ]]; then
  if [[ $TEST == false ]] && interactive; then
    echo "Letsencrypt certificates expire after 90 days." >&2
    ask_yes_no "Renew the certificate automatically?" y && RENEW=yes || RENEW=no
  else
    RENEW=yes
  fi
fi
[[ $RENEW == yes ]] && RENEWAL=enable || RENEWAL=disable

summary Domain "$FQDN"
summary Email "$EMAIL"
summary Proxy "$PROXY in the proxy container (it stops for a few seconds while Let's Encrypt checks the domain)"
if [[ $TEST == true ]]; then
  summary Test "dry run against Let's Encrypt's staging server: no certificate, no config change"
else
  summary Renewal "$( [[ $RENEW == yes ]] && echo automatic || echo "off (renew by hand before it expires)" )"
  summary "Check first" "http://$FQDN must reach this server: DNS points here, port 80 is open, the proxy is running."
  summary "" "Too many failed requests get you blocked by Let's Encrypt for a while: test with --dry-run first."
fi
confirm_summary "$( [[ $TEST == true ]] && echo "Run the test?" || echo "Request the certificate for $FQDN?" )"

if [[ $TEST == true ]]; then
  [[ $PROXY == apache2 ]] && SVC=apache2 || SVC=nginx
  if lxc exec proxy -- certbot certonly --dry-run --standalone -d "$FQDN" -m "$EMAIL" --agree-tos -n --no-eff-email \
       --pre-hook "service $SVC stop" --post-hook "service $SVC start"; then
    echo "The test passed: Let's Encrypt can reach $FQDN. Run dhis2-ssl-setup without --dry-run to get the certificate."
    exit 0
  fi
  die "the test failed: check that $FQDN points to this server and that port 80 reaches the proxy"
fi

if [[ $PROXY == "nginx" ]]; then
	# the stop/start hooks are saved in the renewal config, so 'certbot renew' works later
	lxc exec proxy -- certbot certonly -d $FQDN --standalone -m $EMAIL --agree-tos -n --no-eff-email \
		--pre-hook "service nginx stop" --post-hook "service nginx start"

	####
	# ssl-files.conf
	####
cat <<EOF > /tmp/ssl-files.conf
ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
EOF

	lxc file push /tmp/ssl-files.conf proxy/etc/nginx/conf.d/ssl-files.conf
	rm /tmp/ssl-files.conf
	
	cat configs/nginx-dhis2.conf > /tmp/nginx.conf
	sed -i "s/listen 80;/listen 443 ssl http2;/g" /tmp/nginx.conf
	sed -i "/^  # Main server block.*/i  # Redirect http to https\n  server {\n    listen 80 ;\n    server_name FQDN;\n    return 301 https://\$host\$request_uri;\n  }\n" /tmp/nginx.conf
	sed -i "s/FQDN/${FQDN}/" /tmp/nginx.conf

	lxc file push /tmp/nginx.conf proxy/etc/nginx/nginx.conf
	rm /tmp/nginx.conf

	lxc exec proxy -- service nginx restart
elif [[ $PROXY == "apache2" ]]; then
	# the stop/start hooks are saved in the renewal config, so 'certbot renew' works later
	lxc exec proxy -- certbot certonly --non-interactive --standalone --agree-tos -m $EMAIL -d $FQDN \
		--pre-hook "service apache2 stop" --post-hook "service apache2 start"
	lxc exec proxy -- a2dissite 000-default
	lxc exec proxy -- a2ensite apache-dhis2
	lxc exec proxy -- service apache2 reload
fi

# certbot runs renewals from a systemd timer: certbot.timer (apt) or snap.certbot.renew.timer (snap)
for TIMER in certbot.timer snap.certbot.renew.timer; do
	lxc exec proxy -- systemctl $RENEWAL --now $TIMER 2>/dev/null
done
if [[ $RENEWAL == enable ]]; then
	echo "Automatic renewal is on. Test it with: lxc exec proxy -- certbot renew --dry-run"
else
	echo "Automatic renewal is off. Renew before expiry with: lxc exec proxy -- certbot renew"
fi
