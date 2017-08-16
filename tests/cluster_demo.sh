#!/bin/bash
#
# Builds a cluster of three nodes, then removes all nodes.
# Expects xapi-clusterd to be running on each node.
#

set -x
set -e

SSH_CONFIG=ssh-config
SSH="ssh -F $SSH_CONFIG"

if [ ! -e "$SSH_CONFIG" ]
then
	echo "Generate ssh config..."
	vagrant ssh-config cluster1 cluster2 cluster3 infrastructure > $SSH_CONFIG
fi

echo "Get node eth1 IP addresses"
c1=$($SSH cluster1 "sudo ip addr show dev eth1 | grep 'state UP' -A2 | tail -n1 | awk '{print \$2}' | cut -f1  -d'/'")
c2=$($SSH cluster2 "sudo ip addr show dev eth1 | grep 'state UP' -A2 | tail -n1 | awk '{print \$2}' | cut -f1  -d'/'")
c3=$($SSH cluster3 "sudo ip addr show dev eth1 | grep 'state UP' -A2 | tail -n1 | awk '{print \$2}' | cut -f1  -d'/'")

echo "c1 = '$c1'"
echo "c2 = '$c2'"
echo "c3 = '$c3'"

echo "Destroy any existing configuration"
$SSH cluster1 'sudo xcli destroy'
$SSH cluster2 'sudo xcli destroy'
$SSH cluster3 'sudo xcli destroy'

echo "Create cluster on node 1 ($c1)"
stdout=$($SSH cluster1 'sudo xcli create "{\"hostname\":\"cluster1\",\"addresses\":[\"'$c1'\"]}"')
echo $stdout | grep '^\[' && (echo "CLI command failed"; exit 1)

secret=$(echo $stdout | sed 's/^S(//' | sed 's/)$//')

echo "Secret token was '$secret'"

echo "Join node 2 ($c2) to the cluster"
stdout=$($SSH cluster2 "sudo xcli join $secret '{\"hostname\":\"cluster2\",\"addresses\":[\"$c2\"]}' '[{\"hostname\":\"cluster1\",\"addresses\":[\"$c1\"]}]'")
echo $stdout | grep '^N$' || (echo "CLI command failed"; exit 1)

echo "Join node 3 ($c3) to the cluster"
stdout=$($SSH cluster3 "sudo xcli join $secret '{\"hostname\":\"cluster3\",\"addresses\":[\"$c3\"]}' '[{\"hostname\":\"cluster1\",\"addresses\":[\"$c1\"]}, {\"hostname\":\"cluster2\",\"addresses\":[\"$c2\"]}]'")
echo $stdout | grep '^N$' || (echo "CLI command failed"; exit 1)

echo "Shut down node 2 ($c2)"
stdout=$($SSH cluster2 "sudo xcli shutdown")
echo $stdout | grep '^N$' || (echo "CLI command failed"; exit 1)

echo "Shut down node 3 ($c3)"
stdout=$($SSH cluster3 "sudo xcli shutdown")
echo $stdout | grep '^N$' || (echo "CLI command failed"; exit 1)

echo "Destroy node 1 ($c1)"
stdout=$($SSH cluster1 "sudo xcli destroy")
echo $stdout | grep '^N$' || (echo "CLI command failed"; exit 1)
