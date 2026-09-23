# test_25_chain_structure

> what a CHUNKED relaxation changed, not what its last chunk changed

## 1. Definition

Builds a folder that looks like a finished chunked relaxation — with a known
displacement injected in two stages — and checks which "before" `vasp-check`
compares the final structure against.

## 2. Purpose

`vasp-relax-loop` restarts each chunk from its own `CONTCAR`: at every boundary
the chain does `cp CONTCAR POSCAR`, so the next job resumes from the geometry
reached so far. After five chunks the `POSCAR` in the folder is the geometry
**chunk five began with**.

`vasp-check` diffed that against the final `CONTCAR` under a heading reading
*"What the relaxation changed"*. It reported the last chunk's movement and
called it the relaxation's.

The failure is quiet in the worst possible way: the number it prints is
**small**, and small is what "converged" looks like. It is smallest exactly when
the relaxation has wandered furthest, because a longer run means more chunks
and a more recent `POSCAR`.

The chain already keeps the real thing — every chunk archives the geometry it
started from, so chunk 001's copy is the original input.

## 3. How it is executed

```
tests/run_all.sh test_25_chain_structure
```

Si, 2 atoms, with one atom moved in two stages: 0.25 → 0.28 (three chunks) →
0.29 fractional along x. The whole relaxation moves it 0.04; the last chunk
moves it 0.01. Seconds; no VASP — the displacements are injected, so the right
answer is known in closed form.

## 4. Expected results

| check | expected |
|---|---|
| a chunked folder | compares against `wolfpack_chain/chunk-001/POSCAR.in.gz`, and **says so** |
| the displacement reported | **0.1536 Å** — the whole chain's 0.04 fractional |
| an unchained relaxation | unchanged: diffs its own `POSCAR`, same heading |
| a chunk directory with nothing archived | falls back to `./POSCAR`, still reports, no traceback |
| the control: same files, no chain | **0.0384 Å** — the last chunk alone |
| the decompressed original | cleaned up, not left in `/tmp` |

0.04 fractional along x in this cell is `0.04 × 5.43 × √0.5 = 0.1536 Å`;
0.01 is a quarter of that. The two are a factor of four apart, so no tolerance
can confuse them — which is what the control row exists to demonstrate.

## 5. Obtained results

```
vasp-check sees this is a chunked run and says which 'before' it used
the displacement is the WHOLE chain's        0.1536 A
an unchained relaxation still diffs its own POSCAR, with the usual heading
and it reports the same 0.04 when its POSCAR really is the original
a chunk directory with nothing archived falls back to ./POSCAR and still reports
last chunk alone would report                0.0384 A
the decompressed original is cleaned up, not left in /tmp
```

**One package bug was found here and fixed:** `vasp_check.sh` compared `POSCAR`
against `CONTCAR` unconditionally. It now prefers the chain's archived original
when one exists, names the file it used in the heading, and says how many
chunks it is summarising.

## 6. Pass / fail criterion

| quantity | tolerance | why |
|---|---|---|
| chained displacement | 0.1536 ± 0.02 Å | excludes 0.0384, the wrong answer |
| control displacement | 0.0384 ± 0.005 Å | proves the two answers are distinguishable |

The control is the point of the tolerances. Without it, both assertions would
pass for a tool that reported the same number either way.

## 7. Verdict

**PASSED** — 7 assertions, 0 failed. See `logs/run.log`.

## Sources

- `CONTCAR` as the restart geometry, and what a chained run rewrites —
  <https://www.vasp.at/wiki/index.php/CONTCAR>
- The displacement measure itself is pymatgen's, through
  `wolfpack_structure.py`; `test_05_structure` checks it against closed-form
  answers, so this test only checks WHICH pair of structures it is given.
