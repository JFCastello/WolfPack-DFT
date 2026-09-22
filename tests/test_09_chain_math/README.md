# test_09_chain_math

> the chain's refusals: every one is a run that would produce nothing

## 1. Definition

Presents `vasp-scf-loop` and `vasp-relax-loop` with nine situations in which
chunking the calculation would be wrong, and checks each is refused **before**
anything is submitted.

## 2. Purpose

A chunked chain that should not have been chunked does not crash. It runs, it
finishes, it produces numbers. The numbers are wrong in ways nothing downstream
can detect — a thermostat restarted at every boundary, forces computed from a
truncated electronic loop, Pulay stress paid once per chunk.

So refusing is the feature, and it has to happen before queue time is spent.

## 3. How it is executed

```
tests/run_all.sh test_09_chain_math
```

Nine fabricated folders, each wrong in one way. Seconds; nothing is submitted —
that is the point.

## 4. Expected results

| situation | why it must refuse |
|---|---|
| a **relaxation** INCAR given to `vasp-scf-loop` | its `NELM` would be chunked while the ions keep moving: every boundary truncates an electronic loop, and the forces that move the ions next are wrong |
| a **static** INCAR given to `vasp-relax-loop` | there is no ionic loop to chunk |
| `IBRION = 0` (molecular dynamics) | velocities and thermostat state are in no restart file; chunking silently restarts the thermostat at every boundary |
| a **cell** relaxation (`ISIF ≥ 3`) at too low an `ENCUT` | every boundary rebuilds the plane-wave basis, so the Pulay stress error is paid once per chunk instead of once |
| a walltime that leaves no room to compute | the chunk would be all overhead |
| **no measured per-step time** | the chunk size is derived from it and cannot be guessed |
| stage 2 never produced a job script | there is nothing to chunk |
| not a calculation folder | |
| invoked under a name that says neither `scf` nor `relax` | it refuses instead of guessing |

## 5. Obtained results

All nine refused, each with a message naming the reason. No package bug was
found here.

## 6. Pass / fail criterion

Exact: each situation must exit non-zero **and** print a reason, and nothing may
reach `sbatch`. A refusal with no explanation counts as a failure — a user who
is refused without being told why will work around the refusal.

## 7. Verdict

**PASSED** — 9 assertions, 0 failed. See `logs/run.log`.

## Sources

- `IBRION = 0` is molecular dynamics; the restart files VASP writes do not carry
  thermostat state — <https://www.vasp.at/wiki/index.php/IBRION>
- Pulay stress and why a cell relaxation needs a high `ENCUT`, or repetition at
  the relaxed volume — <https://www.vasp.at/wiki/index.php/Energy_vs_volume_volume_relaxations_and_Pulay_stress>
- `ISIF` — <https://www.vasp.at/wiki/index.php/ISIF>

