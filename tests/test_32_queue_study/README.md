# test_32_queue_study

> the chunk walltime chosen from what the queue did to jobs shaped like this one

## 1. Definition

Feeds `wolfpack_queue.py` accounting histories whose best answer is known in
advance, checks the parsing, the decision and its fallbacks, then checks that
`vasp-relax-loop` uses the result at launch, and ignores it when told to.

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
test_29, whose fake `sacct` serves the history. About 10 seconds.

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
| 6 | launch with no `--walltime` | `#SBATCH --time=02:00:00`, `chain_wall_source = queue study`, the study shown and kept in `wolfpack_chain/queue_study.txt` |
| 6 | no accounting data | profile default `01:00:00`; the state says why the study could not decide |
| 6 | `--no-queue-study` | profile default, no study file |
| 6 | `--study` | prints `PROPOSED CHUNK   : 2 h`, creates nothing, submits nothing |

**Why "similar" matters.** A 1-node job and a 20-node job at the same walltime
wait very differently. The study first compares jobs that match on nodes (the
same band: 1, 2–4, 5–16, 17+), cores (within ×2) **and** memory (within ×3).
It drops one axis at a time (memory, then cores, then nodes, leaving the whole
partition) only when a level lacks at least 8 jobs in at least two candidate
walltimes, and reports the level it used.

## 5. Obtained results

All nineteen as expected. The study as the chain shows it at launch (section 6):

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

The module is new in this change, so there is no earlier behaviour to compare
against. `wolfpack_queue.py` is standard-library only and Python 3.6+
(checked with `vermin`, not run: there is no 3.6 here). It runs on a login node,
inside the launcher, where the toolkit's conda environment may not be active.

## 6. Pass / fail criterion

Exact: parsed values, the chosen walltime, the chunk counts, the similarity
level, the fallback reason, and the `#SBATCH --time` line of the rendered
chunk. The histories use constant waits per walltime, so median, p75 and p90
coincide and no percentile convention can change the answer.

## 7. Verdict

**PASSED** — 19 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` fields `Submit`, `Eligible`, `Start`, `Timelimit`, `TimelimitRaw`,
  `ReqTRES`, `ReqMem`, and `--parsable2` —
  <https://slurm.schedmd.com/sacct.html>
- `Eligible` is when the job became eligible to run (after dependencies and
  holds) — <https://slurm.schedmd.com/sacct.html#OPT_Eligible>
- Backfill scheduling starts lower-priority jobs early only if they do not
  delay higher-priority ones — which depends on their time limit —
  <https://slurm.schedmd.com/sched_config.html>
