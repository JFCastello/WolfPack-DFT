# test_15_pipeline_live

> dry-run -> recommend -> test, on a live SLURM, with a VASP that computes

## 1. Definition

Runs the three pipeline stages in order on a real scheduler with a real VASP,
and checks what each hands to the next.

## 2. Purpose

This is the check that cannot be done any other way. Reading the scripts the
toolkit writes tells you they parse; submitting them tells you the scheduler
takes them; **running** them tells you VASP starts and that the numbers the
report quotes are the numbers the run produced.

The failure it is designed to catch: **stage 2's INCAR and its `slurm.sh`
disagreeing**. Then the benchmark measures one configuration and production
runs another, and both look completely healthy.

## 3. How it is executed

```
tests/run_all.sh test_15_pipeline_live
```

Si, 2 atoms, Γ-centred 6×6×6, on the testbed's one real node (8 cores, ~6 GB).
A few minutes.

## 4. Expected results

| stage | must |
|---|---|
| 1 `vasp-dry-run` | submit; capture the OUTCAR |
| 2 `vasp-recommend-slurm` | choose a layout; write `slurm.sh`; geometry self-consistent; inside the cap; **accepted by SLURM**; and the INCAR carries the recommended KPAR |
| 3 `vasp-test` | submit; VASP records electronic steps; benchmark the **fixed** config, not the raw INCAR; no traceback; write `slurm_vasptest.sh`, also accepted by SLURM |

## 5. Obtained results

All fifteen assertions passed. `slurm.sh` came out 1 node × 8 ranks = 8, inside
the 8-core cap, accepted by `sbatch --test-only`; the INCAR carried `KPAR = 8`;
the benchmark ran `KPAR = 8`; `slurm_vasptest.sh` was written and accepted.

## 6. Pass / fail criterion

Every stage must complete, `--nodes × --ntasks-per-node` must equal `--ntasks`
(or the directive must be absent rather than untrue), `nodes × cores-per-node`
must not exceed the cap, both scripts must be accepted by a real `slurmctld`,
and the KPAR in the INCAR must equal the KPAR recommended.

## 7. Verdict

**PASSED** — 15 assertions, 0 failed. See `logs/run.log`.

## Sources

- The MPI rank-placement rule the geometry has to satisfy —
  <https://vasp.at/wiki/Category:Parallelization>
- `sbatch --test-only` — <https://slurm.schedmd.com/sbatch.html>
