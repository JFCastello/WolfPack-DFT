#!/usr/bin/env bash
###############################################################################
# wolfpack_hw.sh -- what this machine's interconnect is, read from sysfs.
#
#   wolfpack_hw.sh interconnect     -> KIND|DETAIL|SPEED_MBS
#
#   KIND   infiniband | omnipath | roce | slingshot | ethernet | unknown
#   DETAIL the device and its rate, as the kernel reports them
#   SPEED_MBS  for ethernet, the fastest interface's speed in Mb/s (else empty)
#
# Used by vasp-configure (on the login node, into the cluster profile) and by
# vasp-test (inside its benchmark job, on a compute node). The VASP wiki's
# LPLANE page recommends different settings for "a LINUX cluster linked by
# Infiniband" and "a LINUX cluster linked by 1 Gbit Ethernet"
# (vasp.at/wiki/LPLANE); this is how the toolkit tells them apart.
#
# Read-only, and nothing beyond reading files: it runs on compute nodes too.
# WP_SYSFS points it at another /sys (the tests use a fake one).
#
# HOW
#   /sys/class/infiniband/<dev>   an RDMA device. hfi1* is Omni-Path; a port
#                                 whose link_layer is Ethernet is RoCE; the
#                                 rest is InfiniBand. The first ACTIVE port wins.
#   /sys/class/cxi/<dev>          HPE Slingshot (the CXI NIC).
#   /sys/class/net/<if>/speed     otherwise: Ethernet, and its speed (Mb/s)
#                                 over the interfaces that report one.
###############################################################################

wp_interconnect(){
    local sys="${WP_SYSFS:-/sys}" d name ll rate st kind="" detail="" first="" f sp best=""
    if [[ -d $sys/class/infiniband ]]; then
        for d in "$sys"/class/infiniband/*; do
            [[ -e $d ]] || continue
            name=${d##*/}
            ll=$(cat "$d/ports/1/link_layer" 2>/dev/null)
            rate=$(cat "$d/ports/1/rate" 2>/dev/null)
            st=$(cat "$d/ports/1/state" 2>/dev/null)
            case $name in
                hfi1*) f=omnipath ;;
                *) if [[ ${ll,,} == ethernet ]]; then f=roce; else f=infiniband; fi ;;
            esac
            [[ -z $first ]] && first="$f|${name}${rate:+, $rate}${st:+, ${st#*: }}"
            if [[ $st == *ACTIVE* ]]; then
                kind=$f; detail="${name}${rate:+, $rate}, ${st#*: }"
                break
            fi
        done
        if [[ -z $kind && -n $first ]]; then kind=${first%%|*}; detail=${first#*|}; fi
    fi
    if [[ -z $kind ]]; then
        for d in "$sys"/class/cxi/*; do
            [[ -e $d ]] || continue
            kind=slingshot; detail=${d##*/}; break
        done
    fi
    if [[ -n $kind ]]; then
        printf '%s|%s|\n' "$kind" "$detail"
        return 0
    fi
    # Ethernet: the fastest interface that reports a speed (a virtual one
    # reports -1 or nothing).
    for d in "$sys"/class/net/*; do
        [[ -e $d ]] || continue
        name=${d##*/}; [[ $name == lo ]] && continue
        sp=$(cat "$d/speed" 2>/dev/null)
        [[ $sp =~ ^[0-9]+$ ]] || continue
        if [[ -z $best ]] || (( sp > ${best%%|*} )); then best="$sp|$name"; fi
    done
    if [[ -n $best ]]; then
        printf 'ethernet|%s %s Mb/s|%s\n' "${best#*|}" "${best%%|*}" "${best%%|*}"
    elif compgen -G "$sys/class/net/*" >/dev/null; then
        printf 'ethernet|no interface reports its speed|\n'
    else
        printf 'unknown||\n'
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        interconnect) wp_interconnect ;;
        *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
fi
