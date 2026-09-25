# test_32_queue_study

> backfill-study: how long a job waits, predicted with your fairshare, your fairshare now, and the chunk walltime the chain takes from it

## 1. Definition

Feeds `backfill-study` (`backfill_study.py`) accounting histories whose right
answer is known in advance. It checks the parsing, the queue wait it reports
for a job, and the chunk walltime it returns to `vasp-relax-loop`. Then it
launches the chain against the same histories, to check that the chain takes
that walltime. Last, it feeds the fairshare section and the prediction
scheduler answers (`scontrol show config`, `sshare`, `sprio`) whose numbers
are worked out by hand.

## 2. Purpose

`backfill-study` answers one question: how long does a job of this shape wait
in this queue, at the walltime it asks for and at others. It measures what the
scheduler did (backfill included) to similar jobs; it does not simulate it.

`vasp-relax-loop` uses the same numbers at launch. The chain estimates its
ionic-step time from `vasp-test`'s measurements, which is its own job and not
repeated in `backfill-study`. It hands that time over and gets back the chunk
walltime with the shortest `chunks × (median wait + start-up)`.

Past waits are everyone's. What orders the pending jobs today is their
priority, and the user's part of it is their fairshare, so the report ends
with it: data from the scheduler, in SLURM's own definitions. A number read
wrongly there (a factor, a count of jobs above yours) would be acted on.

The prediction joins the two. It takes the table's column for the job's
walltime and keeps the jobs whose owners' fairshare today is closest to the
user's: within 0.05, then 0.10, 0.20, 0.30, until there are 8. That is a
measurement, not a model. If fairshare orders the queue, those jobs waited as
this one will. If it does not, they are a sample of the column and say the
same. The test checks that the right jobs are picked, that the window widens
only when it must, and that when fairshare cannot be used the prediction falls
back to the column and says why.

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
| 7 | `backfill-study` in the folder (4 ranks, 8 GB, `--time=04:00:00`) | "Predicted wait: about **2.0 h** (Q1 5 min, Q3 4.0 h)", from the 24 jobs of its size that asked 1 to 4 h, and why fairshare was not used (no `sshare` here); the table with the quartiles down and the bands across: 0-1 h **2.0 / 2.0 / 2.0 h** (12 jobs), 1-4 h **5 min / 2.0 h / 4.0 h** (24); "your size" spelled out (1 node, 2–8 cores, 3–23 GB); no run-time estimate and no recommendation; nothing created or submitted |
| 7 | `test_startup_s="10.4"` | the chain reads **10 s**, not 104, and takes backfill-study's 2 h |
| 7 | the job on the command line, no folder | the same 2.0 h; without `--partition`, the profile's |
| 7 | no folder and no options; the toolkit's own directory; a folder that does not exist | one message each: not a calculation folder (naming `--nodes --cpus --mem-mb`), or no such folder |
| 7 | `--machine`, the chain's call | its step estimate in, **2 h** out; with too little data the profile's 60 min; without the step estimate, refused |
| 8 | the LaMnO3 relaxation (1 × 56 ranks, 46 GB, 7 days; 76 short 4-core jobs and 10 similar week-long jobs that waited 35–37 min) | about **36 min**, from the 10 jobs of its size that asked 4 to 7 days; one column 4-7 d: **35 / 36 / 37 min**, 10 jobs; the folder's own job waited 12 min; the 4-core jobs are not in the table; at most 21 lines, fairshare included |
| 8b | Santos Dumont: 1 × 48 cores, 73 GB, 7 days, where nobody asked for more than 4 days; `scontrol` shows no MaxTime | "MaxTime: not shown by scontrol"; "No job asked for more than 4 days … yours asks for 7 days", the commands that show the limit, and **no** wait borrowed from the 4-day jobs |
| 8b | the same with MaxTime 4 days | "more than the partition's MaxTime of 4 days: it will not start"; the median row 60 s, 3.3 h, 31.7 h under 1-4 h, 4-12 h, 2-4 d |
| 8 | the LaMnO3 folder without vasp-test's data | the same queue report: it never needed it |
| 8 | `vasp-relax-loop` launched there | its step estimate (263 s × 12 × 1.15) → **96-h** chunks from backfill-study |
| 9 | Fair Tree; weights fairshare 5000, age 2000 over 14 days; alice in fisica, factor 0.420 | the factor and "1.000 is the top-ranked user"; **5 of 6** associations above; fisica 25.0 % of the shares / 31.0 % of the use, alice 20.0 % / 53.7 %; the weights; **2100** points, and 0.1 of factor = 500 points = **3.5 days** of waiting (2000/14 a day) |
| 9 | 6 pending jobs of 4 users; hers at priority 3321 and 2000 | **2** carry more fairshare points than her 2100 (4900, 3100; not 1500 × 2); **3** and **5** pending jobs above her two; usage halves after 3 days |
| 9 | `PriorityFlags=NO_FAIR_TREE` | "(classic)", "0.500 exactly your share", normalized shares 0.2000 against effective usage 0.5373 |
| 9 | fairshare weight 0; `priority/basic` | "does not change priority here", and no points claimed; "FIFO; there is no fairshare", and no factor |
| 9 | `sshare` and `sprio` showing only her own rows (PrivateData) | "not visible", "sprio lists only your own jobs": hidden, not counted as zero |
| 9 | two accounts | `--account quimica` gives quimica's 0.950; without it, her default from `sacctmgr` (fisica, 0.420) and a note naming both |
| 9 | no scheduler to ask; `--no-fairshare`; the chain's `--machine` call | one line saying why; the section left out; the chain's answer without it |
| 10 | a 3-h job; its column has 33 jobs: carla (0.90) 10 × 1 min, eva (0.60) 3 × 30 min, beto (0.45) 10 × 3 h, dani (0.10) 10 × 10 h; the column 60 s / **3.0 h** / 10.0 h | alice at 0.85: **60 s**, from carla's 10 jobs, "by 1 user", next to the column's 3.0 h; the table unchanged |
| 10 | alice at 0.60; at 0.275 | eva's 3 are too few, so it widens to 0.20: eva + beto, 13 jobs, **3.0 h**; at 0.275, beto + dani, 20 jobs, **6.5 h** ((3 h + 10 h)/2), Q1 3.0 h, Q3 10.0 h |
| 10 | 8 of alice's own jobs (20 min each); alice at 0.75, then 0.45 | alone in the 0.05 window: **20 min**, "from 8 of your own jobs", next to the column's 30 min; at 0.45 with beto: **3.0 h** (Q1 20 min), "you among them" |
| 10 | too few near her; owners hidden; weight 0; `--no-fairshare`; no `sshare` | the column's answer every time (10.0 h, 3.0 h, …), each with its reason after "Fairshare not used:" |

## 5. Obtained results

All seventy-six as expected. Case 10 at 0.85, as it reads:

```
YOUR JOB
  Predicted wait: about 60 s   (Q1 60 s, Q3 60 s)
  from 10 jobs of your size that asked for 1 to 4 h, by 1 user, whose fairshare
  today is 0.90 (yours 0.850). All 33 such jobs, any fairshare: about 3.0 h.
```

**The prediction, 2026-09-24.** The user asked for a queue-time prediction
that uses both the fairshare and the table. It is the table's column narrowed
to the jobs of users with a fairshare like the user's (above). `sacct` records
a job's priority, but the value it keeps for a finished job includes the age
it gathered while waiting, so it is tangled with the very wait being
predicted, and it was not used. The report also says when the jobs it used are
the user's own, and "1 of the 5 … has". On their first run two new assertions
failed, both my own arithmetic; see NOTES. Against the previous version, 16 of
the 76 fail.

**Quartiles and fairshare, 2026-09-24.** The user asked for the quartiles down
the table and for an analysis of the current fairshare. The table now has Q1,
Q2 (the median) and Q3 as rows and one column per walltime band; the sentence
gives the same three numbers. The fairshare section is new. On its first run
one assertion failed, and it was a package bug: with a fairshare weight of 0
the report still said "4 carry more fairshare points than yours", counting
points that weigh nothing. That clause now needs a weight above 0. Against the
previous version, 19 of the 63 assertions fail.

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
change the answer. The quartiles are the linear-interpolation ones, and the
test's comments work them out rank by rank. The fairshare lines are exact too:
the factor, the counts, the percentages, the points and the days, each
against the arithmetic in the check's comments.

## 7. Verdict

**PASSED** — 76 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` fields `Submit`, `Eligible`, `Start`, `Timelimit`, `TimelimitRaw`,
  `ReqTRES`, `ReqMem`, `User`, `Account`, `Priority` ("Slurm priority", with
  no statement of when it is taken), and `--parsable2` —
  <https://slurm.schedmd.com/sacct.html>
- `Eligible` is when the job became eligible to run (after dependencies and
  holds) — <https://slurm.schedmd.com/sacct.html#OPT_Eligible>
- Backfill scheduling starts lower-priority jobs early only if they do not
  delay higher-priority ones — which depends on their time limit —
  <https://slurm.schedmd.com/sched_config.html>
- Job priority = sum of weight × factor, each factor in [0, 1]; the age factor
  maxes out at `PriorityMaxAge` (default 7 days); `PriorityDecayHalfLife`;
  Fair Tree the default since 19.05 —
  <https://slurm.schedmd.com/priority_multifactor.html>
- Fair Tree: the factor is the user's rank over the number of user
  associations, 1.0 the top one; LevelFS = shares / usage among siblings —
  <https://slurm.schedmd.com/fair_tree.html>
- Classic: F = 2^(-U/S), 0.5 = exactly one's share; `PriorityFlags=NO_FAIR_TREE`
  — <https://slurm.schedmd.com/classic_fair_share.html>
- `sshare` fields (NormShares, EffectvUsage, FairShare, LevelFS; under Fair Tree
  normalized among siblings) — <https://slurm.schedmd.com/sshare.html>
- `sprio`: the pending jobs' priority and weighted factors —
  <https://slurm.schedmd.com/sprio.html>
- `PriorityType=priority/basic` is FIFO — <https://slurm.schedmd.com/slurm.conf.html>
