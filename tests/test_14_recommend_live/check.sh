#!/usr/bin/env bash
# Every SLURM script the toolkit writes, handed to a real slurmctld.
#
# Parsing a script tells you it is syntactically fine. Only the scheduler can
# tell you it is ACCEPTABLE -- and the failures that matter are the ones where
# --nodes, --ntasks and --ntasks-per-node are three claims that disagree, which
# SLURM resolves by quietly giving the job more CPUs than it asked for.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
have_slurm || { skip "no slurmctld -- run tests/slurm_testbed.sh start"; exit 0; }
export SLURM_CONF="$TESTBED_ROOT/slurm.conf"
W="$WORK/recommend_live"; rm -rf "$W"; mkdir -p "$W"
REC="$TK_DIR/vasp_recommend_slurm.py"

# A cluster of 48-core nodes -- the shape the config-only partition provides,
# so a multi-node layout can be submitted and judged.
CONF="$W/c48.conf"
cat > "$CONF" <<'EOF'
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
EOF

_dry(){ # _dry NKPTS NBANDS -> file
    local f="$W/dry_$1_$2"
    cat > "$f" <<EOF
 vasp.6.5.1
 Found    $1 irreducible k-points:
   k-points           NKPTS =     $1   k-points in BZ     NKDIM =     $1   number of bands    NBANDS=      $2
   dimension x,y,z NGX =    60 NGY =   60 NGZ =   60
   dimension x,y,z NGXF=   120 NGYF=  120 NGZF=  120
   ions per type =               4   4
  k-point   1 :  0.0000 0.0000 0.0000  plane waves:   24000
   total plane-waves  NPLWV = 216000
EOF
    echo "$f"
}

ok=0; bad=0
for nk in 1 41 63 72 190; do
  for nb in 48 200 800; do
    f=$(_dry "$nk" "$nb")
    for ct in dft gw; do
      for cap in 48 96 240; do
        d="$W/$(printf '%s_%s_%s_%s' "$nk" "$nb" "$ct" "$cap")"
        mkdir -p "$d/.wolfpack"; cp "$f" "$d/.wolfpack/dryrun_OUTCAR"
        ( cd "$d" && WOLFPACK_CLUSTER_CONF="$CONF" "$WP_PY" "$REC" --no-report \
            --no-apply-incar --calc-type "$ct" --max-cores "$cap" >rec.log 2>&1 )
        [[ -s "$d/slurm.sh" ]] || continue     # a refusal is not this check's business
        sed -i 's|^/usr/bin/time -v srun .*|echo would-run|' "$d/slurm.sh"
        out=$( cd "$d" && sbatch --test-only slurm.sh 2>&1 )
        r=$(grep -oP '(?<=--ntasks=)\d+' "$d/slurm.sh" | head -1)
        n=$(grep -oP '(?<=--nodes=)\d+' "$d/slurm.sh" | head -1)
        t=$(grep -oP '(?<=--ntasks-per-node=)\d+' "$d/slurm.sh" | head -1)
        why=""
        grep -qiE 'error|failure' <<<"$out" && why="REJECTED: $(sed 's/^sbatch: //' <<<"$out" | tail -1 | cut -c1-60)"
        # SLURM charges WHOLE NODES. A job inside its rank budget can still be
        # outside its core budget.
        [[ -z "$why" && -n "$n" ]] && (( n * 48 > cap )) && why="OVER CAP: $((n*48)) cores for a $cap-core cap"
        # Three claims that disagree is how a job gets CPUs it never asked for.
        [[ -z "$why" && -n "$t" ]] && (( n * t != r )) && why="INCONSISTENT: $n x $t != $r"
        if [[ -n "$why" ]]; then
            bad=$((bad+1)); info "    NKPTS=$nk NBANDS=$nb $ct cap=$cap -- $why"
        else ok=$((ok+1)); fi
      done
    done
  done
done
ok_if "[[ $bad -eq 0 ]]" "$ok generated script(s), every one accepted by a live slurmctld and inside its cap"
exit $(( FAIL_N > 0 ))
