#!/usr/bin/env bash
# vasp-diagnose: why a failed run died, and whether its data is still usable.
#
# A post-mortem on a CRASH is believed more readily than almost anything else,
# because by the time you run it you already know something went wrong and you
# are looking for a name for it. Giving the wrong name sends the user to fix
# the wrong thing: raising memory for a walltime kill, or shortening a job that
# was OOM-killed.
#
# Each case below plants the evidence a real failure leaves and checks the
# diagnosis. The failures are synthesised rather than provoked because an OOM
# on this laptop would take the laptop with it.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
VD="$TK_DIR/vasp_diagnose.sh"
W="$WORK/diagnose"; rm -rf "$W"; mkdir -p "$W"

_case(){ # _case NAME -- a folder with the inputs a real run had
    local d="$W/$1"; mkdir -p "$d/.wolfpack"
    cp "$CASES/Si/POSCAR" "$d/POSCAR"
    printf 'Auto\n0\nGamma\n6 6 6\n0 0 0\n' > "$d/KPOINTS"
    printf 'SYSTEM = Si\nPREC = Accurate\nENCUT = 400\nEDIFF = 1E-6\nNELM = 60\n' > "$d/INCAR"
    : > "$d/POTCAR"
    echo "$d"
}

_diag(){ ( cd "$1" && timeout 200 bash "$VD" 2>&1 ); }

# --- OOM --------------------------------------------------------------------
d=$(_case oom)
cat > "$d/slurm-101.err" <<'EOF'
slurmstepd: error: Detected 1 oom-kill event(s) in StepId=101.batch cgroup.
Some of your processes may have been killed by the cgroup out-of-memory handler.
srun: error: node01: task 3: Out Of Memory
EOF
out=$(_diag "$d")
grep -qiE "out of memory|OOM" <<<"$out" \
    && pass "an oom-kill in the SLURM log is diagnosed as OOM" \
    || fail "an oom-kill was not diagnosed as OOM: $(grep -iE 'cause' <<<"$out" | head -1)"
grep -qiE "time limit|walltime" <<<"$out" \
    && fail "an OOM was ALSO blamed on the walltime" \
    || pass "an OOM is not also blamed on the walltime"

# --- walltime ---------------------------------------------------------------
# The discriminating twin of the case above. Same folder, different evidence.
d=$(_case wall)
cat > "$d/slurm-102.err" <<'EOF'
slurmstepd: error: *** JOB 102 ON node01 CANCELLED AT 2026-01-01T03:00:00 DUE TO TIME LIMIT ***
EOF
out=$(_diag "$d")
grep -qiE "time limit|walltime|timeout" <<<"$out" \
    && pass "a DUE TO TIME LIMIT kill is diagnosed as a walltime kill" \
    || fail "a walltime kill was not diagnosed as one"
grep -qiE "out of memory|OOM" <<<"$out" \
    && fail "a walltime kill was ALSO blamed on memory" \
    || pass "a walltime kill is not also blamed on memory"

# --- segfault ---------------------------------------------------------------
d=$(_case segv)
cat > "$d/slurm-103.err" <<'EOF'
forrtl: severe (174): SIGSEGV, segmentation fault occurred
Image              PC                Routine            Line        Source
vasp_std           00000000023A1B2C  Unknown               Unknown  Unknown
srun: error: node01: task 0: Segmentation fault (core dumped)
EOF
out=$(_diag "$d")
grep -qiE "segmentation|segv|crash" <<<"$out" \
    && pass "a segmentation fault is diagnosed as a crash" \
    || fail "a segfault was not diagnosed as a crash"

# --- non-convergence, with the data still usable ---------------------------
# This is the classification that matters most: a run that ran out of NELM has
# produced eigenvalues. Calling it NOT_USABLE throws away work that is fine.
d=$(_case nelm)
cat > "$d/OUTCAR" <<'EOF'
 vasp.6.5.1 test
   k-points           NKPTS =     16   number of bands    NBANDS=      8
   NELM   =     60;   NELMIN=  2; NELMDL= -5
 ----------------------------------------- Iteration    1(   60)  ---------
 free  energy   TOTEN  =        -10.84000000 eV
 General timing and accounting informations for this job:
EOF
for i in $(seq 1 60); do echo "DAV:  $i    -0.108E+02   -0.1E-03   -0.1E-04   100   0.5E-01" >> "$d/OSZICAR"; done
out=$(_diag "$d")
grep -qiE "converg" <<<"$out" \
    && pass "an SCF that exhausted NELM is diagnosed as non-convergence" \
    || fail "an unconverged SCF was not diagnosed as such"

# --- a run that did not fail at all ----------------------------------------
# Diagnosing a healthy run must not invent a cause.
d=$(_case fine)
cat > "$d/OUTCAR" <<'EOF'
 vasp.6.5.1 test
   k-points           NKPTS =     16   number of bands    NBANDS=      8
 ------------------------ aborting loop because EDIFF is reached ------------
 reached required accuracy - stopping structural energy minimisation
 free  energy   TOTEN  =        -10.84000000 eV
 General timing and accounting informations for this job:
EOF
printf 'DAV:   1    -0.108E+02   -0.1E-06   -0.1E-08   100   0.5E-05\n' > "$d/OSZICAR"
out=$(_diag "$d")
grep -qiE "oom|out of memory|segmentation|time limit" <<<"$out" \
    && fail "a healthy run was given a failure cause: $(grep -iE 'cause' <<<"$out" | head -1)" \
    || pass "a run that did not fail is not given a failure cause"

# --- nothing to diagnose ----------------------------------------------------
mkdir -p "$W/bare"
out=$(cd "$W/bare" && timeout 200 bash "$VD" 2>&1) || true
grep -qiE "traceback|syntax error" <<<"$out" \
    && fail "an empty directory crashes vasp-diagnose" \
    || pass "an empty directory does not crash vasp-diagnose"
exit $(( FAIL_N > 0 ))
