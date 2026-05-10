#!/bin/bash

set -e
set -o pipefail

readonly CONFIG_FILE='./smart-unlock.cnf' # TODO: move this to its proper location
readonly RUNDIR="$XDG_RUNTIME_DIR/smart-unlock" # TODO: sanity checks for this
readonly MODDIR='./modules' # TODO: adapt to system-wide installation

err(){ echo $@ 1>&2; }

debug(){
    if [ "$DEBUG" == 1 ]; then
        echo 'debug:' "$@"
    fi
}

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    err "The '$CONFIG_FILE' doesn't exist!"
    exit 1
fi

mod(){ # Module action wrapper
    # TODO: add sanity checks
    local FUNC="$1"
    shift
    "mod_${MOD}_${FUNC}" "$@" 2>&1
}

mod_log(){ # Module action wrapper, prepend module name
    # TODO: add sanity checks
    mod "$@" 2>&1 | sed "s/^/$MOD: /"
}



unlock_if_locked(){
    if loginctl show-session $XDG_SESSION_ID -p LockedHint |
        awk -F= '{print $2}' | grep -q '^yes$'
    then
        echo "Session locked, unlocking" >&2
        loginctl unlock-session "$XDG_SESSION_ID"
        if [ "$NOTIFY" ]; then
            DEV_NAME="$(mod pretty_name)"
            notify-send -i unlock -a 'Smart Unlock'\
                "Session unlocked due to \"$DEV_NAME\" connecting via \"$MOD\""
        fi
    else
        debug "Session unlocked already, not doing anything"
    fi
}

# initialize working directory
mkdir -vpm 700 "$RUNDIR"

# initialize modules
# TODO: check deps
. "$MODDIR/common" # source common module funcs
for MOD in "${MODULES[@]}"; do
    echo "Initializing module '$MOD'..."
    . "$MODDIR/$MOD"
    mod_log init
    debug "MOD_DESC='$MOD_DESC'"
done
unset MOD

# initialize devices
for DEV_STR in "${DEVICES[@]}"; do
echo "Initializing device $DEV_STR..."
    MOD=$(awk -F '::' '{ print $1}' <<<"$DEV_STR")
    DEV_ID=$(awk -F '::' '{ print $2}' <<<"$DEV_STR")
    debug "Device ID: $DEV_ID, module: $MOD"

    mod_log init_dev $DEV_ID
done
unset DEV
unset MOD

# Cleanup on exit
trap \
    "echo;
    echo 'Cleaning stuff up before exiting...';
    rm -rv $RUNDIR" \
    SIGTERM SIGINT

# Main loop
while true; do
    for DEV_STR in "${DEVICES[@]}"; do
        MOD=$(awk -F '::' '{ print $1}' <<<"$DEV_STR")
        DEV_ID=$(awk -F '::' '{ print $2}' <<<"$DEV_STR")
        if mod_log check_connect "$DEV_ID"; then
            unlock_if_locked
        fi
    done
    sleep "$CHECK_FREQ"
done
