# test_12_slurm_report

> vasp-slurm-report: sacct parsing and the three ratios that grade an allocation

## 1. Definition

Puts a **fake `sacct`** on `PATH` returning accounting rows whose right answer
is arithmetic we chose, and checks the three efficiency ratios the command
computes from them.

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

Plus: a job with **no accounting data yet** — freshly finished, not yet in the
database — reported as such and not as zeros; no `sacct` at all reported as
such; a directory with no recorded jobs saying so.

## 5. Obtained results

All seven as expected. The three `ReqMem` spellings all give 80 %.

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

**PASSED** — 7 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` field definitions, including the `Mc` / `Mn` suffixes on `ReqMem` —
  <https://slurm.schedmd.com/sacct.html>

