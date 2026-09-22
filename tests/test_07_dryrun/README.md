# test_07_dryrun

> vasp-dry-run: refuses missing inputs, never claims what it did not measure

## 1. Definition

Runs stage 1 of the pipeline against a real VASP on a real scheduler, and
separately hands it input sets with one file missing, or present but empty.

## 2. Purpose

Stage 1 is the cheapest stage and the one every later stage trusts. So what is
tested is what it **claims**:

- that it refuses an incomplete input set instead of submitting one;
- that it does **not** claim a memory table it does not have. `--dry-run` exits
  before VASP allocates, so there *is* no memory table — and stage 2 sizes
  production from whatever stage 1 reports. An `OK (memory table captured)`
  printed above a `? MB` is worse than a failure.

A zero-byte `POSCAR` is in the test because it passes every `[[ -f ]]` ever
written.

## 3. How it is executed

```
tests/run_all.sh test_07_dryrun
```

Si with a Γ-centred 8×8×8 mesh, submitted to the testbed. About a minute.

## 4. Expected results

| input | expected |
|---|---|
| `INCAR` / `POSCAR` / `KPOINTS` / `POTCAR` missing | refused, and the **message names the file** |
| zero-byte `POSCAR` | refused, not treated as present |
| complete | submits, captures the OUTCAR, really runs a dry run |
| captured OUTCAR | carries `NKPTS` and `NBANDS`, which stage 2 needs |
| the report | does not claim a memory table it does not have |

`NKPTS = 29` is the check with an external answer: 29 is the number of
irreducible k points of a Γ-centred 8×8×8 mesh in `Fd-3m`.

## 5. Obtained results

All eleven as expected. The captured OUTCAR reports **NKPTS = 29** and
**NBANDS = 8**.

**One package bug was found here and fixed:** with any of the four inputs
missing — or a zero-byte POSCAR — **it submitted the job anyway**. The user was
told `Submitted batch job 14`, got exit status 0, and discovered the failure
from the queue. The four files sit right there; checking they exist and are
non-empty costs nothing. It now refuses and names what is missing, and suggests
a near-miss filename when one is present — the mistake that motivated it was a
file called `INACAR`.

Only **presence** is checked. What is inside those files is the user's physics,
and this package does not judge it.

## 6. Pass / fail criterion

Exact. Every incomplete input set must be refused with the missing file named;
`NKPTS` must be exactly 29; and no `OK` may be printed for a memory table that
is absent.

## 7. Verdict

**PASSED** — 11 assertions, 0 failed. See `logs/run.log`.

## Sources

- The `Fd-3m` irreducible-wedge count for a Γ-centred 8×8×8 mesh is what VASP
  itself prints; the Si cell and mesh follow the VASP wiki's own Si example —
  <https://vasp.at/wiki/index.php/Si>
- `--dry-run` and what it does and does not allocate —
  <https://www.vasp.at/wiki/index.php/Available_VASP_command_line_options>
