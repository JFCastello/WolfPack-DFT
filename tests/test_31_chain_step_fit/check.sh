#!/usr/bin/env bash
# test_31_chain_step_fit -- the chunk walltime is fixed for a chain, and a
# chain that cannot fit ONE ionic step in it refuses to start, or to go on.
#
# Every chunk pays a queue wait and a walltime of core-hours. A chunk that
# cannot complete a single ionic step produces nothing for either -- and the
# check that was supposed to stop it could never fire: the cap was clamped to
# at least 1 on the line before `(( CAP1 < 1 )) && die`.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/chainfit"; rm -rf "$W"; mkdir -p "$W"
source "$SUITE_DIR/chain_harness.sh"
_acct(){ ch_sacct "$1" "$2" "$2|${5:-RUNNING}||" "$2.0|${6:-COMPLETED}|${3}M|${4}M"; }

# A slow calculation: 200 s per electronic step in the benchmark, 10 per ionic
# step. The chain's estimate of one ionic step:
#     CAL   = 200 x (4/4 ranks) / 0.90 efficiency   = 222.2 s
#     T_ION = CAL x 10 x 1.15                        = 2555.6 s
# and a first chunk starts cold, so it must hold T_ION x 1.5 = 3833 s.
# A 60-min chunk leaves 3600 - 5 min margin - 10 s start-up = 3290 s.
_slow(){ sed -i 's/test_avg_loop="2.0"/test_avg_loop="200"/' "$1/.wolfpack/state.env"; }

# --help documents the options this test exercises, all of them: it printed a
# fixed range of lines, and the header had grown past it.
h=$(bash "$CH_TK" --mode relax --help 2>&1)
ok_if "grep -q -- '--no-queue-study' <<<\"\$h\" && grep -q 'REQUIREMENTS' <<<\"\$h\"" \
      "--help prints the whole header, down to its last section"

# ===========================================================================
# 1. AT LAUNCH: a chunk that cannot hold one step is refused
# ===========================================================================
d=$(ch_setup slow); _slow "$d"
out=$(ch_run "$d" --walltime 60 2>&1); rc=$?
ok_if "(( rc != 0 ))" "a 60-min chunk that cannot hold one ~2556 s ionic step is refused (rc=$rc)"
ok_if "grep -qi 'not even ONE ionic step' <<<\"\$out\"" "and it says so in those words"
# The shortest walltime that holds one step, by the chain's own arithmetic:
#   w*60 - max(5, int(0.08 w))*60 - 10 >= 3833   ->   w = 70
ok_if "grep -q 'holds one: 70 min' <<<\"\$out\"" \
      "it names the shortest chunk that WOULD hold one: 70 min (it said: $(grep -o 'holds one: [0-9]* min' <<<"$out"))"
ok_if "[[ ! -f '$d/wolfpack_chain/slurm_chunk.sh' ]] && [[ '$(ch_nsub "$d")' == 0 ]]" \
      "nothing is rendered and nothing is submitted"
# Both numbers, so the arithmetic can be checked by the reader: the estimate,
# and what a cold first chunk must hold (2555.6 x 1.5 = 3833.4 -> 3834 s).
ok_if "grep -q '~2555.6s' <<<\"\$out\" && grep -q 'must hold 1.5 x that: 3834s' <<<\"\$out\"" \
      "it gives the step estimate AND the 1.5x cold-start amount the chunk must hold (3834 s)"
ok_if "grep -q 'Launch with: *--walltime 70' <<<\"\$out\"" "and the command that would work: --walltime 70"
out=$(ch_run "$d" --walltime 70 2>&1); rc=$?
ok_if "(( rc == 0 ))" "the same chain at 70 min is accepted -- the refusal is exact, not conservative"

# ===========================================================================
# 2. THE PARTITION'S MaxTime
# ===========================================================================
# An explicit --walltime above MaxTime is refused rather than silently cut:
# the user asked for something the scheduler will not give.
d=$(ch_setup maxtime)
out=$(FAKE_MAXTIME=01:00:00 ch_run "$d" --walltime 90 2>&1); rc=$?
ok_if "(( rc != 0 )) && grep -qi 'MaxTime' <<<\"\$out\"" "--walltime above the partition's MaxTime is refused, naming MaxTime"
# And when even MaxTime cannot hold one step, there is no walltime to try.
d=$(ch_setup maxtime_slow); _slow "$d"
out=$(FAKE_MAXTIME=01:00:00 ch_run "$d" --no-queue-study 2>&1); rc=$?
ok_if "(( rc != 0 )) && grep -qi 'allows at most 60 min' <<<\"\$out\"" \
      "when the step fits only beyond MaxTime, it says no chunk on this partition can hold one"
# A profile default above MaxTime is capped, not refused: the user did not ask for it.
d=$(ch_setup cap)
sed -i 's/WP_CHUNK_WALLTIME_MIN="60"/WP_CHUNK_WALLTIME_MIN="600"/' "$W/cap.fake/cluster.conf"
out=$(FAKE_MAXTIME=02:00:00 ch_run "$d" --no-queue-study 2>&1); rc=$?
ok_if "(( rc == 0 )) && [[ '$(ch_job "$d" time)' == 02:00:00 ]]" \
      "a profile default above MaxTime is capped to it ($(ch_job "$d" time))"

# ===========================================================================
# 3. MID-CHAIN: a step that has grown past the chunk stops the chain
# ===========================================================================
# The walltime is fixed for the chain. If ionic steps grow -- a cell
# relaxation's basis grows with the volume, a harder geometry needs more SCF
# steps -- past what a chunk can hold, the next chunk would be killed before
# completing one. The chain stops instead of submitting it.
d=$(ch_setup grows)
ch_plan "$d" "t_ion=4000"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
nsub=$(ch_nsub "$d")
ch_chunk "$d"
ok_if "[[ '$(ch_state "$d" stop_reason)' == step_exceeds_chunk ]]" \
      "a chunk that measured 4000 s per step stops the chain (reason: $(ch_state "$d" stop_reason))"
ok_if "[[ '$(ch_nsub "$d")' == '$nsub' ]]" "and submits no chunk that could not complete a step"
ok_if "grep -q '4000' '$d/wolfpack_chain/STOPPED'" "the stop gives the measured step time"
# The chunk itself ran to completion; only the NEXT one cannot. Its geometry
# is kept -- otherwise the way out below would silently redo it.
ok_if "cmp -s '$d/CONTCAR' '$d/POSCAR'" "the geometry this chunk reached is kept (CONTCAR -> POSCAR)"
# The way out, with the number: 4000 s x 1.15 = 4600 s must fit after the
# margin (max(5, 8 %) min) and the 10 s start-up.
#   83 min: 4980 - 360 - 10 = 4610 >= 4600     82 min: 4920 - 360 - 10 = 4550 < 4600
ok_if "grep -q 'vasp-relax-loop --fresh --walltime 83' '$d/wolfpack_chain/STOPPED'" \
      "the stop says --resume cannot help and names the new chain that would: --fresh --walltime 83"
ok_if "! grep -q '^Resume with' '$d/wolfpack_chain/STOPPED'" "and does not tell the user to --resume"
out=$(ch_run "$d" --resume 2>&1); rc=$?
ok_if "(( rc != 0 )) && grep -q -- '--fresh --walltime 83' <<<\"\$out\"" \
      "--resume, tried anyway, refuses with the same way out (rc=$rc)"
ok_if "[[ '$(ch_nsub "$d")' == '$nsub' ]]" "and submits nothing"

# ===========================================================================
# 4. A WALLTIME KILL, SEEN BY --resume
# ===========================================================================
# (a) not one step completed before the walltime killed the job: the step
#     does not fit, and resubmitting would repeat it exactly.
d=$(ch_setup tmo0)
ch_plan "$d" "t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
ch_chunk "$d"
jid=$(ch_last_jid "$d")
ch_plan "$d" "ionic=0 timeout=1"
ch_die "$d"
_acct "$d" "$jid" 1500 1000 TIMEOUT CANCELLED
nsub=$(ch_nsub "$d")
out=$(ch_run "$d" --resume 2>&1); rc=$?
ok_if "(( rc != 0 )) && grep -qi 'not one ionic step completed' <<<\"\$out\"" \
      "--resume after a walltime kill with no step done refuses: the step does not fit"
ok_if "[[ '$(ch_nsub "$d")' == '$nsub' ]]" "and submits nothing"
# (b) steps were completed, but slower than the model said: the walltime stays,
#     the number of steps per chunk comes down to what was measured.
#     3290 s / (1500 s x 1.15) = 1 step per chunk.
d=$(ch_setup tmo2)
ch_plan "$d" "t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
ch_chunk "$d"
jid=$(ch_last_jid "$d")
ch_plan "$d" "ionic=2 t_ion=1500 timeout=1"
ch_die "$d"
_acct "$d" "$jid" 1500 1000 TIMEOUT CANCELLED
out=$(ch_run "$d" --resume 2>&1); rc=$?
ok_if "(( rc == 0 ))" "--resume after a walltime kill that did complete steps continues (rc=$rc)"
ok_if "[[ '$(ch_state "$d" next_cap)' == 1 && '$(ch_job "$d" time)' == 01:00:00 ]]" \
      "the walltime is unchanged ($(ch_job "$d" time)) and the cap drops to what fits: $(ch_state "$d" next_cap) step"

exit $(( FAIL_N > 0 ))
