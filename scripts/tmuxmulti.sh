#!/bin/sh
# You must run this script from inside tmux!
set -e
WINDOW="watch"
CMD="$1"
shift
if [ $# = 0 ]; then
    echo "Missing arguments" >&2
    exit 1
fi
tmux set -g default-terminal screen
echo $* | xargs -n1 | xargs -I {} echo "${CMD}" | (
    read EXPANDEDCMD
    tmux new-window -d -n "${WINDOW}" sh -c "set -x; $EXPANDEDCMD"
    while read EXPANDEDCMD; do
        tmux split-window -v -t "${WINDOW}" sh -c "set -x; $EXPANDEDCMD"
        tmux select-layout -t "${WINDOW}" tiled
    done
)
