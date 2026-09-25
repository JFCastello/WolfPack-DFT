#!/usr/bin/env bash
# test_36_relax_loop -- vasp-relax-loop: fixed NSW per chunk, a walltime per
# chunk from what the last one measured, clean retries.
#
# Against the fake scheduler and the fake VASP of chain_harness.sh, whose
# CONTCAR is the last geometry computed, as a real VASP's is.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/relax_loop"; rm -rf "$W"; mkdir -p "$W"
source "$SUITE_DIR/chain_harness.sh"
x2(){ sed -n 10p "$1" | awk '{printf "%.4f", $1}'; }            # atom 2's x in a POSCAR/CONTCAR
row(){ sed -n "${2}p" "$1/wolfpack_chain/progress.rows"; }        # the N-th attempt's row
col(){ row "$1" "$2" | cut -f"$3"; }

# ===========================================================================
# 1. REFUSALS -- each a chain that could not work
# ===========================================================================
d=$(ch_setup refuse)
sed -i 's/^EDIFFG .*/EDIFFG = 0.001/' "$d/INCAR"
must_refuse "EDIFFG > 0 is refused: VASP compares energies only within one run" "EDIFFG must be negative" \
    ch_run "$d"
sed -i '/^EDIFFG/d' "$d/INCAR"
must_refuse "no EDIFFG (VASP's default EDIFF x 10 > 0) is refused too" "EDIFFG must be negative" ch_run "$d"
echo "EDIFFG = -0.01" >> "$d/INCAR"
sed -i 's/^NSW .*/NSW    = 1/' "$d/INCAR"
must_refuse "NSW = 1 is refused, with why: VASP does not move the ions after its last step" \
    "does not move the ions" ch_run "$d"
sed -i '/^NSW/d' "$d/INCAR"
must_refuse "--nsw 1 (the INCAR has none) is refused the same way" "NSW >= 2" ch_run "$d" --nsw 1
must_refuse "--steps with an entry of 1 is refused" "every chunk needs NSW >= 2" ch_run "$d" --steps 2,1,3
sed -i 's/^IBRION .*/IBRION = 0/' "$d/INCAR"
must_refuse "IBRION = 0 (molecular dynamics) is refused" "IBRION = 1, 2 or 3" ch_run "$d"
sed -i '/^IBRION/d' "$d/INCAR"
must_refuse "no IBRION is refused: with NSW > 0 VASP's default is 0" "default is IBRION = 0" ch_run "$d"
echo "IBRION = 2" >> "$d/INCAR"
sed -i 's/test_ranks="4"/test_ranks="2"/' "$d/.wolfpack/state.env"
must_refuse "vasp-test at 2 ranks for a 4-rank job is refused: run vasp-test --full-size" \
    "vasp-test --full-size" ch_run "$d"
sed -i 's/test_ranks="2"/test_ranks="4"/' "$d/.wolfpack/state.env"
mv "$d/.wolfpack/vasptest_OSZICAR" "$d/.wolfpack/x"
must_refuse "without vasp-test's OSZICAR there is nothing to extrapolate from" "OUTCAR and OSZICAR" ch_run "$d"
mv "$d/.wolfpack/x" "$d/.wolfpack/vasptest_OSZICAR"
echo "LWAVE = .FALSE." >> "$d/INCAR"
must_refuse "--carry-wavecar with LWAVE = .FALSE. is refused: there would be no WAVECAR" \
    "carry-wavecar needs the WAVECAR" ch_run "$d" --carry-wavecar
must_refuse "--margin-min below 3 is refused (the job is warned 120 s before its walltime)" \
    "at least 3" ch_run "$d" --margin-min 2
must_refuse "--safety below 1 is refused" "at least 1" ch_run "$d" --safety 0.9
ok_if "[[ \$(ch_nsub '$d') == 0 ]]" "nothing was submitted by any refusal"

# ===========================================================================
# 2. A CHAIN TO CONVERGENCE -- geometry, walltime per chunk, progress file
# ===========================================================================
# Chunk 1, from vasp-test (see chain_harness.sh): 13 electronic steps of 2.0 s
# plus 2.0 s for the forces = 28 s per ionic step; start-up 10 s; NSW = 2:
#   10 + 28 + 28 = 66 s  x 1.15 = 75.9 s -> 2 min + 5 = 7 min.
# Chunk 2, from chunk 1 as the fake writes it: step 1 = 11 x 2.0 + 0.5 = 22.5 s,
# step 2 = 6 x 2.0 + 0.5 = 12.5 s, start-up = the chunk's wall - 35 s = 0 here:
#   0 + 22.5 + 12.5 = 35 s  x 1.15 = 40.3 s -> 1 min + 5 = 6 min.
d=$(ch_setup conv)
ch_plan "$d" "nel=11,6"; ch_plan "$d" "nel=9,5"; ch_plan "$d" "nel=9,4 conv_at=2"
out=$(ch_run "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -q 'first ionic step *28.0 s: 13 electronic steps (8 done + 3 to reach EDIFF=1e-06 at 1.00 decades/step + 2 margin)' <<<\"\$out\"" \
      "chunk 1's step is extrapolated from vasp-test: 8 done + 3 to EDIFF + 2 = 13 steps, 28 s (rc=$rc)"
ok_if "grep -q 'NSW = 2: estimate 0:01:06 -> asks 7 min' <<<\"\$out\" && [[ \$(ch_job '$d' time) == 00:07:00 ]]" \
      "and chunk 1 asks 7 min: 66 s x 1.15 + 5 min"
ch_chunk "$d"
ok_if "[[ -d '$d/wolfpack_chain/001' && ! -e '$d/wolfpack_chain/001.try1' ]]" \
      "a completed chunk's directory is filed as 001"
ok_if "[[ \$(ch_job '$d' time) == 00:06:00 ]]" \
      "chunk 2 asks 6 min, from chunk 1's measured steps (35 s x 1.15 + 5 min) (got $(ch_job "$d" time))"
ok_if "[[ \$(x2 '$d/wolfpack_chain/002.try1/POSCAR') == \$(x2 '$d/wolfpack_chain/001/CONTCAR') && \$(x2 '$d/wolfpack_chain/001/CONTCAR') == 0.7520 ]]" \
      "chunk 2 starts from chunk 1's CONTCAR (x = 0.7520: NSW = 2 moved the ions once)"
ok_if "[[ \$(x2 '$d/POSCAR') == 0.7500 && \$(x2 '$d/CONTCAR') == 0.7520 ]]" \
      "the folder's POSCAR is untouched; its CONTCAR is the latest geometry"
ch_chunk "$d"; ch_chunk "$d"
ok_if "[[ \$(ch_state '$d' chain_state) == converged && -f '$d/wolfpack_chain/FINISHED' ]]" \
      "VASP's 'reached required accuracy' ends the chain as converged"
ok_if "[[ \$(ch_state '$d' geoms_done) == 4 && \$(ch_nsub '$d') == 3 ]]" \
      "3 chunks of NSW = 2: 2 + 1 + 1 = 4 distinct geometries (each chunk's first step repeats), 3 jobs"
ok_if "[[ \$(ch_seen '$d' 1) == 'dir=001.try1 NSW=2 WAVECAR=0 x2=0.7500' && \$(ch_seen '$d' 3) == 'dir=003.try1 NSW=2 WAVECAR=0 x2=0.7540' ]]" \
      "each chunk ran in its own directory, from the geometry the last one reached"
p=$(cat "$d/relax_progress.txt")
ok_if "grep -qE '^ +1 +1 +2 +2 +2 +11 6 +13 +0:01:06 +0:07 ' <<<\"\$p\" && grep -qE '^ +2 +1 +2 +2 +3 +9 5 +11 +0:00:35 +0:06 ' <<<\"\$p\" && grep -qE ' CONVERGED\$' <<<\"\$p\"" \
      "relax_progress.txt: one row per chunk -- electronic steps per ionic step, the estimates (steps, time), the walltime asked"
ok_if "grep -q 'CONVERGED at chunk 3' <<<\"\$p\" && grep -q 'NSW per chunk: 2 (INCAR)' <<<\"\$p\"" \
      "and says how the chain ended and where NSW came from"
ok_if "[[ ! -e '$d/wolfpack_chain/001/WAVECAR' && ! -e '$d/wolfpack_chain/002/WAVECAR' && -e '$d/wolfpack_chain/003/WAVECAR' ]]" \
      "only the latest completed chunk keeps its WAVECAR"

# ===========================================================================
# 3. A WALLTIME KILL -- a clean retry, longer
# ===========================================================================
# Chunk 1 completes its first ionic step (11 steps) and is warned 3 steps into
# the second, after its ions moved once: its CONTCAR is at x = 0.7520. The
# retry must start from the ORIGINAL POSCAR (0.7500), in a new directory.
# Its walltime: at least 1.5 x 7 = 10.5 -> 11 min.
d=$(ch_setup timeout)
ch_plan "$d" "nel=11,6 stop_at=14"; ch_plan "$d" "nel=11,6"
ch_run "$d" >/dev/null 2>&1; ch_chunk "$d"
ok_if "[[ \$(col '$d' 1 13) == TIMEOUT && \$(ch_state '$d' cur_try) == 2 ]]" \
      "the warned chunk is filed as TIMEOUT and try 2 is submitted"
ok_if "[[ -d '$d/wolfpack_chain/001.try1' && ! -e '$d/wolfpack_chain/001.try1/WAVECAR' && -f '$d/wolfpack_chain/001.try1/ATTEMPT' ]]" \
      "the failed attempt stays, for diagnosis, with its restart files removed"
ok_if "[[ \$(x2 '$d/wolfpack_chain/001.try1/CONTCAR') == 0.7520 && \$(x2 '$d/wolfpack_chain/001.try2/POSCAR') == 0.7500 ]]" \
      "try 2 starts from the original POSCAR (0.7500), not the failed attempt's CONTCAR (0.7520)"
ok_if "[[ \$(ch_job '$d' time) == 00:11:00 ]]" \
      "try 2 asks at least 1.5 x the walltime that ran out: 11 min (got $(ch_job "$d" time))"
ch_chunk "$d"
ok_if "[[ -d '$d/wolfpack_chain/001' && \$(ch_state '$d' chunk_ok) == 1 ]]" "try 2 completes chunk 1"

# A step much slower than vasp-test said: 20 s per electronic step, warned after
# 8 (5 delayed + 3 self-consistent: 5e-2, 5e-3, 5e-4, one decade a step).
# Re-estimated from what it measured: 8 + 3 to EDIFF + 2 = 13 steps x 20 s,
# + 20 s for the forces (none completed) = 280 s per ionic step;
# 10 + 280 + 280 = 570 s x 1.15 = 655.5 s -> 11 min + 5 = 16 min, more than 1.5 x 7.
d=$(ch_setup slow)
ch_plan "$d" "nel=11,6 t_e=20 stop_at=8"
ch_run "$d" >/dev/null 2>&1; ch_chunk "$d"
ok_if "[[ \$(ch_job '$d' time) == 00:16:00 ]]" \
      "a slower step than measured: the retry is re-estimated from its own 20-s steps, 16 min (got $(ch_job "$d" time))"

# Retries run out.
d=$(ch_setup exhaust)
ch_plan "$d" "nel=11,6 stop_at=14"
ch_run "$d" --max-retries 1 >/dev/null 2>&1; ch_chunk "$d"; ch_chunk "$d"
ok_if "[[ \$(ch_state '$d' chain_state) == stopped && \$(ch_state '$d' stop_reason) == retries_exhausted && \$(ch_nsub '$d') == 2 ]]" \
      "--max-retries 1: after two walltime kills the chain stops (retries_exhausted), no third job"

# Chunk 2 killed: its retry starts from chunk 1's CONTCAR.
d=$(ch_setup timeout2)
ch_plan "$d" "nel=11,6"; ch_plan "$d" "nel=11,6 stop_at=14"; ch_plan "$d" "nel=11,6"
ch_run "$d" >/dev/null 2>&1; ch_chunk "$d"; ch_chunk "$d"
ok_if "[[ \$(x2 '$d/wolfpack_chain/002.try1/CONTCAR') == 0.7540 && \$(x2 '$d/wolfpack_chain/002.try2/POSCAR') == \$(x2 '$d/wolfpack_chain/001/CONTCAR') ]]" \
      "a retry of chunk 2 starts from chunk 1's CONTCAR (0.7520), not its own failed one (0.7540)"

# ===========================================================================
# 4. AN OOM KILL -- the same chunk, 1.5 x the memory
# ===========================================================================
d=$(ch_setup oom)
ch_plan "$d" "nel=11,6 oom_at=5"; ch_plan "$d" "nel=11,6"
ch_run "$d" >/dev/null 2>&1; ch_chunk "$d"
ok_if "[[ \$(col '$d' 1 13) == OOM && \$(ch_job '$d' mem-per-cpu) == 3000 && \$(ch_job '$d' time) == 00:07:00 ]]" \
      "an OOM kill: try 2 at 1.5 x 2000 = 3000 MB/cpu, same walltime"

# ===========================================================================
# 5. THE JOB DIES WITH THE CHAIN -- --resume files it and tries again
# ===========================================================================
d=$(ch_setup died)
ch_plan "$d" "nel=11,6 stop_at=14 killjob=1"; ch_plan "$d" "nel=11,6"
ch_run "$d" >/dev/null 2>&1; ch_die "$d"
ok_if "[[ \$(ch_state '$d' chain_state) == running && ! -e '$d/wolfpack_chain/001' ]]" \
      "a job killed with its body leaves the chain 'running', nothing filed"
out=$(ch_run "$d" --resume 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -q 'the last one: timeout' <<<\"\$out\" && [[ \$(ch_state '$d' cur_try) == 2 ]]" \
      "--resume reads the kill (DUE TO TIME LIMIT) and submits try 2 (rc=$rc)"
ok_if "[[ -f '$d/wolfpack_chain/001.try1/ATTEMPT' && \$(x2 '$d/wolfpack_chain/001.try2/POSCAR') == 0.7500 && \$(ch_job '$d' time) == 00:11:00 ]]" \
      "and files the dead attempt, restarts from the original POSCAR, 11 min"
ch_chunk "$d"
ok_if "[[ \$(ch_state '$d' chunk_ok) == 1 ]]" "the resumed chain carries on"

# ===========================================================================
# 6. LIMITS AND OPTIONS
# ===========================================================================
d=$(ch_setup maxion)
ch_plan "$d" "nel=11,6"
ch_run "$d" --max-ionic 3 >/dev/null 2>&1; ch_chunk "$d"; ch_chunk "$d"
ok_if "[[ \$(ch_state '$d' stop_reason) == max_ionic && \$(ch_state '$d' geoms_done) == 3 && \$(ch_nsub '$d') == 2 ]]" \
      "--max-ionic 3: 2 + 1 geometries, then the chain stops (max_ionic)"
out=$(ch_run "$d" --resume --max-ionic 4 2>&1); rc=$?
ok_if "(( rc == 0 )) && [[ \$(ch_state '$d' cur_chunk) == 3 ]]" "--resume --max-ionic 4 continues it (rc=$rc)"

d=$(ch_setup steps)
sed -i '/^NSW/d' "$d/INCAR"
ch_plan "$d" "nel=11,6"
out=$(ch_run "$d" --steps 2,4 2>&1)
ok_if "grep -q 'NSW per chunk *--steps 2,4' <<<\"\$out\"" "--steps 2,4: NSW from the list"
ch_chunk "$d"
ok_if "[[ \$(awk -F'[=!]' '/^ *NSW/{print \$2+0; exit}' '$d/wolfpack_chain/002.try1/INCAR') == 4 && \$(grep -c '^ *NSW' '$d/INCAR') == 0 ]]" \
      "chunk 2's INCAR has NSW = 4; the folder's INCAR is untouched"
ch_chunk "$d"
ok_if "[[ \$(ch_state '$d' stop_reason) == steps_done && \$(ch_nsub '$d') == 2 ]]" \
      "and after the two jobs of the list, it stops (steps_done)"

d=$(ch_setup nsw)
sed -i '/^NSW/d' "$d/INCAR"
out=$(ch_run "$d" 2>&1)
ok_if "grep -q 'NSW per chunk *2 (--nsw; the INCAR has none)' <<<\"\$out\" && [[ \$(awk -F'[=!]' '/^ *NSW/{print \$2+0; exit}' '$d/wolfpack_chain/001.try1/INCAR') == 2 ]]" \
      "no NSW in the INCAR: 2, and it says so"

d=$(ch_setup carry)
ch_plan "$d" "nel=11,6"
ch_run "$d" --carry-wavecar >/dev/null 2>&1; ch_chunk "$d"; ch_chunk "$d"
ok_if "[[ \$(ch_seen '$d' 1 | grep -o 'WAVECAR=.') == WAVECAR=0 && \$(ch_seen '$d' 2 | grep -o 'WAVECAR=.') == WAVECAR=1 ]]" \
      "--carry-wavecar: chunk 2 starts with chunk 1's WAVECAR"
d=$(ch_setup nocarry)
ch_plan "$d" "nel=11,6"
ch_run "$d" >/dev/null 2>&1; ch_chunk "$d"; ch_chunk "$d"
ok_if "[[ \$(ch_seen '$d' 2 | grep -o 'WAVECAR=.') == WAVECAR=0 ]]" "without it, chunk 2 starts with none"

# --stop: the running chunk completes, nothing more is submitted; --resume goes on.
d=$(ch_setup stop)
ch_plan "$d" "nel=11,6"
ch_run "$d" >/dev/null 2>&1
ch_run "$d" --stop >/dev/null 2>&1; ch_chunk "$d"
ok_if "[[ \$(ch_state '$d' stop_reason) == user && \$(ch_state '$d' chunk_ok) == 1 && \$(ch_nsub '$d') == 1 ]]" \
      "--stop: chunk 1 completes and is filed, no chunk 2 is submitted"
out=$(ch_run "$d" --resume 2>&1); rc=$?
ok_if "(( rc == 0 )) && [[ \$(ch_state '$d' cur_chunk) == 2 && \$(ch_job '$d' time) == 00:06:00 ]]" \
      "--resume submits chunk 2, sized from chunk 1 (6 min) (rc=$rc)"
out=$(ch_run "$d" --status 2>&1)
ok_if "grep -q 'queued: chunk 2' <<<\"\$out\"" "--status shows the progress file"

exit $(( FAIL_N > 0 ))
