#!/usr/bin/env bash
#
#   Set up this host: LXD, kernel settings, firewall, then the proxy/postgres/monitor containers.
#   Usage: sudo dhis2-setup [containers.json]
#     containers.json  server description to use; copied to /usr/local/etc/dhis/containers.json
#                      (default: the one already there)

set -e
cd "$(dirname "$(readlink -f "$0")")"

CONFIG=/usr/local/etc/dhis/containers.json
if [[ -n $1 ]]; then
  [[ -f $1 ]] || { echo "No such file: $1" >&2; exit 1; }
  python3 -m json.tool "$1" >/dev/null 2>&1 || { echo "Not valid JSON: $1" >&2; exit 1; }
  mkdir -p /usr/local/etc/dhis
  cp "$1" "$CONFIG"
elif [[ ! -f $CONFIG ]]; then
  echo "No $CONFIG yet. Create it from the sample, then run this again:" >&2
  echo "  sudo mkdir -p /usr/local/etc/dhis" >&2
  echo "  sudo cp $PWD/configs/containers.json.sample $CONFIG" >&2
  echo "  sudo nano $CONFIG" >&2
  exit 1
fi

apt-get -y update
apt-get -y upgrade

# remove lxd installed with apt on old releases (usually lxd 3.0.3)
if dpkg -s lxd >/dev/null 2>&1; then
  apt-get -y remove --purge lxd
  apt-get -y autoremove
fi

# install lxd with snap
snap install lxd 

# initializing lxd system
cat configs/lxd_preseed | sudo lxd init --preseed

# kernel tweaks
cp configs/sysctl /etc/sysctl.d/60-dhis2-lxd.conf
sysctl --system || echo "Warning: some kernel settings could not be applied"

sudo ufw route allow in on lxdbr0
sudo ufw route allow out on lxdbr0

source install_scripts.sh

# Create the containers
source create_containers.sh
