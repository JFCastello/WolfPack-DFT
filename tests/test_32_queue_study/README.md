# test_32_queue_study

> backfill-study: how long a job waits, predicted with your fairshare, and your fairshare now

## 1. Definition

Feeds `backfill-study` (`backfill_study.py`) accounting histories whose right
answer is known in advance. It checks the parsing and the queue wait it reports
for a job. Then it feeds the fairshare section and the prediction scheduler
answers (`scontrol show config`, `sshare`, `sprio`) whose numbers are worked out
by hand.

## 2. Purpose

`backfill-study` answers one question: how long does a job of this shape wait
in this queue, at the walltime it asks for and at others. It measures what the
scheduler did (backfill included) to similar jobs; it does not simulate it.

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
that too little data gives no answer rather than a guess.

## 3. How it is executed

```
tests/run_all.sh test_32_queue_study
```

The histories are written by the test itself, in `sacct --parsable2` format,
so the right answer is arithmetic chosen here, not computed by the code under
test. The fake scheduler is `tests/chain_harness.sh`'s. About 10 seconds.

## 4. Expected results

| section | input | expected |
|---|---|---|
| 1 | `ReqMem` as `1000Mc`, `48000Mn`, `48000M`, and `ReqTRES mem=46.875G`, for 48 CPUs on 1 node | all **48000 MB** |
| 1 | `TimelimitRaw 600`, `1-00:00:00`, `04:30:00`, `UNLIMITED` | 600, 1440, 270, none |
| 1 | a job held 10 h by a dependency, started 1 min after becoming eligible | a **60 s** wait |
| 2 | only 64-core jobs, for a 4-core job | the table compared on the node count, and its title says so |
| 3 | `backfill-study` in the folder (4 ranks, 8 GB, `--time=04:00:00`) | "Predicted wait: about **2.0 h** (Q1 5 min, Q3 4.0 h)", from the 24 jobs of its size that asked 1 to 4 h, and why fairshare was not used (no `sshare` here); the table with the quartiles down and the bands across: 0-1 h **2.0 / 2.0 / 2.0 h** (12 jobs), 1-4 h **5 min / 2.0 h / 4.0 h** (24); "your size" spelled out (1 node, 2–8 cores, 3–23 GB); no run-time estimate and no recommendation; nothing created or submitted |
| 3 | the job on the command line, no folder | the same 2.0 h; without `--partition`, the profile's |
| 3 | no folder and no options; the toolkit's own directory; a folder that does not exist | one message each: not a calculation folder (naming `--nodes --cpus --mem-mb`), or no such folder |
| 3b | `--job 990001`: in `sacct -j`, 1 node, 4 cores, 8 GB, 4 h, waited 30 min; the same job also in the partition's history | its shape and walltime from `sacct -j`; the same **2.0 h** (Q1 5 min, Q3 4.0 h) from the same **24** jobs, so the job is left out of its own comparison (counted, it would make 25 and a median of 30 min); "Job 990001 asked for 4 h and waited 30 min", "between Q1 and Q3" |
| 3b | `--job 990002`, pending for 3 h, asking 1 h | the 1-h column's 2.0 h, and "has been waiting 3.0 h so far", not placed among the quartiles |
| 3b | `--job 990001 --time 01:00:00`; `--job 990002` inside the 4-h folder | the option wins over the job; the job wins over the folder |
| 3b | someone else's job; a job `sacct` does not know; `--job 12ab` | a note that the fairshare is its owner's; refused, naming `sacct -j`; refused, "a job id is digits" |
| 4 | the LaMnO3 relaxation (1 × 56 ranks, 46 GB, 7 days; 76 short 4-core jobs and 10 similar week-long jobs that waited 35–37 min) | about **36 min**, from the 10 jobs of its size that asked 4 to 7 days; one column 4-7 d: **35 / 36 / 37 min**, 10 jobs; the folder's own job waited 12 min; the 4-core jobs are not in the table; at most 21 lines, fairshare included |
| 5 | Santos Dumont: 1 × 48 cores, 73 GB, 7 days, where nobody asked for more than 4 days; `scontrol` shows no MaxTime | "MaxTime: not shown by scontrol"; "No job asked for more than 4 days … yours asks for 7 days", the commands that show the limit, and **no** wait borrowed from the 4-day jobs |
| 5 | the same with MaxTime 4 days | "more than the partition's MaxTime of 4 days: it will not start"; the median row 60 s, 3.3 h, 31.7 h under 1-4 h, 4-12 h, 2-4 d |
| 4 | the LaMnO3 folder without vasp-test's data | the same queue report: it never needed it |
| 6 | Fair Tree; weights fairshare 5000, age 2000 over 14 days; alice in fisica, factor 0.420 | the factor and "1.000 is the top-ranked user"; **5 of 6** associations above; fisica 25.0 % of the shares / 31.0 % of the use, alice 20.0 % / 53.7 %; the weights; **2100** points, and 0.1 of factor = 500 points = **3.5 days** of waiting (2000/14 a day) |
| 6 | 6 pending jobs of 4 users; hers at priority 3321 and 2000 | **2** carry more fairshare points than her 2100 (4900, 3100; not 1500 × 2); **3** and **5** pending jobs above her two; usage halves after 3 days |
| 6 | `PriorityFlags=NO_FAIR_TREE` | "(classic)", "0.500 exactly your share", normalized shares 0.2000 against effective usage 0.5373 |
| 6 | fairshare weight 0; `priority/basic` | "does not change priority here", and no points claimed; "FIFO; there is no fairshare", and no factor |
| 6 | `sshare` and `sprio` showing only her own rows (PrivateData) | "not visible", "sprio lists only your own jobs": hidden, not counted as zero |
| 6 | two accounts | `--account quimica` gives quimica's 0.950; without it, her default from `sacctmgr` (fisica, 0.420) and a note naming both |
| 6 | no scheduler to ask; `--no-fairshare`; `--machine` | one line saying why; the section left out; `--machine` refused: the chain mode is gone |
| 7 | a 3-h job; its column has 33 jobs: carla (0.90) 10 × 1 min, eva (0.60) 3 × 30 min, beto (0.45) 10 × 3 h, dani (0.10) 10 × 10 h; the column 60 s / **3.0 h** / 10.0 h | alice at 0.85: **60 s**, from carla's 10 jobs, "by 1 user", next to the column's 3.0 h; the table unchanged |
| 7 | alice at 0.60; at 0.275 | eva's 3 are too few, so it widens to 0.20: eva + beto, 13 jobs, **3.0 h**; at 0.275, beto + dani, 20 jobs, **6.5 h** ((3 h + 10 h)/2), Q1 3.0 h, Q3 10.0 h |
| 7 | 8 of alice's own jobs (20 min each); alice at 0.75, then 0.45 | alone in the 0.05 window: **20 min**, "from 8 of your own jobs", next to the column's 30 min; at 0.45 with beto: **3.0 h** (Q1 20 min), "you among them" |
| 7 | too few near her; owners hidden; weight 0; `--no-fairshare`; no `sshare` | the column's answer every time (10.0 h, 3.0 h, …), each with its reason after "Fairshare not used:" |

## 5. Obtained results

All fifty-six as expected. Case 7 at 0.85, as it reads:

```
YOUR JOB
  Predicted wait: about 60 s   (Q1 60 s, Q3 60 s)
  from 10 jobs of your size that asked for 1 to 4 h, by 1 user, whose fairshare
  today is 0.90 (yours 0.850). All 33 such jobs, any fairshare: about 3.0 h.
```

**Without the chain, 2026-09-25.** vasp-relax-loop was redesigned: every chunk
now asks for the walltime its own steps are estimated to need, and it no longer
calls `backfill-study`. The `--machine` mode (the chunk-walltime study, the
replay of the old chain's step ramp) and the sections that tested it are gone;
`backfill-study` is the queue report.

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

**`--job` on 2026-09-25.** The job can be named by its id instead of its
folder. Nine assertions (3b); the rest unchanged.

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

**PASSED** — 65 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` fields `Submit`, `Eligible`, `Start`, `Timelimit`, `TimelimitRaw`,
  `ReqTRES`, `ReqMem`, `User`, `Account`, `Priority` ("Slurm priority", with
  no statement of when it is taken), and `--parsable2` —
  <https://slurm.schedmd.com/sacct.html>
- `Eligible` is when the job became eligible to run (after dependencies and
  holds) — <https://slurm.schedmd.com/sacct.html#OPT_Eligible>
- `sacct --jobs` with no `--state`: the default time window starts at Epoch 0,
  so a job of any age is found, and non-eligible jobs are shown too —
  <https://slurm.schedmd.com/sacct.html> (DEFAULT TIME WINDOW, `--jobs`)
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
