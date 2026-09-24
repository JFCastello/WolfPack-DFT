#!/usr/bin/env bash
# test_29_chain_memory -- the chain measures memory after every chunk and
# rewrites the next chunk's allocation from it.
#
# Until this, a chain took --mem-per-cpu once, from slurm_vasptest.sh, and
# kept it for every chunk: it timed each chunk carefully and never once looked
# at how much memory it used. A request too small killed every chunk the same
# way; one too large paid for itself in queue time on every resubmission.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/chainmem"; rm -rf "$W"; mkdir -p "$W"
source "$SUITE_DIR/chain_harness.sh"

# sacct rows for one finished chunk: the allocation line, then the srun step
_acct(){ ch_sacct "$1" "$2" "$2|RUNNING||" "$2.batch|RUNNING||" "$2.0|COMPLETED|${3}M|${4}M"; }

# ===========================================================================
# 1. SHRINK: a request larger than the measurement comes down to it
# ===========================================================================
# The cluster profile gives 8-core nodes of 16000 MB; the chain starts at
# 2000 MB/cpu, 1 node x 4 ranks (slurm_vasptest.sh).
d=$(ch_setup shrink)
# NSW = 60, not the harness's 20: this chain must still be RUNNING at its third
# chunk (caps 3 + 6 + 11 = 20 would spend NSW there, and a chain that stops
# sizes no next chunk -- section 3 would then pass without testing anything).
sed -i 's/^NSW .*/NSW    = 60/' "$d/INCAR"
ch_plan "$d" "ionic=3 t_ion=30"
ch_run "$d" --walltime 60 >/dev/null 2>&1
ok_if "[[ '$(ch_job "$d" mem-per-cpu)' == 2000 ]]" \
      "chunk 1 runs with slurm_vasptest.sh's allocation (2000 MB/cpu)"
_acct "$d" "$(ch_last_jid "$d")" 1500 1000
ch_chunk "$d"
# The rule, from the node-total limit SLURM enforces (cgroup.conf(5),
# ConstrainRAMSpace): the heaviest node holds rank 0 (max) plus the rest at
# the mean, shared by ntpn CPUs, with 25 % headroom:
#     (1500 + 3 x 1000) / 4 x 1.25 = 1406 -> 1450 (rounded up to 50)
ok_if "[[ '$(ch_job "$d" mem-per-cpu)' == 1450 ]]" \
      "the next chunk's request is rewritten from the measurement: 2000 -> $(ch_job "$d" mem-per-cpu) MB/cpu (expected 1450)"
ok_if "[[ '$(ch_state "$d" chain_mem_per_cpu)' == 1450 ]]" "and recorded in the chain's state"
# A relaxation reports IONIC progress against NSW. It used to print electronic
# steps over NELM ("25/60 steps"), which reads as ionic progress and is not.
# grep -qs on the files, not cat | grep: under pipefail a cat that misses one
# glob fails the pipeline even when grep found the line. -q returns 0 on a
# match whatever errors it met on the way.
ok_if "grep -qs 'not converged yet (3 ionic step(s) in this chunk, 3 of 60 done)' '$d'/VASP-chain-*.out '$d'/wolfpack_chain/chunk-*/VASP-chain-*.out" \
      "the chunk reports ionic steps against NSW (3 in this chunk, 3 of 60)"
ok_if "grep -qE '^  1 .* 1500 +2000 CONTINUE' '$d/wolfpack_chain/chain.log'" \
      "chain.log shows what the chunk used next to what it was granted (1500 of 2000)"

# ===========================================================================
# 2. GROW, and SPREAD when one node can no longer hold the ranks
# ===========================================================================
# peak 5000 / mean 4000 at 4 ranks per node needs 5350 MB/cpu -> 21400 MB on
# a node with 15680 usable. Two ranks per node fit; the rank count does not
# change (KPAR/NCORE were chosen for it), so 2 nodes x 2 ranks, recomputed at
# ntpn=2:  (5000 + 4000)/2 x 1.25 = 5625 -> 5650.
ch_plan "$d" "ionic=6 t_ion=30"
_acct "$d" "$(ch_last_jid "$d")" 5000 4000
ch_chunk "$d"
ok_if "[[ '$(ch_job "$d" nodes)' == 2 && '$(ch_job "$d" ntasks-per-node)' == 2 ]]" \
      "when a node cannot hold the ranks they spread: $(ch_job "$d" nodes) node(s) x $(ch_job "$d" ntasks-per-node) per node (expected 2 x 2)"
ok_if "[[ '$(ch_job "$d" ntasks)' == 4 ]]" "the rank count is unchanged (4), so the INCAR's KPAR/NCORE still hold"
ok_if "[[ '$(ch_job "$d" mem-per-cpu)' == 5650 ]]" \
      "the request is recomputed for the new ranks-per-node: $(ch_job "$d" mem-per-cpu) (expected 5650)"

# ===========================================================================
# 3. THE LARGEST PEAK IS NEVER FORGOTTEN
# ===========================================================================
# A quiet chunk must not talk the request down below what an earlier chunk
# needed: VASP's peak depends on the step, and the next step can be the heavy
# one again.
ch_plan "$d" "ionic=6 t_ion=30"
_acct "$d" "$(ch_last_jid "$d")" 1000 800
ch_chunk "$d"
ok_if "grep -qE '^  3 .* CONTINUE' '$d/wolfpack_chain/chain.log'" \
      "(setup) chunk 3 continued, so the chain did size a chunk 4"
ok_if "[[ '$(ch_job "$d" mem-per-cpu)' == 5650 ]]" \
      "a lighter chunk (1000 MB) does not undercut the largest peak seen (request stays $(ch_job "$d" mem-per-cpu))"
ok_if "[[ '$(ch_state "$d" mem_peak_max_mb)' == 5000 ]]" "the largest peak is kept in the state (5000)"

# ===========================================================================
# 4. NO ACCOUNTING: VASP's own footer
# ===========================================================================
# Some clusters' accounting records the steps but no RSS -- this suite's own
# testbed does. The chain falls back to OUTCAR's "Maximum memory used (kb)", which
# is rank 0 (normally the heaviest), and then assumes EVERY rank is that heavy,
# which errs toward more.   2048 MB x 1.25 = 2560.
d2=$(ch_setup outcar)
ch_plan "$d2" "ionic=3 t_ion=30 maxmem_kb=2097152"
ch_run "$d2" --walltime 60 >/dev/null 2>&1
t0=$SECONDS; ch_chunk "$d2"; dt=$(( SECONDS - t0 ))
ok_if "[[ '$(ch_job "$d2" mem-per-cpu)' == 2600 ]]" \
      "with no sacct data, OUTCAR's peak sizes the request: $(ch_job "$d2" mem-per-cpu) (expected 2560 -> 2600)"
ok_if "grep -q 'OUTCAR' '$d2/VASP-chain-$(( $(ch_last_jid "$d2") - 1 )).out'" \
      "and the chunk says the number came from OUTCAR, not accounting"
# The steps are finished and carry no RSS: that answer is final. The chain used
# to poll sacct for 45 s regardless, on every chunk.
ok_if "(( dt < 30 ))" "it does not sit out a 45-s sacct poll for RSS that will never come (${dt} s)"

# ===========================================================================
# 5. A CELL THAT GROWS NEEDS MORE
# ===========================================================================
# ISIF=3 relaxes the cell. At fixed ENCUT the plane-wave count grows with the
# volume, so a cell that grew by x needs about x more for its wavefunctions.
# The fake VASP stretches the lattice by 1 % per ionic step: 3 steps -> 3.03 %
# in length, 9.3 % in volume.
d3=$(ch_setup isif3 3)
ch_plan "$d3" "ionic=3 t_ion=30 vscale=1.01"
ch_run "$d3" --walltime 60 >/dev/null 2>&1
_acct "$d3" "$(ch_last_jid "$d3")" 2000 2000
ch_chunk "$d3"
# 2000 x 1.25 = 2500 at constant volume; x 1.0927 = 2732 -> 2750
got=$(ch_job "$d3" mem-per-cpu)
ok_if "[[ '$got' == 2750 ]]" "a cell that grew 9.3 % in volume is given 9.3 % more (${got}, expected 2750; 2500 without the growth)"

# ===========================================================================
# 6. MEMORY THAT CANNOT BE HAD STOPS THE CHAIN, BEFORE A CHUNK IS WASTED
# ===========================================================================
# One rank needing more than a whole node offers cannot be placed anywhere.
# Submitting it would be a chunk that dies on arrival.
d4=$(ch_setup toobig)
ch_plan "$d4" "ionic=3 t_ion=30"
ch_run "$d4" --walltime 60 >/dev/null 2>&1
_acct "$d4" "$(ch_last_jid "$d4")" 20000 20000
before=$(ch_nsub "$d4")
ch_chunk "$d4"
ok_if "[[ '$(ch_state "$d4" stop_reason)' == memory_does_not_fit ]]" \
      "a rank larger than a node stops the chain (reason: $(ch_state "$d4" stop_reason))"
ok_if "[[ '$(ch_nsub "$d4")' == '$before' ]]" "and no successor is submitted"
ok_if "grep -qi 'one rank alone needs' '$d4/wolfpack_chain/STOPPED'" "the stop says why, in numbers"
ok_if "cmp -s '$d4/CONTCAR' '$d4/POSCAR'" \
      "the chunk that measured it ran to completion, and its geometry is kept (CONTCAR -> POSCAR)"
ok_if "grep -q 'cannot continue this chain on this partition' '$d4/wolfpack_chain/STOPPED' && grep -q 'KPAR' '$d4/wolfpack_chain/STOPPED'" \
      "the stop says --resume cannot fix it here, and what frees memory"
# --resume must not submit the old, measured-too-small allocation.
out=$(ch_run "$d4" --resume 2>&1); rc=$?
ok_if "(( rc != 0 )) && grep -q 'still does not fit' <<<\"\$out\" && [[ '$(ch_nsub "$d4")' == '$before' ]]" \
      "--resume refuses and submits nothing, rather than a chunk below the measured need (rc=$rc)"
# On a profile with bigger nodes the same measurement fits:
#   (20000 + 3 x 20000)/4 x 1.25 = 25000 MB/cpu;  4 x 25000 on a 125440-MB node
sed -i 's/WP_MAIN_MEM_PER_NODE_MB="16000"/WP_MAIN_MEM_PER_NODE_MB="128000"/' "$W/toobig.fake/cluster.conf"
ch_run "$d4" --resume >/dev/null 2>&1; rc=$?
ok_if "(( rc == 0 )) && [[ '$(ch_job "$d4" mem-per-cpu)' == 25000 && '$(ch_job "$d4" nodes)' == 1 ]]" \
      "on bigger nodes --resume continues at the measured need: $(ch_job "$d4" nodes) x $(ch_job "$d4" mem-per-cpu) (expected 1 x 25000)"

# ===========================================================================
# 7. THE MEASURED ALLOCATION SURVIVES A --stop / --resume
# ===========================================================================
# --resume re-renders the chunk's job script. It used to re-read
# slurm_vasptest.sh while doing so, which threw away everything the chain had
# measured and went back to the allocation it started with.
ch_run "$d" --stop >/dev/null 2>&1
ch_plan "$d" "ionic=6 t_ion=30"
_acct "$d" "$(ch_last_jid "$d")" 1000 800
ch_chunk "$d"
ch_run "$d" --resume >/dev/null 2>&1
ok_if "[[ '$(ch_job "$d" mem-per-cpu)' == 5650 && '$(ch_job "$d" nodes)' == 2 ]]" \
      "after --stop and --resume the chain keeps its measured allocation ($(ch_job "$d" nodes) x $(ch_job "$d" mem-per-cpu)), not slurm_vasptest.sh's 1 x 2000"

exit $(( FAIL_N > 0 ))
