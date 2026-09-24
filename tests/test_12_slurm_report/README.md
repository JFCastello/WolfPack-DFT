# test_12_slurm_report

> vasp-slurm-report: every job in a folder, and the three ratios that grade it

## 1. Definition

Puts a **fake `sacct`** on `PATH` returning accounting rows whose right answer
is arithmetic we chose. It checks the three efficiency ratios the command
computes from them, and that the command finds **every** job that ran in a
folder, whichever command launched it.

## 2. Purpose

The command turns `sacct` into three numbers:

```
cpu%   = TotalCPU / (Elapsed x NCPUS)    how much of the reservation computed
mem%   = AveRSS x NCPUS / ReqMem         how much of the RAM asked for was used
time%  = Elapsed / Timelimit             how close it ran to being cut off
```

Every one is a division, and `sacct` hands back units that differ between
fields and between SLURM versions. That is exactly where a ratio goes quietly
wrong by a factor of 1024 — and a wrong `mem%` is acted on: it is what a user
sizes their next job from.

The other failure is quieter: a report that leaves jobs out. The usual
sequence is `vasp-dry-run`, `vasp-test`, then the real run: a production job,
or a chain of chunks. The command read job ids from `.wolfpack/` only, where
the first two keep their logs. So it reported the two preparatory jobs and
**never the run they prepared**. After `vasp-clean`, which removes `.wolfpack/`,
it did not find the folder at all.

A fake `sacct` is used deliberately. Against a real one, the "expected" value
would have to be computed the same way the tool computes it, and the test would
prove only that the code agrees with itself.

## 3. How it is executed

```
tests/run_all.sh test_12_slurm_report
```

Seconds; no VASP, no scheduler.

## 4. Expected results

The planted job:

```
240 cores x 1 h = 240 core-hours allocated (CPUTime = 10 days)
TotalCPU 5 days = 120 core-hours used      ->  cpu%  = 50%
Elapsed 1 h of a 2 h limit                 ->  time% = 50%
AveRSS 800 M x 240 / ReqMem                ->  mem%  = 80%
```

**`ReqMem` is written three ways** — `1000Mc` (per CPU), `48000Mn` (per node)
and `240000M` (job total) — because SLURM has used all three depending on
version, and reading one as another is a 1024× or an NCPUS× error. All three
must give the same 80 %.

**Every job in a folder.** One folder holds all of them:

| job | where it is recorded | stage expected |
|---|---|---|
| 2001 | `.wolfpack/dryrun-2001.out` | `dry-run` |
| 2002 | `.wolfpack/benchmark-2002.out` | `vasp-test` |
| 2003 | `vasp-2003.out` next to the inputs (`slurm.sh` names logs `%x-%j`) | `production` |
| 2004, 2005 | `wolfpack_chain/chain.log`, chunks 1 and 2 | `chunk 1`, `chunk 2` |
| 2006 | `chain.env` and `VASP-chain-2006.out` only (the chunk still running) | `chunk` |
| 1990, 1991 | `wolfpack_chain.prev-*/`, a chain archived by `--fresh` | `chunk 1 (old chain)`, `chunk (old chain)` |

All eight are expected, in job order, with the stage as the last column of the
table and of the CSV. With `.wolfpack/` removed, run from the parent folder,
the folder and its six remaining jobs must still be found.

**No usage recorded.** `sacct` lists the job and its steps with no `MaxRSS`
and a `TotalCPU` of one second, as this suite's testbed does (observed there,
not a documented behaviour). `cpu%` and
`mem%` must read `--`, with the reason, not `0 %`. The job must not be flagged
for low CPU efficiency.

Plus: a job with **no accounting data yet** — freshly finished, not yet in the
database — reported as such and not as zeros; no `sacct` at all reported as
such; a directory with no recorded jobs saying so.

## 5. Obtained results

All seventeen as expected. The three `ReqMem` spellings all give 80 %.

Run against the previous version of `vasp_slurm_report.sh`, eight of them
fail. It lists exactly `2001 2002`, the dry-run and the benchmark and nothing
else, which is the bug as it was reported.

On the live testbed, the folder of test_33's chain now reports both of its
chunks, with `--` and the reason where it used to print `0 %`.

For scale: **5080 %** is what this class of bug printed when the per-CPU
spelling was read as a job total.

## 6. Pass / fail criterion

| ratio | tolerance | why |
|---|---|---|
| `mem%` | 80 ± 5 | a unit error is off by 1024× or 240×, never by 5 |
| `cpu%` | 50 ± 3 | same |

The tolerance exists only to absorb rounding in the tool's own output format.
Any misread unit is orders of magnitude outside it.

## 7. Verdict

**PASSED** — 17 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` field definitions, including the `Mc` / `Mn` suffixes on `ReqMem` —
  <https://slurm.schedmd.com/sacct.html>
- `%x` and `%j` in `--output` are the job name and the job id —
  <https://slurm.schedmd.com/sbatch.html#SECTION_FILENAME-PATTERN>
- `MaxRSS` and `AveRSS` come from the job accounting gather plugin
  (`JobAcctGatherType`) — <https://slurm.schedmd.com/slurm.conf.html#OPT_JobAcctGatherType>.
  That `TotalCPU` is unusable when they are missing is observed on this suite's
  testbed (1–2 s for a 4-rank job that computed for a minute), not documented.

