#!/bin/bash
ip addr show dev eth0 | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/'

