# tools/lib.sh - helpers shared by the scripts in this folder. Sourced, never
# run: it defines functions and does nothing else.
#
# matrix.sh is bash and runtests.sh is zsh, so everything here has to work in
# both. The one real trap is globbing: an unmatched glob expands to itself in
# bash but aborts the script in zsh, so loops over one both guard each hit and
# ask zsh for null_glob, local to the function.

# The Connect IQ SDK folder, printed without a trailing slash; nothing at all
# when no SDK can be found, which the caller is expected to treat as fatal.
#
#   $CIQ_SDK / $CIQ_HOME   an explicit override, used as given
#   current-sdk.cfg        the SDK the SDK manager currently points at
#   ~/connectiq-sdk        the symlink convention the docs use
#   newest installed SDK   by folder date, because SDK version numbers do not
#                          sort by name
#
# Deliberately never a pinned build id: a script that names one keeps working
# only until the SDK manager installs the next SDK.
ciq_find_sdk() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt local_options null_glob
    fi
    if [ -n "${CIQ_SDK:-}" ]; then printf '%s' "${CIQ_SDK%/}"; return; fi
    if [ -n "${CIQ_HOME:-}" ]; then printf '%s' "${CIQ_HOME%/}"; return; fi
    local cfg dir newest
    for cfg in "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg" \
               "$HOME/.Garmin/ConnectIQ/current-sdk.cfg"; do
        if [ -f "$cfg" ]; then
            dir=$(tr -d '\r\n' < "$cfg"); dir=${dir%/}
            if [ -x "$dir/bin/monkeyc" ]; then printf '%s' "$dir"; return; fi
        fi
    done
    [ -x "$HOME/connectiq-sdk/bin/monkeyc" ] && { printf '%s' "$HOME/connectiq-sdk"; return; }
    newest=""
    for dir in "$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks"/*/ \
               "$HOME/.Garmin/ConnectIQ/Sdks"/*/; do
        [ -x "${dir%/}/bin/monkeyc" ] || continue
        if [ -z "$newest" ] || [ "${dir%/}" -nt "$newest" ]; then newest=${dir%/}; fi
    done
    [ -n "$newest" ] && printf '%s' "$newest"
}
