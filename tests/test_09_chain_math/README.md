# test_09_chain_math

> vasp-scf-loop's refusals: every one is a run that would produce nothing

## 1. Definition

Presents `vasp-scf-loop` with seven situations in which chunking the SCF would be
wrong, and checks each is refused **before** anything is submitted. (The relaxation
chain, `vasp-relax-loop`, is its own script since 2026-09-25; its refusals are in
test_36.)

## 2. Purpose

A chunked chain that should not have been chunked does not crash. It runs, it
finishes, it produces numbers. The numbers are wrong in ways nothing downstream
can detect — a thermostat restarted at every boundary, a relaxation's electronic
loop truncated while the ions move.

So refusing is the feature, and it has to happen before queue time is spent.

## 3. How it is executed

```
tests/run_all.sh test_09_chain_math
```

Seven fabricated folders, each wrong in one way. Seconds; nothing is submitted —
that is the point.

## 4. Expected results

| situation | why it must refuse |
|---|---|
| a **relaxation** INCAR given to `vasp-scf-loop` | its `NELM` would be chunked while the ions keep moving: every boundary truncates an electronic loop, and the forces that move the ions next are wrong |
| `vasp_chain.sh --mode relax` | the relaxation chain is `vasp-relax-loop`, a different script; this names it |
| `IBRION = 0` (molecular dynamics) | velocities and thermostat state are in no restart file; chunking silently restarts the thermostat at every boundary |
| a walltime that leaves no room to compute | the chunk would be all overhead |
| **no measured per-step time** | the chunk size is derived from it and cannot be guessed |
| stage 2 never produced a job script | there is nothing to chunk |
| not a calculation folder | |

## 5. Obtained results

All seven refused, each with a message naming the reason.

Rewritten on 2026-09-25 with the relaxation chain's redesign. Gone: the
relaxation cases (now test_36), and the refusal of a cell relaxation at an
`ENCUT` below 1.3 × `ENMAX` (Pulay stress). That was a physics judgement the
chain made about the user's INCAR, not plumbing, and the new relaxation chain
does not make it.

## 6. Pass / fail criterion

Exact: each situation must exit non-zero **and** print a reason, and nothing may
reach `sbatch`. A refusal with no explanation counts as a failure — a user who
is refused without being told why will work around the refusal.

## 7. Verdict

**PASSED** — 7 assertions, 0 failed. See `logs/run.log`.

## Sources

- `IBRION = 0` is molecular dynamics; the restart files VASP writes do not carry
  thermostat state — <https://www.vasp.at/wiki/index.php/IBRION>

