#!/bin/sh
set -x
set -e
echo "Destroying cluster on $(uname -n)"
xcli destroy
