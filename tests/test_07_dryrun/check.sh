#!/usr/bin/env bash
# vasp-dry-run, stage 1. It is the cheapest stage and the one every later stage
# trusts, so the thing to test is what it CLAIMS: a stage that says "OK" when
# it measured nothing is worse than one that fails.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/dryrun"; rm -rf "$W"; mkdir -p "$W"
DR="$TK_DIR/vasp_dry_run.sh"

_inputs(){ local d="$1" case="${2:-Si}"; mkdir -p "$d"
    cp "$CASES/$case/POSCAR" "$d/POSCAR"
    printf 'Auto\n0\nGamma\n8 8 8\n0 0 0\n' > "$d/KPOINTS"
    printf 'SYSTEM = %s\nPREC = Accurate\nENCUT = 400\nEDIFF = 1E-6\nISMEAR = 0\nSIGMA = 0.05\n' \
        "$case" > "$d/INCAR"
    if have_potcar "$case"; then cat "$WP_POTCAR_DIR/$case/POTCAR" > "$d/POTCAR"; fi; }

# --- each missing input is refused BY NAME ---------------------------------
# "something is missing" sends a user looking through four files. Naming the
# one that is missing is the whole difference.
for miss in INCAR POSCAR KPOINTS POTCAR; do
    d="$W/no_$miss"; _inputs "$d"; rm -f "$d/$miss"
    must_refuse "a missing $miss is refused, and the message names it" "$miss" \
        bash -c "cd '$d' && '$DR' </dev/null"
done

# --- an empty input file is not a present input ----------------------------
# A zero-byte POSCAR passes every [[ -f ]] test ever written.
d="$W/empty_poscar"; _inputs "$d"; : > "$d/POSCAR"
must_refuse "a zero-byte POSCAR is refused, not treated as present" "POSCAR|empty" \
    bash -c "cd '$d' && '$DR' </dev/null"

# --- the honesty of the status line ----------------------------------------
# --dry-run exits before VASP allocates, so there IS no memory table. Stage 2
# sizes production from whatever stage 1 reports; a stage that claims a table
# it does not have sends a wrong number downstream, silently.
if ! have_slurm; then
    skip "no slurmctld -- the live dry run goes untested"
elif ! have_vasp; then
    skip "no VASP -- the live dry run goes untested"
elif ! have_potcar Si; then
    skip "no Si POTCAR -- the live dry run goes untested"
else
    export SLURM_CONF="$TESTBED_ROOT/slurm.conf"
    d="$W/live"; _inputs "$d"
    cat > "$d/cluster.conf" <<EOF
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
    ( cd "$d" && WOLFPACK_CLUSTER_CONF="$d/cluster.conf" timeout 300 bash "$DR" >dry.log 2>&1 ) \
        && pass "stage 1 submitted and returned" \
        || { fail "stage 1 failed: $(tail -1 "$d/dry.log")"; }
    for _ in $(seq 1 40); do [[ -s "$d/.wolfpack/dryrun_OUTCAR" ]] && break; sleep 2; done
    ok_if "[[ -s '$d/.wolfpack/dryrun_OUTCAR' ]]" "stage 1 captured the dry-run OUTCAR"

    rep="$d/report.out"
    if grep -qi "memory table captured" "$rep" 2>/dev/null && \
       ! grep -qiE "VASP table / rank *: *[0-9]" "$rep" 2>/dev/null; then
        fail "stage 1 claims a memory table it does not have"
    else
        pass "stage 1 does not claim a memory table it does not have"
    fi

    # The dimensions later stages depend on must actually be there, and be the
    # ones this system has: Si with an 8x8x8 mesh has 29 irreducible k-points.
    nk=$(grep -oP 'NKPTS\s*=\s*\K[0-9]+' "$d/.wolfpack/dryrun_OUTCAR" | head -1)
    ok_if "[[ -n '$nk' && '$nk' -gt 0 ]]" "the OUTCAR carries NKPTS, which stage 2 needs ($nk)"
    nb=$(grep -oP 'NBANDS=\s*\K[0-9]+' "$d/.wolfpack/dryrun_OUTCAR" | head -1)
    ok_if "[[ -n '$nb' && '$nb' -ge 4 ]]" "the OUTCAR carries NBANDS ($nb)"

    # Stage 1 must be FREE. If it started a real SCF it is not a dry run.
    grep -qiE "dry.run|ALGO *= *None" "$d/.wolfpack/dryrun_OUTCAR" "$d"/slurm_dryrun.sh 2>/dev/null \
        && pass "stage 1 really ran a dry run, not a calculation" \
        || fail "nothing marks this as a dry run -- did it compute?"
fi
exit $(( FAIL_N > 0 ))
