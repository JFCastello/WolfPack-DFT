#!/usr/bin/env bash
# test_33_chain_live_e2e -- a real chunked cell relaxation, on a real
# scheduler, with a real VASP: the chain launches, each chunk measures its
# memory and rewrites the next one's, and the relaxation converges.
#
# The fake harness (test_29..32) proves the decisions. This proves the
# plumbing they depend on: that a real OUTCAR, a real srun and a real sacct
# say what the decisions assume, and that a chunk resubmitting its successor
# from inside a job works on a real scheduler.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/chainlive"; rm -rf "$W"; mkdir -p "$W"

have_vasp   || { skip "no VASP -- the live chain goes untested"; exit 0; }
have_potcar Si || { skip "no Si POTCAR -- the live chain goes untested"; exit 0; }
have_slurm  || { skip "no reachable slurmctld -- the live chain goes untested"; exit 0; }
export SLURM_CONF="$TESTBED_ROOT/slurm.conf"

d="$W/si"; mkdir -p "$d/.wolfpack"
# The profile this chain runs under: the testbed's real node, 8 cores, 7 GB.
cat > "$W/cluster.conf" <<EOF
WP_VASP_STD="$WP_VASP"
WP_VASP_MODULES=""
WP_MAIN_PARTITION="local"
WP_DEBUG_PARTITION="local"
WP_MAIN_CPUS_PER_NODE="8"
WP_DEBUG_CPUS_PER_NODE="8"
WP_MAIN_MEM_PER_NODE_MB="7000"
WP_DEBUG_MEM_PER_NODE_MB="7000"
WP_MAX_CORES="8"
WP_MAIN_MEM_MARGIN="0.02"
WP_CHUNK_MARGIN_MIN="5"
WP_ALLOC_PROFILE="whole-nodes"
EOF

# Si, one atom displaced and the cell strained 3 %, so there is a relaxation
# to do -- the ideal diamond cell would converge in one step and prove nothing.
# ISYM = 0: as the atom returns, the symmetry would rise and change NKPTS
# between chunks, which the chain rightly refuses to restart across.
awk 'NR>=3 && NR<=5 { printf "  %.10f  %.10f  %.10f\n", $1*1.03, $2*1.03, $3*1.03; next }
     NR==10 { printf "   0.2700000000  0.2600000000  0.2500000000\n"; next } { print }' \
    "$CASES/Si/POSCAR" > "$d/POSCAR"
printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$d/KPOINTS"
cat "$WP_POTCAR_DIR/Si/POTCAR" > "$d/POTCAR"
cat > "$d/INCAR" <<'EOF'
SYSTEM = Si live chain
PREC   = Accurate
ENCUT  = 400
EDIFF  = 1E-6
NELM   = 60
IBRION = 2
ISIF   = 3
NSW    = 30
EDIFFG = -0.01
ISYM   = 0
ISMEAR = 0
SIGMA  = 0.05
LREAL  = .FALSE.
EOF
cat > "$d/slurm_vasptest.sh" <<EOF
#!/bin/bash
#SBATCH --job-name=vasp
#SBATCH --partition=local
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=4
#SBATCH --mem-per-cpu=1000
#SBATCH --time=00:30:00
/usr/bin/time -v srun --cpu-bind=cores $WP_VASP
EOF
printf 'stage="test"\ntest_avg_loop="0.5"\ntest_ranks="4"\ntest_cpu_eff="90"\ntest_startup_s="10"\ntest_scf_per_ionic="10"\n' \
    > "$d/.wolfpack/state.env"

# 8-min chunks: 3 min of VASP after the 5-min margin -- short enough that the
# relaxation needs more than one chunk.
out=$(cd "$d" && WOLFPACK_CLUSTER_CONF="$W/cluster.conf" bash "$TK_DIR/vasp_chain.sh" \
        --mode relax --walltime 8 2>&1); rc=$?
echo "$out" > "$W/launch.log"
ok_if "(( rc == 0 ))" "the chain launches on the live scheduler (rc=$rc)"
(( rc == 0 )) || exit 1

# Wait for it to end, one way or the other.
deadline=$(( SECONDS + 900 ))
while (( SECONDS < deadline )); do
    [[ -f "$d/wolfpack_chain/FINISHED" || -f "$d/wolfpack_chain/STOPPED" ]] && break
    sleep 10
done
# Kept next to the README as evidence. NB: lib.sh no longer defines $LOGS --
# reading it under `set -u` killed this test silently on its first run.
mkdir -p "$(dirname "${BASH_SOURCE[0]}")/logs"
cp -f "$d/wolfpack_chain/chain.log" "$(dirname "${BASH_SOURCE[0]}")/logs/chain.log" 2>/dev/null

ok_if "[[ -f '$d/wolfpack_chain/FINISHED' ]]" \
      "the relaxation CONVERGED through the chain ($( [[ -f $d/wolfpack_chain/STOPPED ]] && sed -n 's/^reason *: //p' "$d/wolfpack_chain/STOPPED"))"
nchunk=$(grep -cE '^  [0-9]+ ' "$d/wolfpack_chain/chain.log" 2>/dev/null)
ok_if "(( nchunk >= 2 ))" "it took more than one chunk, so a boundary was crossed for real ($nchunk chunks)"
info "    chain.log:"; sed 's/^/      /' "$d/wolfpack_chain/chain.log" | while IFS= read -r l; do info "$l"; done

# Every chunk measured its memory, on a real cluster.
nomem=$(awk '/^  [0-9]+ / && ($9+0) <= 0' "$d/wolfpack_chain/chain.log" 2>/dev/null | wc -l)
ok_if "(( nomem == 0 ))" "every chunk measured its own memory (peakMB column filled in all $nchunk)"
src=$(sed -n 's/^last_mem_src="\(.*\)"$/\1/p' "$d/wolfpack_chain/chain.env")
info "    memory source on this cluster: ${src:-?}"
ok_if "[[ -n '$src' && '$src' != 'not measured' ]]" "the measurement came from ${src} -- a real one"

# The request was rewritten from it. Si with 4 ranks uses a few hundred MB per
# rank, so 1000 MB/cpu comes DOWN to what was measured plus headroom.
mem=$(sed -n 's/^chain_mem_per_cpu="\(.*\)"$/\1/p' "$d/wolfpack_chain/chain.env")
peak=$(sed -n 's/^mem_peak_max_mb="\(.*\)"$/\1/p' "$d/wolfpack_chain/chain.env")
ok_if "[[ -n '$mem' ]] && (( mem != 1000 ))" \
      "the chunk allocation was rewritten from the measurement: 1000 -> ${mem} MB/cpu (peak ${peak} MB/rank)"
ok_if "(( ${mem:-0} >= ${peak:-1} ))" "and never below the largest peak measured (${mem} >= ${peak})"

# The structure record vasp-check relies on.
ok_if "[[ -s '$d/wolfpack_chain/chunk-001/POSCAR.in.gz' ]]" \
      "chunk-001/POSCAR.in.gz holds the original geometry for vasp-check's whole-chain diff"

scancel -u "$USER" 2>/dev/null || true
exit $(( FAIL_N > 0 ))
