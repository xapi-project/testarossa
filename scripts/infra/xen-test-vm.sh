# /bin/sh
#
# xen-test-vm.sh [version]   - installs template of VM
#
#
# This code retrieves a Mirage unikernel and installs it as a new
# template on the host under the name 'xen-test-vm' and writes the UUID
# of the template to stdout. This needs to be run as root.

set -e

if [[ $EUID -ne 0 ]]; then
  echo "You must be root to run $0" 2>&1
  exit 1
fi

VERSION=${1:-"0.0.5"}
NAME="xen-test-vm-$VERSION"
GH="https://github.com/xapi-project"
VM="$GH/xen-test-vm/releases/download/$VERSION/test-vm.xen.gz"

test -d /boot/guest || mkdir /boot/guest
curl -L $VM | gunzip > /boot/guest/test-vm.xen

UUID=$(xe vm-create name-label="$NAME")
xe vm-param-set PV-kernel=/boot/guest/test-vm.xen uuid="$UUID"

echo "$UUID"
exit 0



