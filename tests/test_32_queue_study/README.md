# test_32_queue_study

> backfill-study: how long a job waits, and the chunk walltime the chain takes from it

## 1. Definition

Feeds `backfill-study` (`backfill_study.py`) accounting histories whose right
answer is known in advance. It checks the parsing, the queue wait it reports
for a job, and the chunk walltime it returns to `vasp-relax-loop`. Then it
launches the chain against the same histories, to check that the chain takes
that walltime.

## 2. Purpose

`backfill-study` answers one question: how long does a job of this shape wait
in this queue, at the walltime it asks for and at others. It measures what the
scheduler did (backfill included) to similar jobs; it does not simulate it.

`vasp-relax-loop` uses the same numbers at launch. The chain estimates its
ionic-step time from `vasp-test`'s measurements, which is its own job and not
repeated in `backfill-study`. It hands that time over and gets back the chunk
walltime with the shortest `chunks × (median wait + start-up)`.

The test makes sure the waits are measured correctly (from `Eligible`, like
with like), that the comparison relaxes and says so when data is thin, and
that too little data gives no answer rather than a guess. It also checks that
the chain really runs with what `backfill-study` chose.

## 3. How it is executed

```
tests/run_all.sh test_32_queue_study
```

The histories are written by the test itself, in `sacct --parsable2` format,
so the right answer is arithmetic chosen here, not computed by the code under
test. The chain runs against the fake scheduler of `tests/chain_harness.sh`.
About 20 seconds.

## 4. Expected results

| section | input | expected |
|---|---|---|
| 1 | `ReqMem` as `1000Mc`, `48000Mn`, `48000M`, and `ReqTRES mem=46.875G`, for 48 CPUs on 1 node | all **48000 MB** |
| 1 | `TimelimitRaw 600`, `1-00:00:00`, `04:30:00`, `UNLIMITED` | 600, 1440, 270, none |
| 1 | a job held 10 h by a dependency, started 1 min after becoming eligible | a **60 s** wait |
| 2 | 12 jobs each at 1 h (waited 2 h), 2 h (5 min), 4 h (4 h); the chain's step 25.6 s, 20 steps | 3 chunks at every walltime, so the wait decides: **2 h** |
| 3 | only 64-core jobs, for a 4-core job | similarity relaxed to `nodes`, and reported |
| 4 | 3 jobs per walltime | no proposal, and why; `MaxTime` 150 bounds the candidates and is one |
| 5 | the chain at 120 min | the same time budget per chunk (6650 s) and the same ramp (3, 6, 11) as the chain |
| 6 | the chain launched with no `--walltime` | `#SBATCH --time=02:00:00`, source `backfill-study`, the table kept in `wolfpack_chain/backfill_study.txt`; with no data, the profile's 1 h; `--no-queue-study` skips it; `--study` points at `backfill-study` |
| 7 | `backfill-study` in the folder (4 ranks, 8 GB, `--time=04:00:00`) | in a sentence: about **2.0 h**, from the 24 jobs of its size that asked 1 to 4 h; the table by broad band: up to 1 h **2.0 h** (12 jobs), 1 to 4 h **2.0 h** / 4.0 h (24); "your size" spelled out (1 node, 2–8 cores, 3–23 GB); no run-time estimate and no recommendation; nothing created or submitted |
| 7 | `test_startup_s="10.4"` | the chain reads **10 s**, not 104, and takes backfill-study's 2 h |
| 7 | the job on the command line, no folder | the same 2.0 h; without `--partition`, the profile's |
| 7 | no folder and no options; the toolkit's own directory; a folder that does not exist | one message each: not a calculation folder (naming `--nodes --cpus --mem-mb`), or no such folder |
| 7 | `--machine`, the chain's call | its step estimate in, **2 h** out; with too little data the profile's 60 min; without the step estimate, refused |
| 8 | the LaMnO3 relaxation (1 × 56 ranks, 46 GB, 7 days; 76 short 4-core jobs and 10 similar week-long jobs that waited 35–37 min) | about **36 min**, from the 10 jobs of its size that asked 4 to 7 days; the folder's own job waited 12 min; the 4-core jobs are not in the table; at most 15 lines |
| 8b | Santos Dumont: 1 × 48 cores, 73 GB, 7 days, where nobody asked for more than 4 days; `scontrol` shows no MaxTime | "MaxTime: not shown by scontrol"; "No job asked for more than 4 days … yours asks for 7 days", the commands that show the limit, and **no** wait borrowed from the 4-day jobs |
| 8b | the same with MaxTime 4 days | "more than the partition's MaxTime of 4 days: it will not start"; the table 60 s, 3.3 h, 31.7 h |
| 8 | the LaMnO3 folder without vasp-test's data | the same queue report: it never needed it |
| 8 | `vasp-relax-loop` launched there | its step estimate (263 s × 12 × 1.15) → **96-h** chunks from backfill-study |

## 5. Obtained results

All forty-five as expected. The Santos Dumont case, as it now reads:

```
YOUR JOB
  No job on fakepart asked for more than 4 days in the last 30 days; yours asks for 7 days.
  If that is the partition's limit, this job will not start. Check:
      scontrol show partition fakepart | grep -o 'MaxTime=[^ ]*'
      sacctmgr show qos format=name,maxwall

HOW LONG JOBS OF YOUR SIZE WAITED, BY THE WALLTIME THEY ASKED FOR
  asked for           half started within   9 in 10 within   jobs
  1 to 4 h                           60 s             60 s     20
  4 to 12 h                         3.3 h            3.3 h     20
  2 to 4 days                      31.7 h           31.7 h     20
  your size = 1 node, 24-96 cores, 24-219 GB. Bands with fewer than 8 such jobs are not shown.
```

**Made readable on 2026-09-24.** A user found the per-walltime table obscure:
fifteen fine rows, each compared its own way ("your size" beside "your node
count"), 3-job rows next to 281-job ones, three percentile columns. It now
opens with the job in sentences, followed by broad bands, one comparison for
the whole table spelled out in numbers, at least 8 jobs a row, and two
columns. It also stopped borrowing the 4-day jobs' wait for a 7-day job, and
it names a MaxTime it cannot read. Against the previous version, 13 of the 45
assertions fail.

**Simplified on 2026-09-24.** `backfill-study` had grown a second job: a copy
of the chain's step estimate, readings of a run's OUTCAR, a one-job-or-chain
recommendation, and a note on what the chain would pick. All of that repeated
what `vasp-relax-loop` does at launch, and a test existed only to keep the two
copies equal. It is gone. The step estimate now lives in one place, the chain,
and `backfill-study` reports the queue.

Package bugs found along the way and fixed: the chain read vasp-test's
start-up time "58.3" as 583 s (its `int()` stripped the point); a folder that
was not a calculation got four complaints, one of them false (`NSW=0 in INCAR`
with no INCAR); and the per-walltime table filled ranges that had no jobs
with their neighbours' waits.

## 6. Pass / fail criterion

Exact: parsed values, waits, the chosen walltime, chunk counts, similarity
levels, and the `#SBATCH --time` of the rendered chunk. The histories use
constant waits per walltime (or 35–37 min), so no percentile convention can
change the answer.

## 7. Verdict

**PASSED** — 45 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` fields `Submit`, `Eligible`, `Start`, `Timelimit`, `TimelimitRaw`,
  `ReqTRES`, `ReqMem`, and `--parsable2` —
  <https://slurm.schedmd.com/sacct.html>
- `Eligible` is when the job became eligible to run (after dependencies and
  holds) — <https://slurm.schedmd.com/sacct.html#OPT_Eligible>
- Backfill scheduling starts lower-priority jobs early only if they do not
  delay higher-priority ones — which depends on their time limit —
  <https://slurm.schedmd.com/sched_config.html>
