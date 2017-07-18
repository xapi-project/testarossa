#/bin/sh
set -e
set -x
pcs cluster node remove $1
