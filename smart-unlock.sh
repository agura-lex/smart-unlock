#!/bin/bash

# shellcheck disable=SC2174

set -e
set -o pipefail

# -- Essential functions
usage(){
    echo "Usage: $(basename "$0") [OPTS]"
    echo 'A daemon for auto-unlocking desktop session when a device is connected'
    echo
    echo 'Options:'
    echo '  -l|--local      Run without installation, from a repo directory'
    echo '  -d|--debug      Be more versbose than it makes sense'
}

err(){ echo "$@" 1>&2; }

debug(){
    if [ "$DEBUG" == 1 ]; then
        echo 'debug:' "$@"
    fi
}


# -- Arg parsing
for ARG in "$@"; do
    case "$ARG" in
        '-u'|'--usage'|'-h'|'--help') usage ;;
        '-l'|'--local') LOCAL_RUN=1 ;;
        '-d'|'--debug') CLI_DEBUG=1 ;;
        *)
            echo "'$ARG': unknown argument"
            exit 1
    esac
done


## -- Setting the constants
readonly RUNDIR="$XDG_RUNTIME_DIR/smart-unlock" # TODO: sanity checks for this

if [ "$LOCAL_RUN" == 1 ]; then
    debug 'Running locally (from a single directory)'

    APPDIR="$(dirname "$0")"
    readonly APPDIR
    readonly DEFAULTS_CNF_FILE="$APPDIR/defaults.cnf"
    readonly CONFIG_FILE="$APPDIR/smart-unlock.cnf"
    readonly MODDIR="$APPDIR/modules"

    debug "Directory to run from: $APPDIR"
else
    readonly DEFAULTS_CNF_FILE="/usr/share/defaults.cnf"
    readonly CONFIG_FILE="$HOME/.config/smart-unlock.cnf"
    readonly MODDIR="/usr/share/smart-unlock/modules"
fi


# -- Figuring out the configuration
# shellcheck source=defaults.cnf
. "$DEFAULTS_CNF_FILE"

# Init arrays before reading the conf
MODULES=()
DEVICES=()

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=smart-unlock.cnf.sample
    . "$CONFIG_FILE"
else
    err "The '$CONFIG_FILE' doesn't exist!"
    exit 2
fi

# Cli argument overrides
[ -z "$CLI_DEBUG" ] && DEBUG="$CLI_DEBUG"

if [ -z "${MODULES[0]}" ]; then
    echo "No modules enabled, bailing"
    echo "Be sure to set the MODULES variable in '$CONFIG_FILE'!"
    exit 2
fi

if [ -z "${DEVICES[0]}" ]; then
    echo "No devices added, bailing"
    echo "Be sure to set the DEVICES variable in '$CONFIG_FILE'!"
    exit 2
fi


# -- More functions
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

mod_log_err(){
    mod_log "$@" >&2
}

check_mod(){
    #debug "Checking if module '$MOD' is enabled"
    for M in "${MODULES[@]}"; do
        if [ "$M" == "$MOD" ]; then
            return 0
        fi
    done
    echo "Module '$MOD' not enabled, skipping '$DEV_STR'"
    return 1
}

unlock_if_locked(){
    if loginctl show-session "$XDG_SESSION_ID" -p LockedHint |
        awk -F= '{print $2}' | grep -q '^yes$'
    then
        echo "Session locked, unlocking" >&2
        loginctl unlock-session "$XDG_SESSION_ID"
        if [ "$NOTIFY" ]; then
            DEV_NAME="$(mod pretty_name)"
            notify-send -i unlock -a 'Smart Unlock'\
                "Session unlocked due to \"$DEV_NAME\" connecting via $MOD"
        fi
    else
        debug "Session unlocked already, not doing anything"
    fi
}


# -- Cleanup on exit
trap \
    'echo;
    echo "Cleaning stuff up before exiting...";
    rm -rv "$RUNDIR" ' \
    EXIT



# -- Initialize working directories and files
mkdir -vpm 700 "$RUNDIR"
echo

# initialize modules
# TODO: check deps
# shellcheck source=modules/common
. "$MODDIR/common" # source common module funcs
for MOD in "${MODULES[@]}"; do
    echo "Initializing module '$MOD'..."
    # shellcheck source=modules/kde_connect
    # shellcheck source=modules/bluetooth
    . "$MODDIR/$MOD"
    mod_log init
done
unset MOD
echo

# initialize devices
for DEV_STR in "${DEVICES[@]}"; do
echo "Initializing device $DEV_STR..."
    MOD=$(awk -F '::' '{ print $1}' <<<"$DEV_STR")
    DEV_ID=$(awk -F '::' '{ print $2}' <<<"$DEV_STR")
    debug "Device ID: $DEV_ID, module: $MOD"
    if check_mod; then
        mod_log init_dev "$DEV_ID"
    fi
done
unset DEV
unset MOD
echo


# -- Main loop
while true; do
    for DEV_STR in "${DEVICES[@]}"; do
        MOD=$(awk -F '::' '{ print $1}' <<<"$DEV_STR")
        DEV_ID=$(awk -F '::' '{ print $2}' <<<"$DEV_STR")
        if check_mod > /dev/null; then
            if mod_log check_connect "$DEV_ID"; then
                unlock_if_locked
            fi
        fi
    done
    sleep "$CHECK_FREQ"
done
