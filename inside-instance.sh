#!/bin/bash -eu
set -o pipefail

. settings.conf

fail() {
	local message="$1"
	local logFile=""
	
	if [ $# -ge 2 ]; then
		logFile="$2"
	fi
	
	echo "ERROR: $message (line ${BASH_LINENO[0]})" >&2
	
	if [ -f "$logFile" ]; then
		echo -e "\nContent of ${logFile}:\n" >&2
		cat "$logFile" >&2
	fi
	
	exit 1
}

mkdir log || fail "Couldn't make log directory"

NVIDIA_FILE="NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
NVIDIA_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/$NVIDIA_DRIVER_VERSION/$NVIDIA_FILE"

# NVIDIA doesn't seem to provide checksums for their drivers. :-( Use what Gentoo thinks is right (better than nothing).
NVIDIA_SHA256_URL="https://gitweb.gentoo.org/repo/gentoo.git/plain/x11-drivers/nvidia-drivers/Manifest"
NVIDIA_SHA256=$(
	wget --no-verbose -o log/nvidia-sha256.log -O - "$NVIDIA_SHA256_URL" |
		awk "/ $NVIDIA_FILE /"'{gsub(".*SHA256 ", ""); gsub(" .*", ""); print}'
) || fail "Fetching NVIDIA driver manifest (to obtain SHA-256 checksum) from Gentoo repo failed" "log/nvidia-sha256.log"


if [[ ! "$NVIDIA_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
	fail "Failed to obtain valid checksum from Gentoo manifest (value: $NVIDIA_SHA256)"
fi

# Note: NVIDIA does something rather bad: Their download URL hostname is actually a CNAME to an Akamai CDN server,
# which doesn't use SNI for TLS connections and just spits out an Akamai cert--which, of course, triggers a cert
# mismatch error in wget if you don't disable cert checking. :-( That's probably why the download URL NVIDIA provides
# on their website is HTTP, not HTTPS--which, combined with their failure to provide a checksum for the download, is
# a really bad situation! We'll do the best we can by 1) downloading over HTTPS (even though the cert doesn't match),
# and 2) checking against Gentoo's SHA256 checksum for the file (although one assumes Gentoo just generated the hash for
# the file they downloaded from NVIDIA, rather than getting an authoritative checksum from NVidia... somehow).
wget --no-verbose -o "log/nvidia-driver-download.log" \
	-O nvidia-driver.run \
	--no-check-certificate --secure-protocol TLSv1_2 \
	"$NVIDIA_URL" || \
		fail "Failed to download NVIDIA driver installer" "log/nvidia-driver-download.log"
sha256sum -c >"log/sha256sum.log" 2>&1 <<<"$NVIDIA_SHA256 nvidia-driver.run" ||
	fail "SHA-256 verification of downloaded NVIDIA driver FAILED!" "log/sha256sum.log"

chmod +x nvidia-driver.run >"log/chmod-nvidia-driver.log" 2>&1 ||
	fail "Failed to set execute permission on NVIDIA driver" "log/chmod-nvidia-driver.log"

./nvidia-driver.run --silent --disable-nouveau --no-opengl-files >/dev/null 2>&1 ||
	fail "Failed to install NVIDIA driver" "/var/log/nvidia-installer.log"
