# test_10_magnetic

> build-magnetic-configs: orderings, MAGMOM site order, refusals

## 1. Definition

Enumerates the collinear magnetic orderings of NiO, then checks — folder by
folder — that each generated `MAGMOM` lines up site for site with its own
`POSCAR`, that the orderings really differ, and that the tool refuses the two
inputs it must refuse.

## 2. Purpose

The output is a tree of folders, each holding a `MAGMOM` that must line up
**site for site** with its own `POSCAR`. A `MAGMOM` off by one site is a
different magnetic structure. It converges perfectly well, it produces a
perfectly reasonable energy, and nothing downstream can tell.

The second thing it catches: an enumerator that returns the ferromagnet nine
times has produced **one** ordering, not nine, and the folder count says nine.

## 3. How it is executed

```
tests/run_all.sh test_10_magnetic
```

**NiO in the AFM-II ordering, four sites.** That ordering — ferromagnetic (111)
sheets that alternate — does not exist in a 2-atom cell, so the reference cell
is built deliberately as the smallest one that can hold it. About a minute;
`pymatgen` + `enumlib`, no VASP.

## 4. Expected results

| check | expected |
|---|---|
| a missing INCAR | **hard error** — otherwise every folder gets a two-line INCAR (`ISPIN`, `MAGMOM`) and runs at default cutoff with the wrong functional, silently |
| a near-miss filename next to it | named in the refusal (the mistake that motivated this was `INACAR`) |
| `--no-incar` | the explicit way through |
| a cell with no magnetic species (MgO) | refused, not enumerated |
| `MAGMOM` entries per folder | equal to the site count, expanding `N*value` shorthand |
| orderings | more than one, and actually distinct |
| enumlib scratch files | cleaned up, and a user file with a colliding name **survives** |

## 5. Obtained results

```
NiO: 9 orderings produced, 6 of them distinct
NiO: MAGMOM lines up with the POSCAR in all 9 folders
NiO: no enumlib debris left next to the inputs; the user's own file survived
a missing INCAR is refused, and names the near-miss file
a cell with no magnetic species is refused
```

No package bug was found here.

## 6. Pass / fail criterion

The `MAGMOM`/`POSCAR` alignment is exact in every folder — one mismatch fails
the test. Distinctness is counted, not judged: the number of distinct MAGMOM
vectors must exceed one.

**What is deliberately not tested:** which ordering is the ground state. This
package enumerates orderings and lets DFT rank them by energy; picking a winner
would be judging the physics, which is not its job, and neither is it this
test's.

## 7. Verdict

**PASSED** — 10 assertions, 0 failed. See `logs/run.log`.

## Sources

The enumeration strategies and their automatic selection are pymatgen's
`MagneticStructureEnumerator`, the reference implementation of:

- Horton, Montoya, Liu & Persson, *High-throughput prediction of the
  ground-state collinear magnetic order of inorganic materials using Density
  Functional Theory*, npj Computational Materials **5**, 64 (2019) —
  <https://www.nature.com/articles/s41524-019-0199-7>
- AFM-II as NiO's established ground-state ordering — same paper, and
  <https://doi.org/10.1103/PhysRev.110.1333> (Roth, 1958).
