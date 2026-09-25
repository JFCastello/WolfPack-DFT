# test_25_chain_structure

> what a CHAINED relaxation changed: the whole relaxation, not its last chunk

## 1. Definition

Builds a folder that looks like a finished `vasp-relax-loop` chain — with a known
displacement injected in two stages — and checks which structures `vasp-check`
compares, and that it says so.

## 2. Purpose

`vasp-relax-loop` runs every chunk in its own directory (`wolfpack_chain/001`,
`002`, …) and never overwrites the folder's `POSCAR`; after each chunk it copies
the latest `CONTCAR` into the folder. So `vasp-check`'s **POSCAR → CONTCAR is the
whole relaxation.**

The failure this guards against is quiet in the worst possible way: comparing the
last chunk's start with its end prints a number that is **small**, and small is
what "converged" looks like. The old chain (until 2026-09-25) did overwrite
`POSCAR` at every boundary, and `vasp-check` had to dig the original out of the
chain's archive; the new one keeps it where it was.

## 3. How it is executed

```
tests/run_all.sh test_25_chain_structure
```

Si, 2 atoms, with one atom moved in two stages: 0.25 (the input) → 0.28 (where
chunk 3 started) → 0.29 fractional along x (the end). The whole relaxation moves
it 0.04; the last chunk moves it 0.01. Seconds; no VASP — the displacements are
injected, so the right answer is known in closed form.

## 4. Expected results

| check | expected |
|---|---|
| a chained folder | "chained relaxation: POSCAR is the input, CONTCAR the latest of 3 completed chunk(s)" |
| the displacement reported | **0.1536 Å** — the whole chain's 0.04 fractional |
| an unchained relaxation | the same heading, no chain note |
| the control: the last chunk alone (0.28 → 0.29) | **0.0384 Å** |

0.04 fractional along x in this cell is `0.04 × 5.43 × √0.5 = 0.1536 Å`; 0.01 is a
quarter of that. The control shows the two answers are distinguishable.

## 5. Obtained results

```
vasp-check sees the chain and says what POSCAR and CONTCAR are
the displacement is the WHOLE chain's        0.1536 A
an unchained relaxation: the same heading, no chain note
last chunk alone would report                0.0384 A
```

Rewritten on 2026-09-25 with the relaxation chain's redesign: `vasp-check` no
longer looks for the old chain's archive (`chunk-NNN/POSCAR.in.gz`); the input is
simply `POSCAR`.

## 6. Pass / fail criterion

| quantity | tolerance | why |
|---|---|---|
| chained displacement | 0.1536 ± 0.02 Å | excludes 0.0384, the wrong answer |
| control displacement | 0.0384 ± 0.005 Å | proves the two answers are distinguishable |

## 7. Verdict

**PASSED** — 4 assertions, 0 failed. See `logs/run.log`.

## Sources

- `CONTCAR` as the restart geometry — <https://www.vasp.at/wiki/index.php/CONTCAR>
- The displacement measure itself is pymatgen's, through
  `wolfpack_structure.py`; `test_05_structure` checks it against closed-form
  answers, so this test only checks WHICH pair of structures it is given.
