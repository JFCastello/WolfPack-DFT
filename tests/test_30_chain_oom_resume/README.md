# test_30_chain_oom_resume

> after an OOM kill, `vasp-relax-loop --resume` alone continues, with more memory

## 1. Definition

Kills chunks of a chunked relaxation by running out of memory, in both of the
ways that happens on a real cluster, then runs `vasp-relax-loop --resume`, with
no other arguments, and checks what the chain does next.

## 2. Purpose

A chunk that dies of memory used to leave the user with three jobs to do by
hand: find which job script to edit, raise its memory, and put the geometry the
dead chunk had reached back in place. The chain now does all three itself on
`--resume`. This test pins down that it does, and that it does not do the wrong
thing on the way:

- count the dead chunk's steps twice, or not at all;
- restart from the old geometry and silently redo the steps;
- read a WAVECAR that was cut off while being written;
- start a second chunk next to one still running;
- keep asking for more memory than any node has;
- start a new chain on top of an unfinished one.

A chunk can die of memory in two ways, and the test covers both:

| | what dies | who does the bookkeeping |
|---|---|---|
| **step OOM** | the `srun` step; the batch script survives | the chunk's own body, which records `stop_reason=oom` |
| **job death** | the whole job, body included | nobody — the state still says `running`; `--resume` has to do it |

## 3. How it is executed

```
tests/run_all.sh test_30_chain_oom_resume
```

Same harness as test_29 (`tests/chain_harness.sh`): a fake scheduler and a fake
VASP, with the real `vasp_chain.sh`. For a job death the fake VASP runs its
steps and then kills the chunk body that launched it, as happens when the
OOM killer or a job-level kill takes the batch shell too. The body's edits
before VASP starts are therefore real, and its bookkeeping after VASP never
happens. The fake `sacct` answers with the `OUT_OF_MEMORY` states
and the fake stderr carries `slurmstepd`'s own wording. About 30 seconds.

## 4. Expected results

| section | situation | expected |
|---|---|---|
| A | step OOM in chunk 2 after 2 steps, granted 1450 | `stop_reason=oom`; no successor; `STOPPED` names `vasp-relax-loop --resume` and says the memory will be raised |
| A | `--resume` | exit 0; memory 1450 × 1.5 = **2200**; CONTCAR → POSCAR; steps 3 + 2 = **5**; one new chunk; the stop record filed in `chunk-002/`; messages name `vasp-relax-loop`, not `vasp_chain.sh` |
| B | job death in chunk 2 after 4 steps | `--resume` archives it as `chunk-002/`, counts **4** steps from its OSZICAR (total **7**), adds its **4** frames to `XDATCAR.all` (total 7), logs `DIED` in `chain.log`, files the job's own `.err` with it; no shell error printed on the way |
| C | chunk **1** dies with its job | `chunk-001/POSCAR.in.gz` is still the original geometry |
| D | a second OOM | memory raised again; `oom_count = 2` |
| E | escalation beyond what a node holds (15000 → 22500 MB, node 15680 usable) | refused (exit ≠ 0), names KPAR as the way out, nothing submitted |
| F | `--resume` while the last chunk is still in `squeue` | refused, nothing submitted |
| G | job death while writing WAVECAR (half the size of the last good one) | set aside as `WAVECAR.partial`; the next chunk runs with `ISTART=0 ICHARG=2`; the one after is warm again |
| H | plain start on an unfinished chain | refused, pointing at `--resume`; `--fresh` archives the old chain to `wolfpack_chain.prev-*` and starts from clean state |
| I | job death, escalation refused, `--resume` run **again** | the second run counts nothing again: still chunk 2, 5 steps, 5 frames, no `chunk-003`; same refusal |

**The escalation rule.** An OOM kill says the need was above the grant, never
by how much. The new request is the larger of the grant × 1.5
(`WP_CHAIN_OOM_FACTOR`) and what the measured peak and mean say the heaviest
node needs (the rule of test_29). The number of ranks is never changed, since the
INCAR's KPAR and NCORE were chosen for it. When a node can no longer hold them
they are spread over more nodes; when one rank alone needs more than a node,
the chain refuses.

**Why a partial WAVECAR is detected by its size.** VASP writes WAVECAR once, at
the end of a run, so a chunk killed mid-run leaves the previous chunk's file
untouched, which is correct for a restart. A WAVECAR newer than the dead
chunk's submission, whose size differs from the last good one, was cut off
while being written. A cold start costs one chunk a few extra electronic steps.
Reading a truncated WAVECAR kills that chunk, and every resume after it.

## 5. Obtained results

All thirty-nine as expected. The resume after the job death in section B:

```
== Resuming -- what the last chunk left behind ==
  last chunk                   job 1001
  how it ended                 oom  (peak 1500 MB/rank measured)
  settled                      chunk 2: 4 ionic step(s) counted and archived in wolfpack_chain/chunk-002/
  [ OK ] geometry advanced to the last completed ionic step (CONTCAR -> POSCAR)
  [ OK ] memory raised 1450 -> 2200 MB/cpu (the last chunk was OOM-killed at 1450)
==> resuming at chunk 3
```

and the refusal in section E:

```
  [FAIL] the memory cannot be raised enough to continue: one rank alone needs
   22500 MB, and a node offers 15680 MB after its margin.
   What frees memory, in order: a lower KPAR in the INCAR (each k-point group
   keeps its own copy of the charge density and grids), fewer ranks, LREAL = Auto.
   Then start over with --fresh.
```

Package bugs found by this test and fixed in `vasp_chain.sh`:

1. `STOPPED` told a relaxation to run `vasp-scf-loop --resume`.
2. `--resume` did not check for a live chunk (only a fresh start did), so it
   could put a second VASP into the folder of a running one (section F).
3. A refused `--resume` left the chain marked `running`. Run again, it archived
   the same dead chunk a second time as chunk 3, with its steps and frames
   counted twice (section I). A negative control, run with the fix removed,
   gave `3 7 7` where `2 5 5` is right.
4. Every `--resume` after a job death printed
   `wolfpack_chain/RUNNING: No such file or directory`. The `2>/dev/null` came
   after the `<` redirection that failed, and bash applies redirections left
   to right.

## 6. Pass / fail criterion

Exact: the step counts, frame counts, chunk numbers, memory values and exit
codes above, and byte-for-byte file comparisons for the geometry (`cmp`). The
×1.5 is computed in the test from the value the chain was granted, not read
back from the chain.

## 7. Verdict

**PASSED** — 39 assertions, 0 failed. See `logs/run.log`.

## Sources

- SLURM's OOM wording (`oom_kill event`, `Out Of Memory`) and the
  `OUT_OF_MEMORY` job state — <https://slurm.schedmd.com/sacct.html#SECTION_JOB-STATE-CODES>
- The memory limit is on the job's cgroup as a whole (`ConstrainRAMSpace`:
  "constrain the job's RAM usage"), and the chain's body shares that cgroup
  with VASP, so the kernel's OOM killer can take either —
  <https://slurm.schedmd.com/cgroup.conf.html>
- VASP writes WAVECAR at the end of the run (`LWAVE`) —
  <https://vasp.at/wiki/LWAVE>; restarting from it with `ISTART = 1` —
  <https://vasp.at/wiki/ISTART>; `ISTART = 0`, `ICHARG = 2` is a start from
  scratch — <https://vasp.at/wiki/ICHARG>
- CONTCAR is written after every ionic step — <https://vasp.at/wiki/CONTCAR>
- KPAR groups each keep a copy of the charge density —
  <https://vasp.at/wiki/Optimizing_the_parallelization>
