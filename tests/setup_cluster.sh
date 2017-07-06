#!/bin/bash
set -x
set -e

# workaround NilClass exception
vagrant up infrastructure || vagrant up infrastructure

HOSTS=$(vagrant status |  grep ^cluster |cut -f1 -d' '|xargs echo)
vagrant up $HOSTS
echo $HOSTS

echo "Cluster auth"
echo "============"
vagrant ssh cluster1 -c "sudo pcs cluster auth -u hacluster -p mysecurepassword $HOSTS"

echo "Cluster setup"
echo "============="

vagrant ssh cluster1 -c "sudo pcs cluster setup --name cluster $HOSTS"

echo "Cluster start"
echo "============="

vagrant ssh cluster1 -c "sudo pcs cluster enable --all"
vagrant ssh cluster1 -c "sudo pcs cluster start --all"
