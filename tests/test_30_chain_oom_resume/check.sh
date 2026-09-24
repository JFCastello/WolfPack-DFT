#!/usr/bin/env bash
# test_30_chain_oom_resume -- after an OOM kill, `vasp-relax-loop --resume`
# and nothing else continues the relaxation: the geometry it reached, the
# steps it did, and enough memory not to die the same way.
#
# Two ways a chunk dies of memory, and both happen:
#   STEP OOM   the srun step is killed; the batch script survives and the
#              chain's own body records the death (reason oom).
#   JOB DEATH  the whole job goes -- the body never runs, nothing is archived,
#              the state still says "running". --resume has to do the body's
#              bookkeeping itself.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/chainoom"; rm -rf "$W"; mkdir -p "$W"
source "$SUITE_DIR/chain_harness.sh"
_acct(){ ch_sacct "$1" "$2" "$2|${5:-RUNNING}||" "$2.0|${6:-COMPLETED}|${3}M|${4}M"; }

# ===========================================================================
# A. STEP OOM: the chain's body sees it
# ===========================================================================
d=$(ch_setup stepoom)
ch_plan "$d" "ionic=3 t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
ch_chunk "$d"                                   # chunk 1: fine, request -> 1450
granted=$(ch_job "$d" mem-per-cpu)
ch_plan "$d" "ionic=2 t_ion=30 oom=1"           # chunk 2: 2 steps, then killed
_acct "$d" "$(ch_last_jid "$d")" 1440 1300 FAILED OUT_OF_MEMORY
nsub=$(ch_nsub "$d")
ch_chunk "$d"
ok_if "[[ '$(ch_state "$d" stop_reason)' == oom ]]" \
      "an OOM-killed chunk is recognised as OOM, not as a generic failure ($(ch_state "$d" stop_reason))"
ok_if "[[ '$(ch_nsub "$d")' == '$nsub' ]]" "the dead chunk submits no successor"
ok_if "grep -q 'vasp-relax-loop --resume' '$d/wolfpack_chain/STOPPED'" \
      "the stop names the right command (it used to say vasp-scf-loop for a relaxation)"
ok_if "grep -qi 'raises the memory by itself' '$d/wolfpack_chain/STOPPED'" \
      "and says what --resume will do about the memory"
done_before=$(ch_state "$d" nsw_done)
cp "$d/POSCAR" "$W/stepoom.poscar_before"

ch_run "$d" --resume > "$W/stepoom.resume.log" 2>&1; rc=$?
ok_if "(( $rc == 0 ))" "--resume, with nothing else, continues the chain (rc=$rc)"
exp=$(awk -v g="$granted" 'BEGIN{ printf "%d", int((g*1.5+49)/50)*50 }')
ok_if "[[ '$(ch_job "$d" mem-per-cpu)' == '$exp' ]]" \
      "the memory is raised by itself: ${granted} -> $(ch_job "$d" mem-per-cpu) MB/cpu (expected ${exp}, x1.5)"
ok_if "! cmp -s '$W/stepoom.poscar_before' '$d/POSCAR' && cmp -s '$d/CONTCAR' '$d/POSCAR'" \
      "the geometry the dead chunk reached is kept (CONTCAR -> POSCAR), not redone"
ok_if "[[ '$done_before' == 5 ]]" "the 2 steps the dead chunk completed were counted (3 + 2 = ${done_before})"
ok_if "[[ '$(ch_state "$d" chain_state)' == running && '$(ch_nsub "$d")' == $((nsub+1)) ]]" \
      "the chain is running again, with one new chunk submitted"
ok_if "[[ -f '$d/wolfpack_chain/chunk-002/STOPPED.txt' ]]" "the stop record is filed with the chunk it belongs to"
# The harness calls vasp_chain.sh by its real path, as the rendered job does;
# the messages must still name the command the user types.
ok_if "grep -q 'vasp-relax-loop --status' '$W/stepoom.resume.log' && ! grep -q 'vasp_chain.sh --' '$W/stepoom.resume.log'" \
      "its messages name vasp-relax-loop, not vasp_chain.sh"

# The chain keeps going from there, at the new size.
ch_plan "$d" "ionic=4 t_ion=30"
_acct "$d" "$(ch_last_jid "$d")" 1440 1300
ch_chunk "$d"
ok_if "[[ '$(ch_state "$d" chain_state)' == running ]]" "the next chunk runs and the chain carries on"

# ===========================================================================
# B. JOB DEATH: the body never ran -- --resume does its bookkeeping
# ===========================================================================
d=$(ch_setup jobdeath)
ch_plan "$d" "ionic=3 t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
ch_chunk "$d"
jid=$(ch_last_jid "$d")
ch_plan "$d" "ionic=4 t_ion=30 killjob=1"
ch_die "$d"                                     # VASP ran 4 steps; the job, body and all, is gone
_acct "$d" "$jid" 1500 1400 OUT_OF_MEMORY OUT_OF_MEMORY
ok_if "[[ '$(ch_state "$d" chain_state)' == running ]]" \
      "(setup) a job death leaves the state saying 'running' -- nobody was left to change it"
ch_run "$d" --resume > "$W/jobdeath.resume.log" 2>&1; rc=$?
ok_if "(( $rc == 0 ))" "--resume recovers a chunk that died with its job (rc=$rc)"
ok_if "[[ -d '$d/wolfpack_chain/chunk-002' && -f '$d/wolfpack_chain/chunk-002/OSZICAR.gz' ]]" \
      "the dead chunk is archived as chunk 2, as its body would have done"
ok_if "[[ '$(ch_state "$d" nsw_done)' == 7 ]]" \
      "its 4 completed steps are counted from its OSZICAR (3 + 4 = $(ch_state "$d" nsw_done))"
ok_if "[[ \$(grep -c 'Direct configuration' '$d/wolfpack_chain/XDATCAR.all') == 7 ]]" \
      "the continuous trajectory gains its 4 frames (7 in XDATCAR.all)"
ok_if "grep -qE '^  2 .*DIED' '$d/wolfpack_chain/chain.log'" "chain.log records the death, not a gap"
ok_if "cmp -s '$d/CONTCAR' '$d/POSCAR'" "the geometry it reached becomes the next start"
ok_if "grep -q 'VASP-chain-${jid}.err' <(ls '$d/wolfpack_chain/chunk-002/')" \
      "the dead job's own logs are filed with it (they hold slurmstepd's verdict)"
ok_if "! grep -q 'No such file' '$W/jobdeath.resume.log'" \
      "and --resume prints no shell error on the way (it used to: 'RUNNING: No such file or directory')"

# ===========================================================================
# C. THE FIRST CHUNK DIES: the original geometry must still be archived
# ===========================================================================
# vasp-check's structure report after a chunked relaxation diffs against
# chunk-001/POSCAR.in.gz -- the geometry the WHOLE relaxation started from. If
# chunk 1 dies with its job, that file would never exist.
d=$(ch_setup firstdies)
ch_plan "$d" "ionic=2 t_ion=30 killjob=1"
ch_run "$d" --walltime 60 >/dev/null 2>&1
jid=$(ch_last_jid "$d")
cp "$d/POSCAR" "$W/firstdies.original"
ch_die "$d"
_acct "$d" "$jid" 1500 1400 OUT_OF_MEMORY OUT_OF_MEMORY
ch_run "$d" --resume >/dev/null 2>&1
ok_if "zcat '$d/wolfpack_chain/chunk-001/POSCAR.in.gz' 2>/dev/null | cmp -s - '$W/firstdies.original'" \
      "when chunk 1 dies, chunk-001/POSCAR.in.gz is still the ORIGINAL geometry"

# ===========================================================================
# D. A SECOND OOM ESCALATES AGAIN
# ===========================================================================
d=$W/stepoom
m1=$(ch_job "$d" mem-per-cpu)
ch_plan "$d" "ionic=1 t_ion=30 oom=1"
_acct "$d" "$(ch_last_jid "$d")" "$m1" "$m1" FAILED OUT_OF_MEMORY
ch_chunk "$d"
ch_run "$d" --resume >/dev/null 2>&1
m2=$(ch_job "$d" mem-per-cpu)
ok_if "(( m2 > m1 ))" "a second OOM raises it again (${m1} -> ${m2} MB/cpu)"
ok_if "[[ '$(ch_state "$d" oom_count)' == 2 ]]" "and the chain counts the kills it has survived (2)"

# ===========================================================================
# E. ESCALATION THAT CANNOT BE HAD IS REFUSED, WITH THE WAY OUT
# ===========================================================================
# 4 ranks at 13000 MB: one per 16 GB node, 4 nodes x 8 cores = 32, at the cap.
# One more escalation (x1.5 -> 19500) does not fit a node at all.
d=$(ch_setup cantgrow)
ch_plan "$d" "ionic=3 t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 12000 12000
ch_chunk "$d"
ch_plan "$d" "ionic=1 t_ion=30 oom=1"
_acct "$d" "$(ch_last_jid "$d")" 15000 15000 FAILED OUT_OF_MEMORY
ch_chunk "$d"
nsub=$(ch_nsub "$d")
out=$(ch_run "$d" --resume 2>&1); rc=$?
ok_if "(( rc != 0 ))" "an escalation no node can hold is refused (rc=$rc)"
ok_if "grep -qiE 'KPAR' <<<\"\$out\"" "the refusal names the way out (a lower KPAR, fewer ranks, LREAL)"
ok_if "[[ '$(ch_nsub "$d")' == '$nsub' ]]" "and nothing is submitted"

# ===========================================================================
# F. --resume WHILE A CHUNK IS STILL ALIVE IS REFUSED
# ===========================================================================
# This used to be checked for a fresh start only, so --resume on a live chain
# put a second chunk in the same folder: two VASPs over one WAVECAR.
d=$(ch_setup alive)
ch_plan "$d" "ionic=3 t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
ch_alive "$d" "$(ch_last_jid "$d")"
nsub=$(ch_nsub "$d")
must_refuse "--resume refuses while a chunk is still queued or running" "still queued or running" \
    ch_run "$d" --resume
ok_if "[[ '$(ch_nsub "$d")' == '$nsub' ]]" "and submits nothing"

# ===========================================================================
# G. A WAVECAR WRITTEN BY THE DYING CHUNK IS NOT TRUSTED
# ===========================================================================
# VASP writes WAVECAR at the end of a run. A chunk killed WHILE writing it
# leaves a truncated file, and the next chunk -- told ISTART=1 -- dies reading
# it, and so does every resume after. A size different from the last good
# WAVECAR's gives it away: set aside, and the next chunk starts cold.
d=$(ch_setup partialwave)
ch_plan "$d" "ionic=3 t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
ch_chunk "$d"
jid=$(ch_last_jid "$d")
ch_plan "$d" "ionic=2 t_ion=30 killjob=1 wavepartial=1"
ch_die "$d"
_acct "$d" "$jid" 1500 1400 OUT_OF_MEMORY OUT_OF_MEMORY
ch_run "$d" --resume >/dev/null 2>&1
ok_if "[[ -f '$d/WAVECAR.partial' && ! -f '$d/WAVECAR' ]]" "a truncated WAVECAR is set aside as WAVECAR.partial"
ch_plan "$d" "ionic=2 t_ion=30"
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
ch_chunk "$d"
ok_if "tail -1 '$W/partialwave.fake/vasp_seen' | grep -q 'ISTART=0 ICHARG=2'" \
      "and the next chunk starts cold ($(tail -1 "$W/partialwave.fake/vasp_seen" | cut -d' ' -f1-2)), instead of reading it"
ok_if "[[ '$(ch_state "$d" next_cold_start)' == 0 ]]" "only that one chunk: the one after restarts warm again"

# ===========================================================================
# H. A PLAIN START ON AN UNFINISHED CHAIN POINTS AT --resume
# ===========================================================================
# A start used to carry the old chain's state into the new one: its NBANDS,
# NKPTS, force history and -- now -- its measured memory.
d=$W/stepoom
must_refuse "a plain start on an unfinished chain refuses and points at --resume" "--resume" \
    ch_run "$d" --walltime 60
ch_run "$d" --walltime 60 --fresh >/dev/null 2>&1
ok_if "ls -d '$d'/wolfpack_chain.prev-* >/dev/null 2>&1" "--fresh archives the old chain instead of deleting it"
ok_if "[[ '$(ch_state "$d" oom_count)' == 0 && '$(ch_state "$d" chunk_index)' == 0 ]]" \
      "and the new chain starts with clean state, not the old one's"

# ===========================================================================
# I. A REFUSED --resume, RUN AGAIN, DOES NOT COUNT THE DEAD CHUNK TWICE
# ===========================================================================
# --resume settles a job death (archive, count, trajectory) BEFORE deciding
# whether it can go on. When it then refuses, the user runs it again -- and a
# chain still marked "running" had that chunk archived a second time, as the
# next one, with its steps and frames counted twice.
d=$(ch_setup refusedtwice)
ch_plan "$d" "ionic=3 t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
_acct "$d" "$(ch_last_jid "$d")" 12000 12000
ch_chunk "$d"                                   # 4 nodes x 1 rank, 15000 MB/cpu
jid=$(ch_last_jid "$d")
ch_plan "$d" "ionic=2 t_ion=30 killjob=1"
ch_die "$d"
_acct "$d" "$jid" 15000 15000 OUT_OF_MEMORY OUT_OF_MEMORY
ch_run "$d" --resume >/dev/null 2>&1; rc1=$?
s1="$(ch_state "$d" chunk_index) $(ch_state "$d" nsw_done) $(grep -c 'Direct configuration' "$d/wolfpack_chain/XDATCAR.all")"
out=$(ch_run "$d" --resume 2>&1); rc2=$?
s2="$(ch_state "$d" chunk_index) $(ch_state "$d" nsw_done) $(grep -c 'Direct configuration' "$d/wolfpack_chain/XDATCAR.all")"
ok_if "(( rc1 != 0 && rc2 != 0 ))" "(setup) the escalation is refused both times (rc=$rc1, $rc2)"
ok_if "[[ '$s1' == '2 5 5' ]]" "the first --resume settles the dead chunk once: chunk 2, 3 + 2 = 5 steps, 5 frames (got: $s1)"
ok_if "[[ '$s2' == '$s1' && ! -d '$d/wolfpack_chain/chunk-003' ]]" \
      "a second --resume counts nothing again and invents no chunk 3 (got: $s2)"
ok_if "grep -q 'cannot be raised enough' <<<\"\$out\"" "and it reaches the same decision, for the same reason"

exit $(( FAIL_N > 0 ))
