# test_32_queue_study

> backfill-study: the queue wait, the run time, and a concrete --time

## 1. Definition

Feeds `backfill-study` (`backfill_study.py`) accounting histories whose best
answer is known in advance, and checks the parsing, the decision and its
fallbacks. Then it checks that `vasp-relax-loop` uses the result at launch, and
ignores it when told to. It runs `backfill-study` standing alone, and checks
that it reads a calculation folder exactly as the chain does. Finally it
replays a real case, a cell relaxation, before and while it runs: the queue
wait of the job as written, the step time (estimated, then measured), and the
`--time` to submit with.

## 2. Purpose

The chunk walltime trades two costs against each other:

- **short chunks** start sooner (a scheduler backfills short jobs into gaps),
  but a relaxation needs more of them, and each one waits in the queue again;
- **long chunks** mean fewer waits, but each wait is longer, since fewer gaps
  fit them.

Which one wins depends on the cluster, the partition, the job's shape and the
week. The profile's fixed default (`WP_CHUNK_WALLTIME_MIN`) cannot know that.
The partition's own accounting history does, so the chain now reads it and
proposes the walltime. When there is not enough data to decide, it falls back
to the profile's default and says so.

The test makes sure the study compares like with like, measures the wait
correctly, counts chunks as the chain would, and refuses to decide from too
little data.

## 3. How it is executed

```
tests/run_all.sh test_32_queue_study
```

The histories are written by the test itself, in `sacct --parsable2` format
with the fields the study asks for
(`JobID,Partition,Submit,Eligible,Start,State,Timelimit,TimelimitRaw,NNodes,NCPUS,ReqTRES,ReqMem`).
They are synthetic on purpose: the right answer is then arithmetic chosen here,
not something computed by the code under test. Sections 1–5 call the module
directly; section 6 runs the real `vasp_chain.sh` against the harness of
test_29, whose fake `sacct` serves the history; section 7 runs `backfill-study`
as a command, in a folder and with no folder. About 15 seconds.

## 4. Expected results

**The decision.** For each candidate walltime *W* the study counts the chunks
the chain would need, then estimates the time to finish:

```
T(W) = chunks(W) × (median wait of similar jobs at W + start-up) + steps × t_ionic
```

It proposes the *W* with the smallest T. `chunks(W)` is a replay of the chain's
own ramp: a calibration chunk of at most 3 steps, then a cap that may at most
double, up to what fits in *W* (`⌊T_work / (t_ionic × 1.15)⌋`).

| section | input | expected |
|---|---|---|
| 1 | `ReqMem` as `1000Mc` (per CPU), `48000Mn` (per node), `48000M` (job total) and `ReqTRES mem=46.875G`, for 48 CPUs on 1 node | all **48000 MB** |
| 1 | `TimelimitRaw 600`, `1-00:00:00`, `04:30:00`, `UNLIMITED` | 600, 1440, 270, none |
| 1 | a job held 10 h by a dependency, started 1 min after becoming eligible | a **60 s** wait: waits are counted from `Eligible`, not `Submit` |
| 2 | 12 jobs each at 1 h (waited 2 h), 2 h (waited 5 min), 4 h (waited 4 h); the job needs 20 steps of 25.6 s | 3 chunks at every candidate (3 + 6 + 11 ≥ 20), so the wait decides: **2 h** |
| 2 | — | similarity reported as `nodes + cores + memory` |
| 3 | only 64-core jobs in the history, for a 4-core job | similarity relaxed to `nodes`, and reported |
| 4 | 3 jobs per walltime | **no proposal** (`fallback`), with the reason "fewer than two …" |
| 4 | `MaxTime` 150 min | no candidate above 150; 150 itself is a candidate |
| 5 | the chain at 120 min, and the study at 120 min | the same time budget per chunk (6650 s); the chain's ramp at 60 min and 30 s per step: 3, 6, 11 → 3 chunks, steady cap 95 |
| 6 | launch with no `--walltime` | `#SBATCH --time=02:00:00`, `chain_wall_source = backfill-study`, the study shown and kept in `wolfpack_chain/backfill_study.txt` |
| 6 | no accounting data | profile default `01:00:00`; the state says why the study could not decide |
| 6 | `--no-queue-study` | profile default, no study file |
| 6 | `vasp-relax-loop --study` | refused, naming `backfill-study` |
| 7 | `backfill-study` in the folder, no option | the job as written (`--time=04:00:00`) waits **~4 h**; recommends the chain of **3 × 2-h chunks** (24 min in all), with the one-job alternative `--time=01:00:00` next to it |
| 7 | `--details` | adds the per-walltime table (`PROPOSED CHUNK : 2 h`) and where each input came from |
| 7 | the same folder through both programs, with `test_startup_s="10.4"` | backfill-study and the chain agree on the ionic step (25.6 s), steps, ranks, nodes, memory and walltime (120 min); the start-up is read as **10 s** |
| 7 | no folder, the job on the command line | the same 2 h |
| 7 | no folder and no options | exit 2: "not a calculation folder", and the options that describe the job instead |
| 7 | run in the toolkit's own directory, as it was first run on a real cluster | **one** message, not four; no false `NSW=0 in INCAR`; names `--nodes --cpus --mem-mb` (the partition comes from the profile) |
| 7 | a calculation folder with everything but its INCAR | the queue wait, a note that the INCAR is missing, no recommendation |
| 7 | a folder that does not exist | "no such folder" |
| 7 | by hand, no `--partition` | the profile's partition, and the output says so |
| 7 | by hand, all six given, too little data to decide | the fallback is the profile's 60 min, not a built-in 600 |
| 8a | a LaMnO3-shaped relaxation **before** launching (vasp-test only) | the job as written (7 days) waits **~36 min** (median of 10 similar week-long jobs); the step is labelled estimated, its 12 electronic steps per ionic step assumed; `--time=5-20:00:00`; the whole report in at most 25 lines |
| 8b | the same **while it runs** (19 ionic steps in its OUTCAR) | the step is **measured**, 55 min; `--time=5-07:00:00`, and 7 days is "more than the run can use"; the folder's job waited 12 min; 19 steps done |
| 8c | the script asks for 2 days | flagged: too little for all of NSW |
| 8d | no vasp-test and no run | the queue wait, and no recommendation |
| 8e | the real run as it was: 3.6-h measured steps, NSW 120 (497 h as one job, beyond the queue data) | the chain of **120-h** chunks recommended; and, since vasp-relax-loop sizes from vasp-test's 61-min estimate, the report says it would pick **96 h** — which launching it there confirms |

**Why "similar" matters.** A 1-node job and a 20-node job at the same walltime
wait very differently. The study first compares jobs that match on nodes (the
same band: 1, 2–4, 5–16, 17+), cores (within ×2) **and** memory (within ×3).
It drops one axis at a time (memory, then cores, then nodes, leaving the whole
partition) only when a level lacks at least 8 jobs in at least two candidate
walltimes, and reports the level it used.

## 5. Obtained results

All forty-five as expected. The study as the chain shows it at launch (section 6):

```
  walltime   fits?  steps/chunk  chunks   jobs   median    p75      p90     expected total
  --------------------------------------------------------------------------------------------
       1 h    yes         111        3      12      2.0h     2.0h     2.0h         6.2h
       2 h    yes         225        3      12      5.0m     5.0m     5.0m        24.0m  <
       4 h    yes         450        3      12      4.0h     4.0h     4.0h        12.2h

  PROPOSED CHUNK   : 2 h
  why              : smallest expected time to finish 20 ionic step(s): 3 chunk(s) x median
                     wait 5.0m (n=12, level: nodes + cores + memory)
```

(rows with no jobs omitted here). 24.0 min = 3 × (5 min + 10 s) + 20 × 25.6 s.

`backfill-study` has been its own command since 2026-09-24; the chain calls it
with its own numbers rather than letting it re-derive them, and section 7 is
what keeps the two readings of a folder identical.

One package bug was found by section 7 and fixed in `vasp_chain.sh`: vasp-test
writes its start-up time with a decimal (`test_startup_s="58.3"`), and the
chain's `int()` kept only the digits, reading **583 s**. Every chunk budget
lost ten times its start-up; the tests never saw it because their state files
held whole numbers. A negative control with the fix removed reads 104 for 10.4.

Three defects in `backfill-study`'s own messages were found when it was first
run by hand on a real cluster, in the toolkit's directory instead of a
calculation folder:

1. It printed four complaints for one cause. One of them was false: an absent
   INCAR was read as an empty one and reported as `NSW=0 in INCAR`.
2. The options it suggested were incomplete: `--steps` and `--partition` were
   missing from the list.
3. Given all six options by hand, it replaced the profile's chunk settings with
   built-in defaults (a 600-min fallback where the profile said 60).

Against the previous `backfill_study.py`, the six new cases fail on all but
one: the partition was already read from the profile when it was not given.

Then the same first real run showed what the command was missing. It printed
a 17-row table that was mostly empty. It labelled vasp-test's assumption in a
way that read as a claim about the user's 20-hour job, while ignoring that
job's OUTCAR, which held the real step time. And with too little queue data it
recommended nothing, not even the walltime the run needs. Section 8 is that
case. Against the version before this change, 25 of the 45 assertions fail. `wolfpack_queue.py` is standard-library only and Python 3.6+
(checked with `vermin`, not run: there is no 3.6 here). It runs on a login node,
inside the launcher, where the toolkit's conda environment may not be active.

## 6. Pass / fail criterion

Exact: parsed values, the chosen walltime, the chunk counts, the similarity
level, the fallback reason, and the `#SBATCH --time` line of the rendered
chunk. The histories use constant waits per walltime, so median, p75 and p90
coincide and no percentile convention can change the answer.

## 7. Verdict

**PASSED** — 48 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` fields `Submit`, `Eligible`, `Start`, `Timelimit`, `TimelimitRaw`,
  `ReqTRES`, `ReqMem`, and `--parsable2` —
  <https://slurm.schedmd.com/sacct.html>
- `Eligible` is when the job became eligible to run (after dependencies and
  holds) — <https://slurm.schedmd.com/sacct.html#OPT_Eligible>
- Backfill scheduling starts lower-priority jobs early only if they do not
  delay higher-priority ones — which depends on their time limit —
  <https://slurm.schedmd.com/sched_config.html>
