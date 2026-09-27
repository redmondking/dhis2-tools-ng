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
if [[ $PROXY == nginx ]]; then
  # certbot --webroot: Let's Encrypt checks the domain through the running proxy
  lxc exec proxy -- test -f /etc/nginx/snippets/acme-challenge.conf \
    && lxc exec proxy -- grep -q 'snippets/acme-challenge.conf' /etc/nginx/nginx.conf \
    || die "the proxy is from an older version and can't serve Let's Encrypt's check yet: run sudo dhis2-upgrade-setup first"
  summary Proxy "nginx in the proxy container (keeps running: Let's Encrypt checks the domain through it)"
else
  summary Proxy "$PROXY in the proxy container (it stops for a few seconds while Let's Encrypt checks the domain)"
fi
if [[ $TEST == true ]]; then
  summary Test "dry run against Let's Encrypt's staging server: no certificate, no config change"
else
  summary Renewal "$( [[ $RENEW == yes ]] && echo automatic || echo "off (renew by hand before it expires)" )"
  summary "Check first" "http://$FQDN must reach this server: DNS points here, port 80 is open, the proxy is running."
  summary "" "Too many failed requests get you blocked by Let's Encrypt for a while: test with --dry-run first."
fi
confirm_summary "$( [[ $TEST == true ]] && echo "Run the test?" || echo "Request the certificate for $FQDN?" )"

if [[ $TEST == true ]]; then
  if [[ $PROXY == nginx ]]; then
    TEST_CMD=(certbot certonly --dry-run --webroot -w /var/www/letsencrypt)
  else
    TEST_CMD=(certbot certonly --dry-run --standalone --pre-hook "service apache2 stop" --post-hook "service apache2 start")
  fi
  if lxc exec proxy -- "${TEST_CMD[@]}" -d "$FQDN" -m "$EMAIL" --agree-tos -n --no-eff-email; then
    echo "The test passed: Let's Encrypt can reach $FQDN. Run dhis2-ssl-setup without --dry-run to get the certificate."
    exit 0
  fi
  die "the test failed: check that $FQDN points to this server and that port 80 reaches the proxy"
fi

if [[ $PROXY == "nginx" ]]; then
	# 1. the certificate, through the running proxy. The reload hook is saved in the renewal config, so renewals
	#    reload nginx and never stop it. Nothing else changes until the certificate really exists.
	lxc exec proxy -- certbot certonly --webroot -w /var/www/letsencrypt -d "$FQDN" -m "$EMAIL" --agree-tos -n --no-eff-email \
		--deploy-hook "service nginx reload" \
		|| die "Let's Encrypt did not issue the certificate. Check that $FQDN points to this server and that port 80 reaches the proxy, then test with: sudo dhis2-ssl-setup --dry-run. The proxy is unchanged (http still works)."
	CERT=/etc/letsencrypt/live/$FQDN
	lxc exec proxy -- test -f "$CERT/fullchain.pem" \
		|| die "certbot finished, but $CERT/fullchain.pem is missing. The proxy is unchanged (http still works)."

	# 2. the https configuration
	WORK=$(mktemp -d)
	printf 'ssl_certificate %s/fullchain.pem;\nssl_certificate_key %s/privkey.pem;\n' "$CERT" "$CERT" > "$WORK/ssl-files.conf"
	cat configs/nginx-dhis2.conf > "$WORK/nginx.conf"
	sed -i "s/listen 80;/listen 443 ssl http2;/g" "$WORK/nginx.conf"
	# http -> https, except Let's Encrypt's check (a server-level return would redirect that too)
	sed -i "/^  # Main server block.*/i  # Redirect http to https\n  server {\n    listen 80 ;\n    server_name FQDN;\n    include snippets/acme-challenge.conf;\n    location / {\n      return 301 https://\$host\$request_uri;\n    }\n  }\n" "$WORK/nginx.conf"
	sed -i "s/FQDN/${FQDN}/" "$WORK/nginx.conf"

	# 3. keep the current files, switch, test; a failed test puts the old ones back
	lxc exec proxy -- cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.before-ssl
	HAD_SSL_FILES=false
	if lxc exec proxy -- test -f /etc/nginx/conf.d/ssl-files.conf; then
		HAD_SSL_FILES=true
		lxc exec proxy -- cp /etc/nginx/conf.d/ssl-files.conf /etc/nginx/conf.d/ssl-files.conf.before-ssl
	fi
	lxc file push "$WORK/ssl-files.conf" proxy/etc/nginx/conf.d/ssl-files.conf
	lxc file push "$WORK/nginx.conf" proxy/etc/nginx/nginx.conf
	rm -rf "$WORK"
	if ! lxc exec proxy -- nginx -t; then
		lxc exec proxy -- cp /etc/nginx/nginx.conf.before-ssl /etc/nginx/nginx.conf
		if [[ $HAD_SSL_FILES == true ]]; then
			lxc exec proxy -- cp /etc/nginx/conf.d/ssl-files.conf.before-ssl /etc/nginx/conf.d/ssl-files.conf
		else
			lxc exec proxy -- rm -f /etc/nginx/conf.d/ssl-files.conf
		fi
		die "the new https configuration failed nginx's test, so the previous one was put back (http still works). The certificate is in $CERT."
	fi
	lxc exec proxy -- service nginx reload
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
