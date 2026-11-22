#!/bin/sh
#
# wifi-watch.sh - log an ATBM603x camera's Wi-Fi link once a minute, from RAM,
# to catch the moment of the MCS1 wedge and what changed around it.
# Issue: https://github.com/themactep/thingino-firmware/issues/1915
#
# One line a sample (key=value, so it greps and plots), and an EVENT line
# whenever the rate drops to or leaves 13 Mbps, the AP's protection flags in
# its beacon change, or the connection changes. Nothing is written to flash;
# the log is in /tmp unless -o says otherwise.
#
# Usage: wifi-watch.sh [-i wlan0] [-t 60] [-o /tmp/wifi-watch.log] [-n 3]
#                      [-a none|max650] [-s] [-k DIR]
#   -i IFACE   wireless interface                       (default: wlan0)
#   -t SEC     seconds between samples                  (default: 60)
#   -o FILE    log file                                 (default: /tmp/wifi-watch.log)
#   -n N       samples at 13 Mbps in a row that count as a wedge (default: 3)
#   -a ACTION  on a wedge: none, or max650 = re-apply the full TX ceiling
#              (iwpriv fwcmd lmac_max_rate,650) once and log what follows
#              (default: none)
#   -s         one active scan at start, to list the other networks on the
#              channel and next to it (a short gap in the camera's traffic)
#   -k DIR     the kit folder: iw in DIR/bin or DIR (default: the script's own
#              folder); without iw the station counters and beacon flags are
#              left out
#
# Run it in the background so it outlives the login:
#   (trap "" HUP; sh wifi-watch.sh -s > /dev/null 2>&1 < /dev/null &)
# Stop it with: kill $(cat /tmp/wifi-watch.pid)
#
# Privacy: no SSID and no MAC address is written. The AP is "ap"; other
# networks are counted, with their channel, signal and flags only.
#
set -u

IFACE=wlan0
INT=60
OUT=/tmp/wifi-watch.log
WEDGE_N=3
ACTION=none
SCAN=0
KIT=$(cd "$(dirname "$0")" && pwd)

while getopts "i:t:o:n:a:sk:h" opt; do
	case "$opt" in
		i) IFACE=$OPTARG ;;
		t) INT=$OPTARG ;;
		o) OUT=$OPTARG ;;
		n) WEDGE_N=$OPTARG ;;
		a) ACTION=$OPTARG ;;
		s) SCAN=1 ;;
		k) KIT=$OPTARG ;;
		*)
			sed -n '2,/^set -u/p' "$0" | sed -n 's/^# \{0,1\}//p'
			exit 1
			;;
	esac
done
case "$INT$WEDGE_N" in *[!0-9]*)
	echo "error: -t and -n are numbers" >&2
	exit 1
	;;
esac
case "$ACTION" in none | max650) ;; *)
	echo "error: -a none|max650" >&2
	exit 1
	;;
esac

IW=
for _k in "$KIT/bin/iw" "$KIT/iw"; do
	[ -x "$_k" ] && IW=$_k && break
done
command -v iw >/dev/null 2>&1 && [ -z "$IW" ] && IW=$(command -v iw)
PIDF=/tmp/wifi-watch.pid
echo $$ >"$PIDF"
trap 'rm -f "$PIDF"; echo "$(date -u +%FT%TZ) EVENT stop" >>"$OUT"; exit 0' INT TERM

log() { echo "$(date -u +%FT%TZ) $*" >>"$OUT"; }

# keep the log under 2 MB: keep the last half
trim() {
	[ "$(wc -c <"$OUT" 2>/dev/null || echo 0)" -gt 2097152 ] || return 0
	tail -n 4000 "$OUT" >"$OUT.tmp" && mv "$OUT.tmp" "$OUT"
}

ip_rate() { # the firmware's TX rate byte (get_maxrate; 650 prints as 138)
	iwpriv "$IFACE" common get_maxrate 2>/dev/null |
		sed -n 's/.*send_rate:\([0-9][0-9]*\)\/10.*/\1/p' | head -n 1
}
txrx() { # "rssi tp tsp"
	iwpriv "$IFACE" common get_txrx_info 2>/dev/null |
		sed -n 's/.*rssi\[\([-0-9]*\)\].*tp\[\([0-9]*\)\].*tsp\[\([0-9]*\)\].*/\1 \2 \3/p' | head -n 1
}
one() { # iwpriv common $1, the first number after "$2"
	iwpriv "$IFACE" common "$1" 2>/dev/null | sed -n "s/.*$2[^-0-9]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -n 1
}
sta() { # mac80211's view: "retries failed txbitrate signal"
	[ -n "$IW" ] || return 0
	"$IW" dev "$IFACE" station dump 2>/dev/null | awk '
		/tx retries:/ {r=$3} /tx failed:/ {f=$3}
		/tx bitrate:/ {b=$3} /^[ \t]*signal:/ {s=$2}
		END {print r+0, f+0, (b==""?"?":b), (s==""?"?":s)}'
}
beacon() { # the AP's beacon flags from the cached scan: erp,htprot,nongf,obss
	[ -n "$IW" ] || return 0
	"$IW" dev "$IFACE" scan dump 2>/dev/null | awk '
		/^BSS/ {cur = ($0 ~ /associated/)}
		cur && /ERP:/ {sub(/.*ERP: */, ""); gsub(/ /, "_"); e=$0}
		cur && /HT protection:/ {p=$NF}
		cur && /non-GF present:/ && !/OBSS/ {g=$NF}
		cur && /OBSS non-GF present:/ {o=$NF}
		END {printf "erp=%s htprot=%s nongf=%s obss_nongf=%s\n", (e==""?"-":e), (p==""?"-":p), (g==""?"-":g), (o==""?"-":o)}'
}

scan_once() {
	[ -n "$IW" ] || {
		log "EVENT scan skipped: no iw"
		return 0
	}
	_ch=$("$IW" dev "$IFACE" link 2>/dev/null | sed -n 's/.*freq: *\([0-9]*\).*/\1/p')
	"$IW" dev "$IFACE" scan 2>/dev/null | awk -v myf="${_ch:-0}" '
		/^BSS/ {n++; f[n]=0; s[n]=""; ht[n]=""; erp[n]=""; me[n]=($0 ~ /associated/)}
		/freq:/ {f[n]=int($2)}
		/signal:/ {s[n]=int($2)}
		/HT protection:/ {ht[n]=$NF}
		/ERP:/ {e=$0; sub(/.*ERP: */, "", e); gsub(/ /, "_", e); erp[n]=e}
		END {
			for (i = 1; i <= n; i++) {
				d = f[i] - myf; if (d < 0) d = -d
				if (me[i]) continue
				if (d <= 25) { near++; printf "SCAN other freq=%d dist_mhz=%d signal=%s htprot=%s erp=%s\n", f[i], d, s[i], (ht[i]==""?"-":ht[i]), (erp[i]==""?"-":erp[i]) }
				else far++
			}
			printf "SCAN summary own_freq=%d overlapping=%d elsewhere=%d\n", myf, near+0, far+0
		}' | while read -r l; do log "$l"; done
}

log "EVENT start iface=$IFACE interval=${INT}s wedge_n=$WEDGE_N action=$ACTION iw=${IW:+yes} fw=$(cat /sys/module/atbm6031/parameters/fw_ver 2>/dev/null) driver=$(cat /sys/module/atbm6031/parameters/driver_ver 2>/dev/null) uptime=$(cut -d. -f1 /proc/uptime)"
[ "$SCAN" = 1 ] && scan_once

low=0
wedged=0
acted=0
last_beacon=
last_conn=
last_tp=
last_tsp=
while :; do
	r=$(ip_rate)
	# shellcheck disable=SC2046 # txrx prints three fields, split on purpose
	set -- $(txrx)
	rssi=${1:-?}
	tp=${2:-}
	tsp=${3:-}
	ok='?'
	if [ -n "$tp" ] && [ -n "$last_tp" ] && [ "$tp" -gt "$last_tp" ]; then
		ok=$((((tsp - last_tsp) * 1000) / (tp - last_tp)))
		ok="$((ok / 10)).$((ok % 10))"
	fi
	dtp=$([ -n "$tp" ] && [ -n "$last_tp" ] && echo $((tp - last_tp)) || echo ?)
	last_tp=$tp
	last_tsp=$tsp
	# shellcheck disable=SC2046 # sta prints four fields, split on purpose
	set -- $(sta)
	retr=${1:-?}
	fail=${2:-?}
	brate=${3:-?}
	sig=${4:-?}
	b=$(beacon)
	noise=$(one get_noise_level noise_level_dBm)
	idle=$(one get_channel_idle current_idle)
	conn=$(one get_conn_state wifi_status)
	log "rate=${r:-?} rssi=$rssi tx_frames=$dtp tx_ok_pct=$ok mac_tx_retries=$retr mac_tx_failed=$fail mac_tx_bitrate=$brate signal=$sig noise=${noise:-?} idle=${idle:-?} conn=${conn:-?} ${b:-}"
	if [ -n "$b" ] && [ "$b" != "$last_beacon" ]; then
		[ -n "$last_beacon" ] && log "EVENT beacon flags changed: $last_beacon -> $b"
		last_beacon=$b
	fi
	if [ -n "$last_conn" ] && [ "${conn:-?}" != "$last_conn" ]; then
		log "EVENT connection state $last_conn -> ${conn:-?}"
	fi
	last_conn=${conn:-?}
	if [ "$r" = 130 ]; then
		low=$((low + 1))
		if [ "$low" -ge "$WEDGE_N" ] && [ "$wedged" = 0 ]; then
			wedged=1
			log "EVENT wedge: rate 13 Mbps for $low samples"
			dmesg 2>/dev/null | tail -n 15 | sed 's/^/DMESG /' | while read -r l; do log "$l"; done
			if [ "$ACTION" = max650 ] && [ "$acted" = 0 ]; then
				acted=1
				iwpriv "$IFACE" fwcmd "lmac_max_rate,650" >/dev/null 2>&1
				log "EVENT action: fwcmd lmac_max_rate,650 (rc $?)"
				_n=10
				while [ "$_n" -gt 0 ]; do
					log "after-action rate=$(ip_rate)"
					sleep 1
					_n=$((_n - 1))
				done
			fi
		fi
	else
		if [ "$wedged" = 1 ]; then
			log "EVENT wedge ended: rate ${r:-?} after $low samples at 13 Mbps"
		fi
		low=0
		wedged=0
	fi
	trim
	sleep "$INT"
done
