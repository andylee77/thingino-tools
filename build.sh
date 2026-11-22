#!/bin/bash
#
# build.sh - build the Wi-Fi test kit for Ingenic T31 cameras (XBurst1,
# mipsel, uClibc): static iw, tcpdump and iperf3, packed with wifi-watch.sh.
#
# Usage: ./build.sh [-t TOOLCHAIN_DIR] [-w WORK_DIR]
#   -t DIR  an unpacked Thingino XBurst1 uClibc toolchain (the folder with
#           bin/mipsel-thingino-linux-uclibc-gcc). Without -t the script
#           downloads Thingino's toolchain release into WORK_DIR.
#   -w DIR  work folder (default: ./work)
#
# Sources are downloaded from their upstream sites and checked against the
# sha256 sums below; a mismatch stops the build. The toolchain is a rolling
# release asset, so its sum is printed and checked only if TOOLCHAIN_SHA256
# is set. Output: WORK_DIR/wifi-kit-t31.tar.gz and WORK_DIR/sources/ (the
# source tarballs, libnl's among them for LGPL-2.1).
#
# Needs: a Linux x86_64 host with bash, curl, tar, xz, make, pkg-config,
# bison and flex.
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$HERE/work
TC=

while getopts "t:w:h" o; do
	case "$o" in
		t) TC=$(cd "$OPTARG" && pwd) ;;
		w) WORK=$OPTARG ;;
		*) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
	esac
done
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

# name url sha256
SOURCES="
libpcap-1.10.7.tar.gz https://www.tcpdump.org/release/libpcap-1.10.7.tar.gz 0b394ac90dbc0a9838ff97468e05c9c9a3e873dec2514cd58db65d859d296e31
tcpdump-4.99.6.tar.gz https://www.tcpdump.org/release/tcpdump-4.99.6.tar.gz 5839921a0f67d7d8fa3dacd9cd41e44c89ccb867e8a6db216d62628c7fd14b09
libnl-3.12.0.tar.gz https://github.com/thom311/libnl/releases/download/libnl3_12_0/libnl-3.12.0.tar.gz fc51ca7196f1a3f5fdf6ffd3864b50f4f9c02333be28be4eeca057e103c0dd18
iw-6.17.tar.xz https://cdn.kernel.org/pub/software/network/iw/iw-6.17.tar.xz 7d182e498289ab39b257da6780d562e415377107f50358ee5b55b8cfe40b1e33
iperf-3.22.tar.gz https://downloads.es.net/pub/iperf/iperf-3.22.tar.gz 1c0d0fb02c52626111d6e132db80edfbf27bbaff8bd9245df2a371dcb0b35a92
"
TC_NAME=thingino-toolchain-x86_64_xburst1_uclibc_gcc16-linux-mipsel.tar.gz
TC_URL=https://github.com/themactep/thingino-firmware/releases/download/toolchain-x86_64/$TC_NAME

DL=$WORK/sources
SRC=$WORK/src
ST=$WORK/stage
OUT=$WORK/out
KIT=$OUT/wifi-kit-t31
mkdir -p "$DL"
rm -rf "$SRC" "$ST" "$OUT"
mkdir -p "$SRC" "$ST" "$KIT/bin" "$KIT/LICENSES"

fetch() { # name url sha256
	if [ ! -f "$DL/$1" ]; then
		curl -fsSL -o "$DL/$1.part" "$2"
		mv "$DL/$1.part" "$DL/$1"
	fi
	have=$(sha256sum "$DL/$1" | cut -d' ' -f1)
	[ "$have" = "$3" ] || { echo "error: $1 sha256 $have, expected $3" >&2; exit 1; }
	echo "ok  $1"
}
echo "$SOURCES" | while read -r n u s; do
	if [ -n "$n" ]; then fetch "$n" "$u" "$s"; fi
done

if [ -z "$TC" ]; then
	[ -f "$WORK/$TC_NAME" ] || curl -fsSL -o "$WORK/$TC_NAME" "$TC_URL"
	have=$(sha256sum "$WORK/$TC_NAME" | cut -d' ' -f1)
	echo "toolchain $TC_NAME sha256 $have"
	if [ -n "${TOOLCHAIN_SHA256:-}" ] && [ "$have" != "$TOOLCHAIN_SHA256" ]; then
		echo "error: toolchain sha256 differs from TOOLCHAIN_SHA256" >&2
		exit 1
	fi
	rm -rf "$WORK/toolchain" && mkdir -p "$WORK/toolchain"
	tar -xzf "$WORK/$TC_NAME" -C "$WORK/toolchain" --strip-components=1
	TC=$WORK/toolchain
	[ -x "$TC/relocate-sdk.sh" ] && (cd "$TC" && ./relocate-sdk.sh >/dev/null)
fi
HOST=mipsel-thingino-linux-uclibc
# the host's pkg-config, before the toolchain's wrapper comes first on PATH
HOST_PKG_CONFIG=$(command -v pkg-config) || { echo "error: no pkg-config" >&2; exit 1; }
export PATH=$TC/bin:$PATH
export CC=$HOST-gcc AR=$HOST-ar RANLIB=$HOST-ranlib
STRIP=$HOST-strip
command -v "$CC" >/dev/null || { echo "error: no $CC in $TC/bin" >&2; exit 1; }
J=$(nproc)
x() { tar -xf "$DL/$1" -C "$SRC"; }

echo "== libpcap"
x libpcap-1.10.7.tar.gz
(cd "$SRC/libpcap-1.10.7" &&
	./configure --host=$HOST --prefix="$ST" --disable-shared \
		--without-libnl --disable-usb --disable-dbus --disable-rdma \
		--disable-bluetooth --disable-netmap --disable-remote >/dev/null &&
	make -j"$J" >/dev/null && make install >/dev/null)

echo "== tcpdump"
x tcpdump-4.99.6.tar.gz
(cd "$SRC/tcpdump-4.99.6" &&
	CFLAGS="-Os -I$ST/include" LDFLAGS="-static -L$ST/lib" \
		./configure --host=$HOST --prefix="$ST" --without-crypto \
		--without-cap-ng --disable-smb >/dev/null &&
	make -j"$J" LIBS="-lpcap" >/dev/null &&
	$STRIP -o "$KIT/bin/tcpdump" tcpdump)

echo "== libnl (libnl-3 and libnl-genl-3 only)"
# libnl-route needs newer kernel headers (linux/ila.h) than the toolchain's
x libnl-3.12.0.tar.gz
(cd "$SRC/libnl-3.12.0" &&
	./configure --host=$HOST --prefix="$ST" --disable-shared \
		--disable-cli --disable-debug >/dev/null &&
	make -j"$J" lib/libnl-3.la lib/libnl-genl-3.la >/dev/null &&
	mkdir -p "$ST/lib/pkgconfig" "$ST/include/libnl3" &&
	cp lib/.libs/libnl-3.a lib/.libs/libnl-genl-3.a "$ST/lib/" &&
	cp -r include/netlink "$ST/include/libnl3/" &&
	cp libnl-3.0.pc libnl-genl-3.0.pc "$ST/lib/pkgconfig/")

echo "== iw"
x iw-6.17.tar.xz
# the toolchain's own pkg-config looks in its sysroot: use the host's
(cd "$SRC/iw-6.17" &&
	PKG_CONFIG_LIBDIR="$ST/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR='' \
		make -j"$J" CC="$CC" PKG_CONFIG="$HOST_PKG_CONFIG" LDFLAGS="-static" >/dev/null &&
	$STRIP -o "$KIT/bin/iw" iw)

echo "== iperf3"
x iperf-3.22.tar.gz
(cd "$SRC/iperf-3.22" &&
	./configure --host=$HOST --disable-shared --enable-static \
		--without-openssl --without-sctp CFLAGS=-Os >/dev/null &&
	# IPv6 flow labels: linux/in6.h of the 3.10 headers clashes with netinet/in.h
	sed -i 's|^#define HAVE_FLOWLABEL 1|/* #undef HAVE_FLOWLABEL */|' src/iperf_config.h &&
	make -j"$J" LDFLAGS="-all-static" >/dev/null &&
	$STRIP -o "$KIT/bin/iperf3" src/iperf3)

echo "== pack"
cp "$HERE/wifi-watch.sh" "$HERE/README.md" "$KIT/"
cp "$SRC/libpcap-1.10.7/LICENSE" "$KIT/LICENSES/libpcap.txt"
cp "$SRC/tcpdump-4.99.6/LICENSE" "$KIT/LICENSES/tcpdump.txt"
cp "$SRC/libnl-3.12.0/COPYING" "$KIT/LICENSES/libnl-LGPL-2.1.txt"
cp "$SRC/iw-6.17/COPYING" "$KIT/LICENSES/iw.txt"
cp "$SRC/iperf-3.22/LICENSE" "$KIT/LICENSES/iperf3.txt"
{
	echo "Built $(date -u +%F) by build.sh with $($CC --version | head -1)."
	echo
	echo "$SOURCES" | awk 'NF {printf "%s  %s\n  %s\n", $3, $1, $2}'
	echo
	echo "bin/iw links libnl (LGPL-2.1) statically. libnl-3.12.0.tar.gz is"
	echo "published beside this kit; build.sh rebuilds iw with a modified libnl."
} >"$KIT/SOURCES.txt"
chmod 755 "$KIT"/bin/* "$KIT/wifi-watch.sh"
(cd "$KIT" && find . -type f | sort | xargs sha256sum >"$WORK/SHA256SUMS" && mv "$WORK/SHA256SUMS" SHA256SUMS)
tar -czf "$WORK/wifi-kit-t31.tar.gz" -C "$OUT" wifi-kit-t31
file "$KIT"/bin/* | sed "s|$KIT/||"
sha256sum "$WORK/wifi-kit-t31.tar.gz"
