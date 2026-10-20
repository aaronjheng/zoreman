# fish completion for zoreman
#
# Install:
#   zoreman completion fish > ~/.config/fish/completions/zoreman.fish
#
# Candidates are computed by `zoreman __complete`, which reads the Procfile
# (honoring -f/--procfile and --basedir typed earlier on the line). When the
# command outputs nothing (e.g. the value of -f, --env or --basedir, or a
# LOCATION) fish falls back to filename completion on its own.

function __zoreman_complete
    set -l cur (commandline -ct)
    set -l tokens (commandline -opc)
    if test (count $tokens) -gt 1
        set -e tokens[1]
        command zoreman __complete $tokens "$cur" 2>/dev/null
    else
        command zoreman __complete "$cur" 2>/dev/null
    end
end

complete -c zoreman -a '(__zoreman_complete)'
