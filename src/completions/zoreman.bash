# bash completion for zoreman
#
# Install:
#   source <(zoreman completion bash)        # current session only
#   zoreman completion bash > \
#     ~/.local/share/bash-completion/completions/zoreman   # every session
#
# Candidates are computed by `zoreman __complete`, which reads the Procfile
# (honoring -f/--procfile and --basedir typed earlier on the line).

_zoreman() {
    local cur
    COMPREPLY=()
    (( COMP_CWORD >= 1 )) || return 0

    cur="${COMP_WORDS[COMP_CWORD]}"

    local line
    while IFS=$'\n' read -r line; do
        [ -n "$line" ] && COMPREPLY+=("$line")
    done < <(zoreman __complete "${COMP_WORDS[@]:1:COMP_CWORD-1}" "$cur" 2>/dev/null)
}

# `-o default`: when __complete returns no candidates (e.g. the value of
# -f, --env or --basedir, or a LOCATION) fall back to filename completion.
complete -o default -F _zoreman zoreman
