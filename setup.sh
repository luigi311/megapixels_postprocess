#!/usr/bin/env sh

set -e


mkdir -p "${HOME}/.config/megapixels"

rm -f "${HOME}/.config/megapixels/postprocess.sh"

ln -s "${PWD}/postprocess.sh" "${HOME}/.config/megapixels/postprocess.sh"

chmod +x "${HOME}/.config/megapixels/postprocess.sh"

if [ "$(id -u)" -eq 0 ]; then
    echo "Script must not be ran as root"
    exit 1
fi

USER="$(whoami)"

if [ -z "${USER}" ]; then
    echo "Could not determine current user"
    exit 1
fi

# Switch to root
sudo -s <<EOF
if [ ! -e /etc/nsswitch.conf ]; then
    echo 'hosts: files dns' > /etc/nsswitch.conf
fi

# If /etc/subgid or /etc/subuid do not exist, create them
if [ ! -f /etc/subgid ]; then
    touch /etc/subgid
fi

if [ ! -f /etc/subuid ]; then
    touch /etc/subuid
fi

if ! command -v "bash" > /dev/null; then
    if command -v "pacman" >/dev/null; then
        pacman -Sy bash
    elif command -v "apk" >/dev/null; then
        apk update
        apk add bash
    fi
fi

if ! command -v "podman" >/dev/null; then
    if command -v "pacman" >/dev/null; then
        pacman -Sy podman fuse-overlayfs --noconfirm
    elif command -v "apk" >/dev/null; then
        apk update
        apk add podman fuse-overlayfs shadow slirp4netns
        rc-update add cgroups
        rc-service cgroups start
        modprobe tun
    else
        echo "Unknown package manager, podman needs to be install via your preferred method"
    fi
fi

# If $USER is not in /etc/subgid or /etc/subuid
if ! grep -q "^${USER}:100000" /etc/subgid || ! grep -q "^${USER}:100000" /etc/subuid; then
    chmod u+s /usr/bin/newuidmap
    chmod u+s /usr/bin/newgidmap
    echo "Adding ${USER} to /etc/subgid and /etc/subuid"
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${USER}"
    echo "User permisisons adjusted, reboot machine afterwards"
fi

podman system migrate
EOF