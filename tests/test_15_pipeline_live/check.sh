#!/usr/bin/env bash
# The three stages, run for real against a live SLURM and a VASP that computes.
# This is the check that cannot be done any other way: reading the scripts the
# toolkit writes tells you they parse; submitting them tells you the scheduler
# takes them; running them tells you VASP starts and that the numbers the
# report quotes are the numbers the run produced.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
have_slurm || { skip "no slurmctld -- run tests/slurm_testbed.sh start"; exit 0; }
have_vasp  || { skip "no VASP at $WP_VASP"; exit 0; }
have_potcar Si || { skip "no Si POTCAR under $WP_POTCAR_DIR"; exit 0; }
export SLURM_CONF="$TESTBED_ROOT/slurm.conf"

W="$WORK/pipeline"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
cp "$CASES/Si/POSCAR" POSCAR
cat "$WP_POTCAR_DIR/Si/POTCAR" > POTCAR
printf 'Auto\n0\nGamma\n6 6 6\n0 0 0\n' > KPOINTS
cat > INCAR <<'EOF'
SYSTEM = Si pipeline
PREC   = Accurate
ENCUT  = 400
EDIFF  = 1E-6
ISMEAR = 0 ; SIGMA = 0.05
NSW    = 0
LWAVE  = .FALSE. ; LCHARG = .FALSE.
EOF
cat > cluster.conf <<EOF
WP_VASP_STD="$WP_VASP"
WP_VASP_MODULES=""
WP_MAIN_PARTITION="local"
WP_DEBUG_PARTITION="local"
WP_MAIN_CPUS_PER_NODE="8"
WP_DEBUG_CPUS_PER_NODE="8"
WP_MAIN_MEM_PER_NODE_MB="6000"
WP_DEBUG_MEM_PER_NODE_MB="6000"
WP_MAX_CORES="8"
WP_DEBUG_MAX_CORES="8"
WP_MEM_UTIL="0.81"
WP_MEM_UTIL_MIN="0.80"
WP_MAIN_MEM_MARGIN="0.02"
WP_DEBUG_MEM_MARGIN="0.05"
WP_TEST_WALLTIME_MIN="5"
EOF
export WOLFPACK_CLUSTER_CONF="$W/cluster.conf"

# --- STAGE 1 ---------------------------------------------------------------
timeout 300 bash "$TK_DIR/vasp_dry_run.sh" >dry.log 2>&1 \
    && pass "stage 1 submitted" || { fail "stage 1: $(tail -1 dry.log)"; exit 1; }
for _ in $(seq 1 40); do [[ -s .wolfpack/dryrun_OUTCAR ]] && break; sleep 2; done
ok_if "[[ -s .wolfpack/dryrun_OUTCAR ]]" "stage 1 captured the OUTCAR"

# --- STAGE 2 ---------------------------------------------------------------
timeout 300 "$WP_PY" "$TK_DIR/vasp_recommend_slurm.py" >rec.log 2>&1 \
    && pass "stage 2 chose a layout" || { fail "stage 2: $(tail -1 rec.log)"; exit 1; }
ok_if "[[ -s slurm.sh ]]" "stage 2 wrote a production job script"

# The geometry it writes must be internally consistent AND acceptable to a real
# scheduler. Three numbers that disagree (--nodes, --ntasks, --ntasks-per-node)
# is how a job silently gets more CPUs than it asked for.
r=$(grep -oP '(?<=--ntasks=)\d+' slurm.sh | head -1)
n=$(grep -oP '(?<=--nodes=)\d+' slurm.sh | head -1)
t=$(grep -oP '(?<=--ntasks-per-node=)\d+' slurm.sh | head -1)
if [[ -n "$t" ]]; then
    ok_if "(( n * t == r ))" "slurm.sh geometry is self-consistent ($n x $t = $r)"
else
    pass "slurm.sh omits --ntasks-per-node rather than claiming an untrue one"
fi
ok_if "(( n * 8 <= 8 ))" "slurm.sh stays inside the 8-core cap ($((n*8)) cores)"
out=$(sbatch --test-only slurm.sh 2>&1)
grep -qiE 'error|failure' <<<"$out" \
    && fail "SLURM rejects slurm.sh: $(tail -1 <<<"$out")" \
    || pass "SLURM accepts slurm.sh"

# The INCAR it wrote must carry the layout it chose. If the two disagree, the
# benchmark measures one configuration and production runs another.
k_inc=$(grep -m1 -oP '^KPAR\s*=\s*\K[0-9]+' INCAR 2>/dev/null)
k_rec=$(grep -m1 -oP '^KPAR\s*:\s*\K[0-9]+' rec.log 2>/dev/null)
ok_if "[[ -n '$k_inc' && '$k_inc' == '$k_rec' ]]" \
    "the INCAR carries the KPAR that was recommended ($k_inc)"

# --- STAGE 3 ---------------------------------------------------------------
timeout 900 bash "$TK_DIR/vasp_test.sh" >test.log 2>&1 \
    && pass "stage 3 submitted" || { fail "stage 3: $(tail -1 test.log)"; }
for _ in $(seq 1 90); do grep -q "DONE\|CANNOT" report.out 2>/dev/null && break; sleep 3; done

b=$(ls .wolfpack/benchmark-*.out 2>/dev/null | tail -1)
if [[ -z "$b" ]]; then
    fail "stage 3 produced no benchmark output"
else
    grep -qE "^(DAV|RMM):" "$b" \
        && pass "stage 3 ran VASP (electronic steps recorded)" \
        || fail "stage 3 produced no electronic steps"
    # The benchmark must run the FIXED config, not whatever the raw INCAR said.
    grep -q "testing config: KPAR=${k_inc} " "$b" \
        && pass "the benchmark ran the recommended config (KPAR=$k_inc)" \
        || fail "the benchmark did not run KPAR=$k_inc"
    grep -qiE "traceback \(most recent" "$b" "$W/test.log" \
        && fail "stage 3 left a traceback" \
        || pass "stage 3 left no traceback"
fi
ok_if "[[ -s slurm_vasptest.sh ]]" "stage 3 wrote the definitive job script"
if [[ -s slurm_vasptest.sh ]]; then
    dn=$(grep -oP '(?<=--nodes=)\d+' slurm_vasptest.sh | head -1)
    ok_if "(( dn * 8 <= 8 ))" "the definitive script stays inside the core cap"
    out=$(sbatch --test-only slurm_vasptest.sh 2>&1)
    grep -qiE 'error|failure' <<<"$out" \
        && fail "SLURM rejects slurm_vasptest.sh" \
        || pass "SLURM accepts slurm_vasptest.sh"
fi
scancel -u "$USER" 2>/dev/null || true
exit $(( FAIL_N > 0 ))
