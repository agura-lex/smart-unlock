#!/bin/bash

set -e
set -o pipefail

readonly CONFIG_FILE='./smart-unlock.cnf' # TODO: move this to its proper location
readonly RUNDIR="$XDG_RUNTIME_DIR/smart-unlock" # TODO: sanity checks for this
readonly MODDIR='./modules' # TODO: adapt to system-wide installation

err(){ echo $@ 1>&2; }
debug(){
    [ "$DEBUG" == 1 ] && echo 'debug:' "$@"
}

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    err "The '$CONFIG_FILE' doesn't exist!"
    exit 1
fi

mod(){ # Module action wrapper
    # TODO: add sanity checks
    mod_$MOD "$@" 2>&1 | sed "s/^/$MOD: /"
}

unlock_if_locked(){
    if loginctl show-session $XDG_SESSION_ID -p LockedHint |
        awk -F= '{print $2}' | grep -q '^yes$'
    then
        echo "Session locked, unlocking" >&2
        loginctl unlock-session $XDG_SESSION_ID
        #notify-send -i unlock -a $0\
            #"Session unlocked due to \"$DEVICE_NAME\" connecting"
    else
        debug "Session unlocked already, not doing anything"
    fi
}

# initialize working directory
mkdir -vpm 700 "$RUNDIR"

# initialize modules
for MOD in "${MODULES[@]}"; do
    echo "Initializing module '$MOD'..."
    . "$MODDIR/$MOD"
    mod init
done
unset MOD

# initialize devices
for DEV_STR in "${DEVICES[@]}"; do
echo "Initializing device $DEV_STR..."
    MOD=$(awk -F '::' '{ print $1}' <<<"$DEV_STR")
    DEV_ID=$(awk -F '::' '{ print $2}' <<<"$DEV_STR")
    debug "Device ID: $DEV_ID, module: $MOD"

    mod init_dev $DEV_ID
done
unset DEV
unset MOD


# Main loop
while true; do
    for DEV_STR in "${DEVICES[@]}"; do
        MOD=$(awk -F '::' '{ print $1}' <<<"$DEV_STR")
        DEV_ID=$(awk -F '::' '{ print $2}' <<<"$DEV_STR")
        if mod check_connect "$DEV_ID"; then
            unlock_if_locked
        fi
    done
    sleep "$CHECK_FREQ"
done



exit


DEVICE_ID="$1"
DEVICE_NAME="$(qdbus org.kde.kdeconnect /modules/kdeconnect/devices/$DEVICE_ID org.kde.kdeconnect.device.name)"
OLD_STATE=1 # assume device was connected at script launch

checkconnect(){
    #if [[ $(kdeconnect-cli -a --id-only 2>/dev/null) == $DEVICE_ID ]]; then
    if [[ "$(qdbus org.kde.kdeconnect /modules/kdeconnect/devices/"$DEVICE_ID" \
	    org.kde.kdeconnect.device.isReachable)" == true ]]; then
        CONNECTED=1
    else
        CONNECTED=0
        # force device search to check if it is indeed unavailable
        kdeconnect-cli --refresh
    fi
    #qdbus org.kde.kdeconnect /modules/kdeconnect/devices/"$DEVICE_ID" org.kde.kdeconnect.device.isReachable
}

echo "Monitoring for '$DEVICE_NAME' ($DEVICE_ID) connections..." >&2

while true; do
    checkconnect
    if [[ $CONNECTED -gt $OLD_STATE ]]; then
       echo "Device $DEVICE_ID connected" >&2
       #loginctl show-session $XDG_SESSION_ID -p LockedHint
       if loginctl show-session $XDG_SESSION_ID -p LockedHint | awk -F= '{print $2}' | grep -q '^yes$'
       then
           echo "Session locked, unlocking" >&2
           #xset dpms force on
           loginctl unlock-session $XDG_SESSION_ID &&\
               notify-send -i unlock -a $0 "Session unlocked due to \"$DEVICE_NAME\" connecting"
       fi
    fi
    OLD_STATE=$CONNECTED
    sleep 1
done
