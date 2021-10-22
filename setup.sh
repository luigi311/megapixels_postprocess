#!/bin/bash

set -e

setup_main() {
    PASSED_USER="$1"
    rm -rf /etc/megapixels/postprocess.sh

    mkdir -p /etc/megapixels

    ln -s "${PWD}/postprocess.sh" /etc/megapixels/postprocess.sh

    chmod 777 /etc/megapixels/postprocess.sh

    if ! command -v "podman" >/dev/null; then
        if command -v "pacman" >/dev/null; then
            pacman -S podman --noconfirm
        elif command -v "apk" >/dev/null; then
            apk add podman
        else
            echo "Unknown package manager, podman needs to be install via your preferred method"
        fi
    fi

    # If /etc/subgid or /etc/subuid do not exist, create them 
    if [ ! -f /etc/subgid ]; then
        touch /etc/subgid
    fi

    if [ ! -f /etc/subuid ]; then
        touch /etc/subuid
    fi

    # If $PASSED_USER is not in /etc/subgid or /etc/subuid
    if ! grep -q "^${PASSED_USER}:" /etc/subgid || ! grep -q "^${PASSED_USER}:" /etc/subuid; then
        echo "Adding ${PASSED_USER} to /etc/subgid and /etc/subuid"
        usermod --add-subuids 200000-201000 --add-subgids 200000-201000 "$PASSED_USER"
        echo "Setup complete, reboot machine"
    fi
}


export -f setup_main
FUNC=$(declare -f setup_main)

if [[ $EUID -ne 0 ]]; then
    USER="$(whoami)"
    sudo bash -c "$FUNC; setup_main $USER"
else
    echo "Script must not be ran as root"
    exit 1
fi
