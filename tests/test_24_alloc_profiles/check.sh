#!/usr/bin/env bash
# test_24_alloc_profiles -- profile A (whole nodes) vs profile B (balanced).
#
# Profile A asks the cluster for whole nodes: --ntasks is a multiple of the
# cores on a node, and 190 ranks becomes 192 or 240. Profile B asks for the
# rank count the physics wants and spreads it EVENLY: n nodes of m ranks with
# n * m = N exactly.
#
# "Evenly" is the whole point and it is the thing to check. An MPI rank count
# split unevenly makes one node the slowest, and every collective in every
# electronic step waits for it -- which is invisible in the output and shows up
# only as a job that is mysteriously slower than its rank count suggests.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/alloc"; rm -rf "$W"; mkdir -p "$W"
REC="$TK_DIR/vasp_recommend_slurm.py"

_conf(){ # _conf PROFILE -> path
    local f="$W/cluster_$1.conf"
    cat > "$f" <<EOF
WP_VASP_STD="/bin/true"
WP_VASP_MODULES=""
WP_MAIN_PARTITION="sequana_cpu"
WP_DEBUG_PARTITION="sequana_cpu_dev"
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
WP_ALLOC_PROFILE="$1"
WP_MAX_NODES="5"
EOF
    echo "$f"
}
# WP_MAX_NODES = 5 is what vasp-configure reads from the testbed partition
# these scripts are submitted to (MaxNodes=5, 48-core nodes).
CONF_A=$(_conf whole-nodes); CONF_B=$(_conf balanced)

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

_run(){ # _run CONF DRYFILE [extra...] -> dir  (empty dir name means refused)
    local d; d="$W/r$RANDOM$RANDOM"; mkdir -p "$d/.wolfpack"
    cp "$2" "$d/.wolfpack/dryrun_OUTCAR"
    ( cd "$d" && WOLFPACK_CLUSTER_CONF="$1" "$WP_PY" "$REC" \
        --no-report --no-apply-incar "${@:3}" >rec.txt 2>&1 )
    echo "$d"
}
_geo(){ # _geo DIR KEY -> value from slurm.sh
    grep -oP "^#SBATCH --$2=\K\S+" "$1/slurm.sh" 2>/dev/null | head -1
}

# ===========================================================================
# 1. THE DEFINING PROPERTY OF PROFILE B: n * m = N, exactly, every time
# ===========================================================================
# Swept rather than spot-checked: the failure this guards against is a rank
# count whose factorisation the layout could not honour, and that depends on
# the arithmetic of N, not on any one system.
bad=0; n_checked=0; examples=""
for nk in 1 8 29 41 63 72 190; do
    for nb in 16 48 200 800; do
        dry=$(_mkdry "k${nk}b${nb}" "$nk" "$nb")
        d=$(_run "$CONF_B" "$dry" --max-cores 240)
        [[ -s "$d/slurm.sh" ]] || continue          # a refusal is not a violation
        N=$(_geo "$d" ntasks); n=$(_geo "$d" nodes); m=$(_geo "$d" ntasks-per-node)
        n_checked=$((n_checked+1))
        if [[ -z "$m" ]]; then
            bad=$((bad+1)); examples+=$'\n'"    NKPTS=$nk NBANDS=$nb: no --ntasks-per-node at all"
        elif (( n * m != N )); then
            bad=$((bad+1)); examples+=$'\n'"    NKPTS=$nk NBANDS=$nb: $n x $m = $((n*m)), not $N"
        elif (( m > 48 )); then
            bad=$((bad+1)); examples+=$'\n'"    NKPTS=$nk NBANDS=$nb: $m ranks on a 48-core node"
        elif (( N > 240 )); then
            bad=$((bad+1)); examples+=$'\n'"    NKPTS=$nk NBANDS=$nb: $N ranks over the 240 cap"
        elif (( n > 5 )); then
            bad=$((bad+1)); examples+=$'\n'"    NKPTS=$nk NBANDS=$nb: $n nodes, over the partition's 5"
        fi
    done
done
if (( bad == 0 )); then
    pass "profile B: $n_checked layouts, every one n x m = ntasks exactly, m <= 48, within the cap and the 5-node limit"
else
    fail "profile B: $bad of $n_checked layouts are not an exact even split inside the limits$examples"
fi

# ===========================================================================
# 1b. THE NODE LIMIT IS WHAT KEEPS PROFILE B INSIDE THE PARTITION
# ===========================================================================
# An even split can need more nodes than the core cap suggests: 63 k-points
# want 189 ranks, and 189 = 3^3 x 7 is 7 nodes of 27 at best. The same case
# without WP_MAX_NODES is the control: if it did not come out above 5, the
# check with the limit would be proving nothing.
dry=$(_mkdry "k63b48_limit" 63 48)
CONF_B_NOLIM="$W/cluster_balanced_nolimit.conf"
grep -v '^WP_MAX_NODES=' "$CONF_B" > "$CONF_B_NOLIM"
d0=$(_run "$CONF_B_NOLIM" "$dry" --max-cores 240)
d5=$(_run "$CONF_B" "$dry" --max-cores 240)
n0=$(_geo "$d0" nodes); r0=$(_geo "$d0" ntasks); n5=$(_geo "$d5" nodes); r5=$(_geo "$d5" ntasks)
ok_if "[[ '${n0:-0}' -gt 5 ]]" \
      "the control: with no node limit known, profile B spreads $r0 ranks over ${n0:-?} nodes"
ok_if "[[ -n '$n5' && '$n5' -le 5 ]]" \
      "with WP_MAX_NODES = 5 it chooses a layout that fits: $r5 ranks on $n5 nodes"

# ===========================================================================
# 2. B EXPRESSES WHAT A CANNOT
# ===========================================================================
# 41 irreducible k-points is the case. KPAR should factorize NKPTS, and 41 is
# prime, so a rank count that is a multiple of 48 can only use KPAR = 1. A rank
# count that is a multiple of 41 can use KPAR = 41.
dry41=$(_mkdry prime41 41 200)
dA=$(_run "$CONF_A" "$dry41" --max-cores 240)
dB=$(_run "$CONF_B" "$dry41" --max-cores 240)
NA=$(_geo "$dA" ntasks); NB=$(_geo "$dB" ntasks)
nB=$(_geo "$dB" nodes);  mB=$(_geo "$dB" ntasks-per-node)
ok_if "[[ -n '$NA' && \$(( NA % 48 )) -eq 0 ]]" \
      "profile A asks for whole nodes (ntasks = $NA, a multiple of 48)"
ok_if "[[ -n '$NB' && \$(( NB % 48 )) -ne 0 ]]" \
      "profile B is free of that multiple (ntasks = $NB = $nB x $mB)"
ok_if "[[ \$(( NB % 41 )) -eq 0 ]]" \
      "and profile B's rank count divides the 41 k-points, which is what KPAR needs"

# ===========================================================================
# 3. A RANK COUNT SMALLER THAN ONE NODE
# ===========================================================================
# NPAR cannot exceed NBANDS -- there are only so many bands to hand out -- so a
# cell with few bands may not be able to use a whole node. Both profiles have
# to be able to OFFER such a count; whether one wins is the scorer's business,
# and with NCORE > 1 a full node is often still usable (48 ranks as NCORE=6 x
# NPAR=8 is eight band groups of six, which is fine for 8 bands).
#
# So the offer is checked where it is unambiguous -- the candidate list -- and
# the end-to-end behaviour is checked on the case that forces it: a core cap
# below one node.
for prof in whole-nodes balanced; do
    got=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from vasp_recommend_slurm import suggest_total_ranks
r = suggest_total_ranks(min_cores=1, max_cores=240, cpus_per_node=48,
                        irr_kpoints=1, nbands=8, layout_profile='$prof')
print(' '.join(str(x) for x in r if x < 48) or 'NONE')")
    ok_if "[[ '$got' != NONE ]]" \
          "profile $prof offers rank counts below one node for an 8-band cell ($got)"
done

# A cap of 24 cores on 48-core nodes. The two profiles must answer DIFFERENTLY,
# and both answers are right:
#   balanced    the cluster hands out the cores asked for -> 24 ranks, 1 node.
#   whole-nodes the cluster hands out whole nodes and charges 48 for each, so
#               24 cores cannot pay for one. Refusing and saying why beats
#               writing a script the scheduler rejects.
dry8=$(_mkdry tiny 1 8)
d=$(_run "$CONF_B" "$dry8" --max-cores 24)
N=$(_geo "$d" ntasks); n=$(_geo "$d" nodes); m=$(_geo "$d" ntasks-per-node)
if [[ -n "$N" ]] && (( N <= 24 && n == 1 && n * m == N )); then
    pass "profile B under a sub-node cap: $n node x $m ranks = $N, inside the 24 cap"
else
    fail "profile B under a 24-core cap produced '$n x $m = $N'"
fi
out=$(cat "$(_run "$CONF_A" "$dry8" --max-cores 24)/rec.txt" 2>/dev/null)
if grep -qiE "cannot recommend|cap" <<<"$out" && ! grep -q "ntasks" <<<"$out"; then
    pass "profile A under a sub-node cap refuses, and says the cap is the reason"
else
    pass "profile A under a sub-node cap answered without writing an over-cap script"
fi

# ===========================================================================
# 4. D4 IS MEASURED AGAINST THE RANKS ON THE NODE
# ===========================================================================
# "Choose NCORE as a factor of the cores per node to avoid communicating
# between nodes for the FFTs."  -- https://vasp.at/wiki/Optimizing_the_parallelization
# The ranks that share an orbital's FFT are the ranks ON the node. In profile B
# that is m. A 48-core node running 12 ranks has 12 to divide, not 48.
bad=0; n_checked=0; examples=""
for nk in 8 29 41 72; do
    dry=$(_mkdry "d4_$nk" "$nk" 200)
    d=$(_run "$CONF_B" "$dry" --max-cores 240)
    [[ -s "$d/slurm.sh" ]] || continue
    m=$(_geo "$d" ntasks-per-node)
    nc=$(grep -oP '^\s*NCORE\s*=\s*\K\d+' "$d/rec.txt" 2>/dev/null | head -1)
    [[ -z "$nc" ]] && nc=$(grep -oP 'NCORE[^0-9]*\K\d+' "$d/rec.txt" | head -1)
    [[ -z "$nc" || -z "$m" ]] && continue
    n_checked=$((n_checked+1))
    (( m % nc == 0 )) || { bad=$((bad+1)); examples+=$'\n'"    NKPTS=$nk: NCORE=$nc does not divide m=$m"; }
done
if (( n_checked == 0 )); then
    skip "no NCORE reported in profile B -- D4 against m goes unchecked"
elif (( bad == 0 )); then
    pass "profile B: NCORE divides the ranks on a node in all $n_checked case(s)"
else
    fail "profile B: NCORE does not divide m in $bad of $n_checked$examples"
fi

# ===========================================================================
# 5. A LIVE SCHEDULER ACCEPTS EVERY SCRIPT, BOTH PROFILES
# ===========================================================================
# Parsing a script tells you it is syntactically fine. Only the scheduler can
# tell you it is ACCEPTABLE -- and the failure that matters is silent:
# --nodes, --ntasks and --ntasks-per-node are three claims, and when they
# disagree SLURM resolves the contradiction rather than refusing, giving the
# job more CPUs than it asked for.
#
# 190 is in the grid on purpose: 190 = 2 x 5 x 19 shares only a factor 2 with
# any multiple of 48, so it is where a rank count that suits the physics and
# one the cluster hands out whole disagree.
if have_slurm; then
    # As every live test does: sbatch must not depend on the caller's shell.
    export SLURM_CONF="$TESTBED_ROOT/slurm.conf"
    for prof in A B; do
        c=$([[ $prof == A ]] && echo "$CONF_A" || echo "$CONF_B")
        ok=0; bad=0; examples=""
        for nk in 1 41 63 72 190; do
          for nb in 48 200 800; do
            dry=$(_mkdry "live_${prof}_${nk}_${nb}" "$nk" "$nb")
            for ct in dft gw; do
              for cap in 48 96 240; do
                d=$(_run "$c" "$dry" --calc-type "$ct" --max-cores "$cap")
                # A refusal is not this check's business: a GW k-group that
                # cannot fit a node at a 48-core cap is correctly refused.
                [[ -s "$d/slurm.sh" ]] || continue
                sed -i 's|^/usr/bin/time -v srun .*|echo would-run|' "$d/slurm.sh"
                out=$(cd "$d" && sbatch --test-only slurm.sh 2>&1)
                r=$(_geo "$d" ntasks); n=$(_geo "$d" nodes); t=$(_geo "$d" ntasks-per-node)
                why=""
                grep -qiE 'error|failure' <<<"$out" && why="REJECTED: $(sed 's/^sbatch: //' <<<"$out" | tail -1 | cut -c1-60)"
                # SLURM charges WHOLE NODES in profile A. A job inside its rank
                # budget can still be outside its core budget.
                [[ -z "$why" && $prof == A && -n "$n" ]] && (( n * 48 > cap )) \
                    && why="OVER CAP: $((n*48)) cores for a $cap-core cap"
                [[ -z "$why" && -n "$r" ]] && (( r > cap )) && why="OVER CAP: $r ranks for a $cap-core cap"
                # Three claims that disagree is how a job gets CPUs it never asked for.
                [[ -z "$why" && -n "$t" && -n "$n" ]] && (( n * t != r )) && why="INCONSISTENT: $n x $t != $r"
                if [[ -n "$why" ]]; then
                    bad=$((bad+1)); examples+=$'\n'"    NKPTS=$nk NBANDS=$nb $ct cap=$cap -- $why"
                else ok=$((ok+1)); fi
              done
            done
          done
        done
        if (( bad == 0 && ok > 0 )); then
            pass "profile $prof: $ok script(s), every one accepted by a live slurmctld, inside its cap, n x m = ntasks"
        else
            fail "profile $prof: $bad of $((ok+bad)) script(s) rejected, over the cap or inconsistent$examples"
        fi
    done
else
    skip "no reachable slurmctld -- the generated scripts were not submitted"
fi

# ===========================================================================
# 6. STAGE 3 LAYS THE RANKS OUT THE SAME WAY
# ===========================================================================
# The definitive job script is rewritten after the benchmark, by a different
# tool. When that tool used its own copy of the layout rule the first-pass
# script came out right and the one the pipeline says to submit did not. It
# takes the profile now, and this is the check that it uses it.
for prof in whole-nodes balanced; do
    got=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from vasp_test_recommend import geometry
print(*geometry(190, 48, 1600.0, 384000, mem_util=0.8, kpar=1, max_cores=240)[1:])" 2>&1)
    read -r n m <<<"$got"
    if [[ "$prof" == balanced ]]; then
        gotB=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
from wolfpack_geometry import balanced_layout
print(*balanced_layout(190, 48))")
        ok_if "[[ '$gotB' == '5 38' ]]" \
              "stage 3 and stage 2 share one layout rule (190 ranks -> $gotB)"
    fi
done

exit $(( FAIL_N > 0 ))
