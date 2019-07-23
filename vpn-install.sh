#!/bin/sh
#
# Script for automatic setup of an IPsec VPN server on Ubuntu LTS and Debian.
# Works on any dedicated server or virtual private server (VPS) except OpenVZ.
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC!
#
# The latest version of this script is available at:
# https://github.com/hwdsl2/setup-ipsec-vpn
#
# Copyright (C) 2014-2019 Lin Song <linsongui@gmail.com>
# Based on the work of Thomas Sarlandie (Copyright 2012)
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# =====================================================

# Define your own values for these variables
# - IPsec pre-shared key, VPN username and password
# - All values MUST be placed inside 'single quotes'
# - DO NOT use these special characters within values: \ " '

# Important notes:   https://git.io/vpnnotes
# Setup VPN clients: https://git.io/vpnclients

# =====================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SYS_DT=$(date +%F-%T)

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'apt-get install' failed."; }
conf_bk() { /bin/cp -f "$1" "$1.old-$SYS_DT" 2>/dev/null; }
bigecho() { echo; echo "## $1"; echo; }

check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

vpn_install() {

os_type=$(lsb_release -si 2>/dev/null)
if [ -z "$os_type" ]; then
  [ -f /etc/os-release  ] && os_type=$(. /etc/os-release  && printf '%s' "$ID")
  [ -f /etc/lsb-release ] && os_type=$(. /etc/lsb-release && printf '%s' "$DISTRIB_ID")
fi
if ! printf '%s' "$os_type" | head -n 1 | grep -qiF -e ubuntu -e debian -e raspbian; then
  exiterr "This script only supports Ubuntu and Debian."
fi

if [ "$(sed 's/\..*//' /etc/debian_version)" = "7" ]; then
  exiterr "Debian 7 is not supported."
fi

if [ -f /proc/user_beancounters ]; then
  exiterr "OpenVZ VPS is not supported. Try OpenVPN: github.com/Nyr/openvpn-install"
fi

if [ "$(id -u)" != 0 ]; then
  exiterr "Script must be run as root. Try 'sudo sh $0'"
fi

def_iface=$(route 2>/dev/null | grep -m 1 '^default' | grep -o '[^ ]*$')
[ -z "$def_iface" ] && def_iface=$(ip -4 route list 0/0 2>/dev/null | grep -m 1 -Po '(?<=dev )(\S+)')
def_state=$(cat "/sys/class/net/$def_iface/operstate" 2>/dev/null)
if [ -n "$def_state" ] && [ "$def_state" != "down" ]; then
  if ! uname -m | grep -qi '^arm'; then
    case "$def_iface" in
      wl*)
        exiterr "Wireless interface '$def_iface' detected. DO NOT run this script on your PC or Mac!"
        ;;
    esac
  fi
  NET_IFACE="$def_iface"
else
  eth0_state=$(cat "/sys/class/net/eth0/operstate" 2>/dev/null)
  if [ -z "$eth0_state" ] || [ "$eth0_state" = "down" ]; then
    exiterr "Could not detect the default network interface."
  fi
  NET_IFACE=eth0
fi

bigecho "VPN setup in progress... Please be patient."

# Create and change to working dir
mkdir -p /opt/src
cd /opt/src || exit 1

count=0
APT_LK=/var/lib/apt/lists/lock
PKG_LK=/var/lib/dpkg/lock
while fuser "$APT_LK" "$PKG_LK" >/dev/null 2>&1 \
  || lsof "$APT_LK" >/dev/null 2>&1 || lsof "$PKG_LK" >/dev/null 2>&1; do
  [ "$count" = "0" ] && bigecho "Waiting for apt to be available..."
  [ "$count" -ge "60" ] && exiterr "Could not get apt/dpkg lock."
  count=$((count+1))
  printf '%s' '.'
  sleep 3
done

bigecho "Populating apt-get cache..."

export DEBIAN_FRONTEND=noninteractive
apt-get -yq update || exiterr "'apt-get update' failed."

bigecho "Installing packages required for setup..."

apt-get -yq install wget dnsutils openssl \
  iptables iproute2 gawk grep sed net-tools || exiterr2

bigecho "Trying to auto discover IP of this server..."

cat <<'EOF'
In case the script hangs here for more than a few minutes,
press Ctrl-C to abort. Then edit it and manually enter IP.
EOF

bigecho "Installing packages required for the VPN..."

apt-get -yq install libnss3-dev libnspr4-dev pkg-config \
  libpam0g-dev libcap-ng-dev libcap-ng-utils libselinux1-dev \
  libcurl4-nss-dev flex bison gcc make libnss3-tools \
  libevent-dev ppp xl2tpd || exiterr2

bigecho "Installing Fail2Ban to protect SSH..."

apt-get -yq install fail2ban || exiterr2

bigecho "Compiling and installing Libreswan..."

SWAN_VER=3.29
swan_file="libreswan-$SWAN_VER.tar.gz"
swan_url1="https://github.com/libreswan/libreswan/archive/v$SWAN_VER.tar.gz"
swan_url2="https://download.libreswan.org/$swan_file"
if ! { wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url1" || wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url2"; }; then
  exit 1
fi
/bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
tar xzf "$swan_file" && /bin/rm -f "$swan_file"
cd "libreswan-$SWAN_VER" || exit 1
cat > Makefile.inc.local <<'EOF'
WERROR_CFLAGS =
USE_DNSSEC = false
USE_DH31 = false
USE_NSS_AVA_COPY = true
USE_NSS_IPSEC_PROFILE = false
USE_GLIBC_KERN_FLIP_HEADERS = true
EOF
if [ "$(packaging/utils/lswan_detect.sh init)" = "systemd" ]; then
  apt-get -yq install libsystemd-dev || exiterr2
fi
NPROCS=$(grep -c ^processor /proc/cpuinfo)
[ -z "$NPROCS" ] && NPROCS=1
make "-j$((NPROCS+1))" -s base && make -s install-base

cd /opt/src || exit 1
/bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
if ! /usr/local/sbin/ipsec --version 2>/dev/null | grep -qF "$SWAN_VER"; then
  exiterr "Libreswan $SWAN_VER failed to build."
fi

}

## Defer setup until we have the complete script
vpn_install "$@"

exit 0
