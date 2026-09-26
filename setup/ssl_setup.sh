#!/usr/bin/env bash
#
#   Get a letsencrypt certificate for the fqdn and switch the proxy to https.
#   Usage: sudo dhis2-ssl-setup

cd "$(dirname "$(readlink -f "$0")")" || exit 1

# Parse json config file
source parse_config.sh

echo "IMPORTANT WARNING"
echo "================="
echo "You are about to attempt to setup a TLS certificate from"
echo "letsencrypt.org for $FQDN.  Please first check that you"
echo "can reach http://$FQDN from your browser.  If you cannot"
echo "reach it then there is some problem with your setup.  It could"
echo "be:"
echo "1. failure to resolve DNS"
echo "2. external or host based firewall issue"
echo "3. proxy service is not running"
echo "If you cannot access, then do not proceed.  Exit now and resolve"
echo "the issue before trying again.  If you make too many failed"
echo "requests to run this script you will be banned by letsencrypt."
echo
echo "Are you really sure you want to install ssl certificate now?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) break;;
        No ) exit;;
    esac
done

echo
echo "Letsencrypt certificates expire after 90 days."
read -r -p "Renew the certificate automatically? [Y/n] " ANSWER
[[ $ANSWER =~ ^[Nn] ]] && RENEWAL=disable || RENEWAL=enable

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
