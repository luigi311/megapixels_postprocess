#!/bin/bash

set -e

USER=$(whoami)

# su to root if not already root
[ "$(whoami)" = root ] || exec sudo su -c "$0" root

rm -rf /etc/megapixels/postprocess.sh /etc/megapixels/Low-Power-Image-Processing

ln -s "${PWD}/postprocess.sh" /etc/megapixels/postprocess.sh

if ! command -v "podman" >/dev/null; then
    pacman -S podman --noconfirm
fi

# If /etc/subgid or /etc/subuid do not exist, create them 
if [ ! -f /etc/subgid ]; then
    touch /etc/subgid
fi

if [ ! -f /etc/subuid ]; then
    touch /etc/subuid
fi

# If $USER is not in /etc/subgid or /etc/subuid
if ! grep -q "^$USER:" /etc/subgid || ! grep -q "^$USER:" /etc/subuid; then
    # Add $USER to /etc/subgid
    echo "Adding ${USER} to /etc/subgid"
    usermod --add-subuids 200000-201000 --add-subgids 200000-201000 "$USER"
fi

reboot