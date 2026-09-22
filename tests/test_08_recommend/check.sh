#!/usr/bin/env bash
# vasp-recommend-slurm, against the VASP documentation it claims to follow.
#
# TWO RULE SETS, and a recommendation is judged by the one it declares. VASP
# parallelizes GW/RPA by different rules than an SCF, so checking a GW layout
# against the electronic-minimization rules would fail it for rules that are
# not its own -- and, worse, PASSING it would mean the tool had quietly applied
# them.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/recommend"; rm -rf "$W"; mkdir -p "$W"
REC="$TK_DIR/vasp_recommend_slurm.py"
CONF="$W/cluster48.conf"

cat > "$CONF" <<'EOF'
WP_VASP_STD="/bin/true"
WP_VASP_MODULES=""
WP_MAIN_PARTITION="main"
WP_DEBUG_PARTITION="dev"
WP_MAIN_CPUS_PER_NODE="48"
WP_DEBUG_CPUS_PER_NODE="48"
WP_MAIN_MEM_PER_NODE_MB="384000"
WP_DEBUG_MEM_PER_NODE_MB="384000"
WP_MAIN_NUMA_CORES="24"
WP_MAX_CORES="240"
WP_DEBUG_MAX_CORES="96"
WP_MEM_UTIL="0.81"
WP_MEM_UTIL_MIN="0.80"
WP_MAIN_MEM_MARGIN="0.02"
WP_DEBUG_MEM_MARGIN="0.05"
EOF

# A dry-run OUTCAR is what stage 2 reads. Build them from the real cases so the
# dimensions (NKPTS, NBANDS) are a real system's, not invented.
_mkdry(){ # _mkdry NAME NKPTS NBANDS -> path
    local f="$W/dry_$1"
    cat > "$f" <<EOF
 vasp.6.5.1 test
 Found    $2 irreducible k-points:
   k-points           NKPTS =     $2   k-points in BZ     NKDIM =     $2   number of bands    NBANDS=      $3
   number of dos      NEDOS =    301   number of ions     NIONS =      4
   dimension x,y,z NGX =    40 NGY =   40 NGZ =   40
   dimension x,y,z NGXF=    80 NGYF=   80 NGZF=   80
   support grid    NGXF=    80 NGYF=   80 NGZF=   80
   ions per type =               2   2
  k-point   1 :  0.0000 0.0000 0.0000  plane waves:    8553
   total plane-waves  NPLWV = 64000
EOF
    echo "$f"
}

_run(){ # _run DRYFILE CALCTYPE CAP [extra...] -> dir
    local d="$W/run$RANDOM"; mkdir -p "$d/.wolfpack"
    cp "$1" "$d/.wolfpack/dryrun_OUTCAR"
    ( cd "$d" && WOLFPACK_CLUSTER_CONF="$CONF" "$WP_PY" "$REC" \
        --no-report --no-apply-incar --calc-type "$2" --max-cores "$3" \
        "${@:4}" >rec.txt 2>&1 )
    echo "$d"
}

# --- the rules, checked on the output, per regime ---------------------------
_judge(){ # _judge DIR LABEL
    local d="$1" label="$2" t="$1/rec.txt"
    grep -q "BEST CANDIDATE\|CANDIDATE " "$t" 2>/dev/null || { info "    $label: refused (no candidate) -- not a rule violation"; return; }
    local regime ranks nodes ntpn kpar ncore npar nkpts nb eff
    regime=$(grep -oP '^parallelization rules\s*:\s*\K.*' "$t" | head -1)
    ranks=$(grep -oP '^total MPI ranks\s*:\s*\K[0-9]+' "$t")
    nodes=$(grep -oP '^nodes\s*:\s*\K[0-9]+' "$t")
    ntpn=$(grep -oP '^ntasks-per-node\s*:\s*\K[0-9]+' "$t")
    kpar=$(grep -oP '^KPAR\s*:\s*\K[0-9]+' "$t")
    ncore=$(grep -oP '^NCORE\s*:\s*\K[0-9]+' "$t")
    npar=$(grep -oP 'NPAR \(derived\)\s*:\s*\K[0-9]+' "$t")
    [[ -z "$npar" ]] && npar=$(grep -oP 'ranks per k-point group\s*:\s*\K[0-9]+' "$t")
    nkpts=$(grep -oP 'irreducible k-points\s*:\s*\K[0-9]+' "$t")
    nb=$(grep -oP '^  NBANDS\s*:\s*\K[0-9]+' "$t")
    eff=$(grep -oP '^effective NBANDS\s*:\s*\K[0-9]+' "$t")
    [[ -z "$regime" ]] && { fail "$label: the recommendation does not say which rule set produced it"; return; }

    local bad=""
    # Shared, and shared because it is MPI rank placement rather than either
    # algorithm: "VASP assumes the ranks first fill up a node before the next
    # node is occupied."
    (( nodes * 48 == ranks )) || bad="$bad ranks($ranks)!=nodes($nodes)x48"
    (( nodes * ntpn == ranks )) || bad="$bad nodesXntpn!=ranks"
    (( nodes * 48 <= 240 ))    || bad="$bad over-cap"
    (( ranks % kpar == 0 ))    || bad="$bad ranks%KPAR"
    (( npar * ncore * kpar == ranks )) || bad="$bad NPARxNCORExKPAR!=ranks"
    (( nkpts == 1 )) && (( kpar != 1 )) && bad="$bad gamma-needs-KPAR1"

    if [[ "$regime" == relax* ]]; then
        # "Keep in mind that KPAR should factorize the number of k points."
        (( nkpts % kpar == 0 )) || bad="$bad NKPTS%KPAR"
        # "Choose NCORE as a factor of the cores per node."
        (( 48 % ncore == 0 || 24 % ncore == 0 )) || bad="$bad NCORE-not-a-factor"
        (( (ranks / kpar) % ncore == 0 )) || bad="$bad kgroup%NCORE"
        if [[ -n "$nb" && -n "$eff" ]]; then
            local want=$(( (nb + npar - 1) / npar * npar ))
            (( eff == want )) || bad="$bad NBANDS($eff!=$want)"
        fi
    else
        # GW: NCORE = 1, always. "you need to use the default for GW and RPA."
        (( ncore == 1 )) || bad="$bad GW-NCORE!=1"
    fi
    [[ -z "$bad" ]] && pass "$label [$regime]" || fail "$label [$regime] --$bad"
}

# 72 k-points factorises well; 63 does not over multiples of 48; 1 is gamma.
for spec in "k72 72 24" "k63 63 120" "gamma 1 200" "prime 41 96"; do
    read -r nm nk nb <<<"$spec"
    f=$(_mkdry "$nm" "$nk" "$nb")
    for ct in dft gw gw-low; do
        for cap in 48 96 240; do
            _judge "$(_run "$f" "$ct" "$cap")" "$nm NKPTS=$nk $ct cap=$cap"
        done
    done
done

# --- the adversarial half ---------------------------------------------------
f=$(_mkdry k72 72 24)
d="$W/norefuse"; mkdir -p "$d/.wolfpack"; cp "$f" "$d/.wolfpack/dryrun_OUTCAR"
must_refuse "a core cap below one node is refused, not rounded up" \
    "cap|node|cannot|refus" \
    env WOLFPACK_CLUSTER_CONF="$CONF" "$WP_PY" "$REC" --root "$d" --no-report \
        --no-apply-incar --max-cores 8 --min-cores 8
d2="$W/nodry"; mkdir -p "$d2"
must_refuse "a missing dry-run OUTCAR is refused by name" "dry-run|OUTCAR|not found|first" \
    env WOLFPACK_CLUSTER_CONF="$CONF" "$WP_PY" "$REC" --root "$d2" --no-report --no-apply-incar
exit $(( FAIL_N > 0 ))
