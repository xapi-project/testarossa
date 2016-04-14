# /bin/bash
#
# xen-test-vm.sh [version] - downloads template of VM
#

FORCE="no"
VERSION="${1:-0.0.5}"
NAME="xen-test-vm-$VERSION"
GH="https://github.com/xapi-project"
VM="$GH/xen-test-vm/releases/download/$VERSION/test-vm.xen.gz"
KERNEL="xen-test-vm-${VERSION//./-}.xen.gz"

errcho() { echo "$@" 1>&2; }


if test -f ${KERNEL}; then
  errcho "Version ${VERSION} already present: ${KERNEL}"
  errcho "Remove it first to download it again"
  exit 0
fi

curl --fail -s -L "$VM" > "$KERNEL"
if [ $? -ne 0 ]; then
  errcho "Can't download $VM"
  rm -f "${KERNEL}"
  exit 1
fi

exit 0



