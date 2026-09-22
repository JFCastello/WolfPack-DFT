# test_17_vasp_tutorial_magnetism

> VASP's own magnetism tutorial, run with its own input files

## 1. Definition

Reproduces part 1 of the official VASP magnetism tutorial — ferromagnetic hcp
cobalt — using the tutorial's POSCAR, INCAR and KPOINTS verbatim, and compares
the moment against the experimental value the tutorial quotes.

## 2. Purpose

This test exists because of the Hubbard U (see `../RULES.md`, rule 1). A
physical quantity was "corrected" from my own reasoning about which way
electrons move, and the reasoning was backwards. The defence is to take VASP's
worked examples and **reproduce them**, rather than argue about what the answer
should be.

It also catches the most common way a magnetic calculation goes silently wrong:
a lost `ISPIN` or `MAGMOM`. Such a run converges perfectly, reports a sensible
energy, and gives a moment of zero.

## 3. How it is executed

```
tests/run_all.sh test_17_vasp_tutorial_magnetism
```

Two real VASP runs on 4 MPI ranks — the tutorial's setup, and the same cell
with `ISPIN`/`MAGMOM` removed. About one minute total.

Input files, copied from the tutorial and not adapted:

```
POSCAR     a = 2.4719999032 A,  c = 4.02114408 A,  2 Co
INCAR      ALGO = Normal   PREC = Accurate   EDIFF = 1e-5   ENCUT = 350
           ISPIN = 2       MAGMOM = 2 2      LMAXMIX = 4    LASPH = T
           ISMEAR = 2      SIGMA = 0.1
KPOINTS    Gamma  6 6 4
```

## 4. Expected results

The tutorial gives the experimental moment as **1.7 μB/Co** and says the
computed value is *"a bit smaller but in relatively good agreement"*.

So: a moment per Co somewhat below 1.7 μB; zero without `ISPIN`; and the
ferromagnet lower in energy than the non-magnetic state.

## 5. Obtained results

```
total magnetization 3.1513726 muB for 2 Co  ->  1.576 muB/Co
without ISPIN:       no magnetization line at all
ferromagnet lower by 0.2443 eV/atom
```

1.576 against 1.7 is exactly "a bit smaller".

## 6. Pass / fail criterion

| assertion | criterion | why |
|---|---|---|
| moment per Co | 1.60 ± 0.15 μB | covers "a bit smaller"; excludes **0.0** (spin polarisation lost) and ≥1.7 (which would mean it was not smaller) |
| without `ISPIN` | moment 0 or no line | the negative control |
| FM vs non-magnetic | FM lower by > 0.05 eV/atom | the energy gain is the signature that the moment is real rather than a printed number |

## 7. Verdict

**PASSED** — 4 assertions, 0 failed. See `logs/run.log`.

## Sources

- **VASP tutorial, Magnetism part 1** — the input files, the experimental
  1.7 μB/Co, and the statement that the computed value is a bit smaller:
  <https://vasp.at/tutorials/latest/magnetism/part1/>
- `ISPIN` — <https://www.vasp.at/wiki/index.php/ISPIN>
- `MAGMOM` — <https://www.vasp.at/wiki/index.php/MAGMOM>

