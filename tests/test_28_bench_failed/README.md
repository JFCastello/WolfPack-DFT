# test_28_bench_failed

> a benchmark that died must not size production

## 1. Definition

Drives the stage-3 helper with the numbers from a benchmark that was
OOM-killed, and checks the verdict, the exit code, and whether a production job
script comes out of it.

## 2. Purpose

This test is written from an incident, on 2026-09-23. A benchmark job on a real
cluster was OOM-killed 19 seconds in, having completed **zero** electronic
steps, and `vasp-test` reported:

```
[VERDICT]  ADEQUATE -- the recommended config works; memory updated below.
[FILES] updated production memory in .../slurm_vasptest.sh  <- submit this
```

The verdict was computed from CPU efficiency and a memory sum alone:

```python
adequate = (args.cpu_eff == 0 or args.cpu_eff >= 70) and fits and not gw_infeasible
```

Nothing looked at VASP's exit code, at the OOM, or at whether a single
electronic step had completed — all three of which the report itself printed a
few lines earlier.

**Why the numbers are not merely incomplete but misleading.** VASP dies during
FFT planning, *before* it allocates the wavefunctions. The RSS recorded is a
floor the real run passes immediately, so a production script sized from it
reproduces the failure — at production cost, after a production queue wait.

It is the dangerous shape of failure: silent, and indistinguishable from
success.

## 3. How it is executed

```
tests/run_all.sh test_28_bench_failed
```

The fixture carries the incident's real numbers — 95 ranks, KPAR = 95, MaxRSS
8320 MB, AveRSS 3756 MB, CPU efficiency 78 % — so it reproduces what made the
run look healthy. Seconds; no VASP, no scheduler.

## 4. Expected results

| input | expected |
|---|---|
| healthy benchmark (12 steps) | exit 0, ADEQUATE, production memory written |
| OOM-killed | exit 8, **FAILED**, production script untouched |
| VASP exit code 1 | exit 8, **FAILED**, production script untouched |
| zero electronic steps | exit 8, **FAILED**, production script untouched |
| VASP ran on 1 MPI rank with 4 started: `srun` launched separate copies | exit 8, **FAILED**, production script untouched |
| the ranks as VASP reports them, `running    1 mpi-ranks, …` (copied from the incident) and `running    4 mpi-ranks, …` | read as 1 and as 4, by the same pattern vasp-test uses |
| the report under FAILED | does not also assert "memory fits one node" as a finding |
| the refusal | names KPAR with its actual value, names ranks-per-node, says to re-run |
| the OOM pattern | matches `slurmstepd`'s real wording, and does not fire on an ordinary log |

The healthy case is listed first and written first: every other assertion is of
the form *"it refuses"*, and a helper that refused everything would pass all of
them.

Exit 8 is distinct from 0 (success) and from 7 (the GW re-pick), so a caller
can tell the three apart.

## 5. Obtained results

All thirty-six as expected. The incident's own input now produces:

```
[VERDICT]  FAILED -- the benchmark was OOM-killed (a task exceeded
           --mem-per-cpu=3640 MB). The benchmark did not run, so nothing
           below is a measurement of this calculation.

 BENCHMARK FAILED -- no production job script was written
  what happened : the benchmark was OOM-killed ...
  measured      : 0 electronic step(s) in 19s
```

**One package bug was found and fixed — the one this test is named after.**
`vasp-test` now detects the three signals and passes the reason to the helper;
the helper makes the verdict FAILED, suppresses the production script, and
returns 8.

**A fourth signal, added on 2026-09-26.** When `srun`'s MPI plugin does not
match the MPI VASP was built with, `srun` starts one copy of VASP per task,
each on 1 rank, all writing the same OUTCAR. It runs, converges, and measures
nothing the job would do. That happened to every `srun`-launched VASP on this
suite's own testbed, whose `slurm.conf` had no `MpiDefault` (VASP here is
OpenMPI with PMIx). The OUTCAR says so (`running    1 mpi-ranks`), so vasp-test
now compares it with the ranks `srun` started, and a mismatch is a failed
benchmark. The testbed now sets `MpiDefault=pmix`.

## 6. Pass / fail criterion

Exact, and two-sided. Each failure mode must produce exit 8, a FAILED verdict,
no `[FILES] updated` claim, and a production script byte-identical to what it
was before — while the healthy control must still produce exit 0, ADEQUATE and
an updated script. A run that only satisfied the first half would be a helper
that refuses everything.

## 7. Verdict

**PASSED** — 36 assertions, 0 failed. See `logs/run.log`.

## Sources

- `oom_kill` and `Out Of Memory` are `slurmstepd`'s own wording; the fixture is
  copied verbatim from the incident's `benchmark-13249633.err`.
  <https://slurm.schedmd.com/slurm.conf.html>
- "To launch Open MPI applications using PMIx the '--mpi=pmix' option must be
  specified on the srun command line or 'MpiDefault=pmix' must be configured
  in slurm.conf." — <https://slurm.schedmd.com/mpi_guide.html>. What happens
  otherwise (one 1-rank VASP per task, all writing one OUTCAR) was measured on
  this suite's testbed with VASP 6.5.1 and Open MPI + PMIx: `srun --mpi=none`
  gave `running 1 mpi-ranks`, `--mpi=pmix` gave `running 4 mpi-ranks`.
- KPAR duplicating the charge density and grids per k-point group is why the
  memory is what it is — <https://vasp.at/wiki/KPAR> and
  <https://vasp.at/wiki/Optimizing_the_parallelization>
