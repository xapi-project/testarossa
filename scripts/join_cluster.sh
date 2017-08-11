#!/bin/sh
set -x
set -e

ISCSI_IP=169.254.0.16  # TODO pass this in
NODE=$(uname -n)

#IP_ADDRS=$(ip addr | fgrep inet | grep -v ' lo$' | awk '{print $2}' | sed 's/\/[0-9]*$//')
IP_ADDRS=$(ip addr | fgrep inet | grep ' eth1$' | awk '{print $2}' | sed 's/\/[0-9]*$//')  # TODO only use eth1 until corosync config can cope with more interfaces

secret=$1
existing=$2 # TODO should take all options passed in

echo "Joining node $NODE to cluster on $existing (using secret $secret)"

ADDRS=$(echo $IP_ADDRS | sed 's/ /","/g')
xcli join $secret '{"hostname":"'$NODE'","addresses":["'$ADDRS'"]}' '[{"hostname":"","addresses":["'$existing'"]}]'

echo "Mounting GFS2"
mount -t gfs2 -o noatime,nodiratime /dev/disk/by-path/ip-169*-0 /mnt
#echo "OK"
