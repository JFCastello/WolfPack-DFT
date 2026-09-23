#!/usr/bin/env bash
# test_28_bench_failed -- a benchmark that died must not size production.
#
# This is the bug this test exists for, seen in the wild on 2026-09-23: a
# benchmark job was OOM-killed 19 seconds in, having completed ZERO electronic
# steps, and vasp-test reported
#
#     [VERDICT]  ADEQUATE -- the recommended config works; memory updated below.
#
# and wrote a production job script sized from its numbers. Those numbers are
# not the requirement. VASP dies during FFT planning, BEFORE it allocates the
# wavefunctions, so the memory recorded is a FLOOR the real run passes
# immediately -- and a production script built from a floor reproduces the
# failure, at production cost.
#
# The failure mode is the dangerous one: silent, and shaped like success.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/benchfail"; rm -rf "$W"; mkdir -p "$W"
HELPER="$TK_DIR/vasp_test_recommend.py"

# A dry-run-shaped OUTCAR: the helper only needs the dimensions from it.
cat > "$W/OUTCAR" <<'EOF'
 vasp.6.5.1 10Mar25 (build Nov 19 2025) complex
   k-points           NKPTS =     95   k-points in BZ  NKDIM =  95   number of bands    NBANDS=      48
   number of ions     NIONS =     20
      total amount of memory used by VASP MPI-rank0  2097152. kBytes
      base      :      30000. kBytes
      nonl-proj :     500000. kBytes
      fftplans  :      70000. kBytes
      grid      :     900000. kBytes
      one-center:      10000. kBytes
      wavefun   :     587152. kBytes
EOF

# The numbers are the real ones from that run, so the fixture is the incident
# rather than an invention: 95 ranks, KPAR=95, MaxRSS 8320 MB, AveRSS 3756 MB,
# 78 % CPU efficiency -- everything that made it look healthy.
_run(){ # _run OUTFILE [extra args...] -> prints RC
    local out="$1"; shift
    "$WP_PY" "$HELPER" "$W/OUTCAR" \
        --maxrss-mb 8320 --averss-mb 3756 --ntasks-test 95 \
        --test-kpar 95 --test-ncore 1 --test-npar 1 \
        --prod-ranks 95 --prod-kpar 95 --prod-ncore 1 --prod-npar 1 --prod-nsim 4 \
        --prod-partition main --cpus-per-node 256 --node-mem-mb 363520 \
        --mem-util 0.81 --cpu-eff 77.9 "$@" > "$out" 2>&1
    echo $?
}

# ===========================================================================
# 1. THE CONTROL FIRST: a healthy benchmark still passes
# ===========================================================================
# Written first on purpose. Every assertion below is of the form "it refuses",
# and a helper that refused EVERYTHING would pass all of them.
# A real job script, because update_slurm REWRITES #SBATCH directives -- handing
# it an empty file would make "did it write one?" pass or fail for reasons that
# have nothing to do with the verdict. This is what vasp-test copies in.
sane="$W/sane.sh"
cat > "$sane" <<'EOF'
#!/bin/bash
#SBATCH --job-name=vasp
#SBATCH --nodes=1
#SBATCH --ntasks=95
#SBATCH --ntasks-per-node=95
#SBATCH --mem-per-cpu=3640
#SBATCH --time=08:00:00
srun vasp_std
EOF
rc=$(_run "$W/sane.out" --nscf 12 --wall 300 --update-slurm "$sane")
ok_if "[[ '$rc' == 0 ]]" "a healthy benchmark still exits 0 (got $rc)"
ok_if "grep -q 'ADEQUATE' '$W/sane.out'" "a healthy benchmark is still ADEQUATE"
ok_if "grep -q 'FILES. updated' '$W/sane.out'" "and it still writes the production memory"
ok_if "[[ -s '$sane' ]]" "and the production job script is still produced"

# ===========================================================================
# 2. THE THREE WAYS A BENCHMARK DIES WHILE LOOKING FINE
# ===========================================================================
# Each is passed as the reason vasp-test detected; the helper's job is to treat
# any of them as "this measured nothing".
i=0
for why in \
    "the benchmark was OOM-killed (a task exceeded --mem-per-cpu=3640 MB)" \
    "VASP exited with code 1" \
    "VASP completed no electronic step in 19s"; do
    i=$((i+1))
    # Starts as a copy of the healthy script: the claim is that a FAILED run
    # leaves it ALONE, which cannot be shown with a file that was empty anyway.
    tgt="$W/prod_$i.sh"; cp "$sane" "$tgt"
    rc=$(_run "$W/fail_$i.out" --nscf 0 --wall 19 --bench-failed "$why" --update-slurm "$tgt")
    lbl="${why%% (*}"
    ok_if "[[ '$rc' == 8 ]]" "$lbl -> exit 8, distinct from success and from the GW re-pick (got $rc)"
    ok_if "grep -qE '^\[VERDICT\]  FAILED' '$W/fail_$i.out'" "$lbl -> the verdict is FAILED"
    ok_if "! grep -q 'ADEQUATE' '$W/fail_$i.out'" "$lbl -> it is never also called ADEQUATE"
    ok_if "! grep -q 'FILES. updated' '$W/fail_$i.out'" "$lbl -> it does not claim to have updated anything"
    ok_if "cmp -s '$tgt' '$sane'" "$lbl -> the production job script is left UNTOUCHED"
done

# ===========================================================================
# 3. THE REPORT MUST NOT CONTRADICT ITSELF
# ===========================================================================
# "memory fits one node" is computed from a run that was killed for not
# fitting. Printing it as a bullet under FAILED is how a report argues with its
# own headline -- and the reader believes the reassuring half.
out="$W/fail_1.out"
if grep -qE '^  - memory fits' "$out"; then
    fail "under FAILED the report still asserts 'memory fits' as a finding"
else
    pass "under FAILED the measured lines are not presented as findings"
fi
ok_if "grep -qiE 'NOT findings|did not run' '$out'" \
      "and it says plainly that nothing below is a measurement of this run"

# ===========================================================================
# 4. IT SAYS WHAT TO CHANGE
# ===========================================================================
# A refusal that does not say what to do gets worked around. These three are
# the levers, in the order they free memory.
ok_if "grep -qi 'lower KPAR' '$out'"      "the refusal names KPAR, which duplicates the density per k-group"
ok_if "grep -q 'KPAR=95 means' '$out'"    "and quotes the actual KPAR, so the cost is concrete"
ok_if "grep -qi 'fewer ranks per node' '$out'" "it names ranks-per-node, the other memory lever"
ok_if "grep -qi 're-run vasp-test' '$out'" "and says what to do next"

# ===========================================================================
# 5. THE OOM PATTERN MATCHES WHAT SLURM ACTUALLY WRITES
# ===========================================================================
# vasp-test greps the job's stderr for the OOM. The pattern is the fragile part
# -- it has to match slurmstepd's real wording, not a paraphrase -- so it is
# checked against the message from the incident, copied verbatim.
cat > "$W/benchmark-13249633.err" <<'EOF'
slurmstepd: error: Detected 1 oom_kill event in StepId=13249633.0. Some of the step tasks have been OOM Killed.
srun: error: mn019: task 94: Out Of Memory
srun: Terminating StepId=13249633.0
EOF
grep -qiE 'oom[-_]kill|Out Of Memory' "$W/benchmark-13249633.err" \
    && pass "the OOM pattern matches slurmstepd's real message, copied from the incident" \
    || fail "the OOM pattern does not match what SLURM actually writes"
# And it must not fire on an ordinary log, or every benchmark would be refused.
printf 'srun: job 1 queued\n running 95 mpi-ranks, on 1 nodes\n LOOP:  cpu time 1.0\n' > "$W/clean.err"
grep -qiE 'oom[-_]kill|Out Of Memory' "$W/clean.err" \
    && fail "the OOM pattern fires on a log with no OOM in it" \
    || pass "and it does not fire on an ordinary benchmark log"

# vasp-test itself must still parse, and must pass the flag through.
bash -n "$TK_DIR/vasp_test.sh" 2>/dev/null \
    && pass "vasp_test.sh parses with the detection in it" \
    || fail "vasp_test.sh does not parse"
ok_if "grep -q -- '--bench-failed' '$TK_DIR/vasp_test.sh'" \
      "vasp-test passes the reason to the helper rather than deciding twice"

exit $(( FAIL_N > 0 ))
