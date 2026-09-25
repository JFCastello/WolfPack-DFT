# test_10_magnetic

> build-magnetic-configs: orderings, MAGMOM site order, --magmom, refusals

## 1. Definition

Enumerates the collinear magnetic orderings of NiO three times: with
pymatgen's default moments, with `--magmom "Ni:1.0"`, and with the INCAR
shorthand `--magmom "2*3.0 2*0.0"`. Then it checks:

- in every folder of the three trees, that `MAGMOM` lines up site for site with
  its own `POSCAR`;
- that the orderings really differ;
- that the flag changes the magnitudes and nothing else.

It also checks the inputs the tool must refuse.

## 2. Purpose

The output is a tree of folders, each holding a `MAGMOM` that must line up
**site for site** with its own `POSCAR`. A `MAGMOM` off by one site is a
different magnetic structure. It converges perfectly well, it produces a
perfectly reasonable energy, and nothing downstream can tell.

The second thing it catches: an enumerator that returns the ferromagnet nine
times has produced **one** ordering, not nine, and the folder count says nine.

The third is the division of labour behind `--magmom`. The flag says **how
large** a moment each species starts with. It does not say where the up and
down sites go: that is the enumeration, and the enumeration is pymatgen's
`MagneticStructureEnumerator`, untouched. A flag that also changed which
orderings appeared would mean this package had started deciding the magnetic
structure, which is not its job.

## 3. How it is executed

```
tests/run_all.sh test_10_magnetic
```

**NiO in the AFM-II ordering, four sites.** That ordering — ferromagnetic (111)
sheets that alternate — does not exist in a 2-atom cell, so the reference cell
is built deliberately as the smallest one that can hold it. MgO for the case
pymatgen calls non-magnetic. About two minutes; `pymatgen` + `enumlib`, no VASP.

## 4. Expected results

| check | expected |
|---|---|
| a missing INCAR | **hard error** — otherwise every folder gets a two-line INCAR (`ISPIN`, `MAGMOM`) and runs at default cutoff with the wrong functional, silently |
| a near-miss filename next to it | named in the refusal (the mistake that motivated this was `INACAR`) |
| `--no-incar` | the explicit way through |
| orderings, pymatgen's defaults | more than one, and actually distinct |
| enumlib scratch files | cleaned up, and a user file with a colliding name **survives** |
| `--magmom "Ni:1.0"` | every generated moment is 1.0 |
| `--magmom "2*3.0 2*0.0"` (INCAR shorthand, one entry per ion in POSCAR order) | every generated moment is 3.0 |
| the three runs | the **same number of orderings** and the **same sign patterns** |
| pymatgen's default | a different magnitude (5.0), so the comparison above is not vacuous |
| `MAGMOM` entries, every folder of the three trees | equal to the site count, expanding `N*value` shorthand |
| MgO without the flag | refused (non-zero exit), and the refusal names `--magmom` |
| MgO with `--magmom "Mg:1.0"` | enumerates |
| `--strategies ...,ferrimagnetic_by_motif` | accepted alongside the flag |
| `Fe:3.0` on a cell with no Fe, `Ni:abc`, a wrong value count, all zeros, empty | each refused with a message naming the problem |

## 5. Obtained results

```
a missing INCAR is refused, and names the near-miss file; --no-incar goes through
NiO: 9 orderings produced, 6 of them distinct
NiO: no enumlib debris left next to the inputs; the user's own file survived
EL:value form -- every moment is the 1.0 asked for        (0.0 1.0)
INCAR shorthand -- every moment is the 3.0 asked for      (0.0 3.0)
--magmom produces the same NUMBER of orderings as pymatgen's defaults (9)
and the same sign patterns; the INCAR shorthand agrees with them too
pymatgen's default magnitude differs from the flag's      (0.0 5.0 vs 0.0 1.0)
MAGMOM lines up with the POSCAR in all 27 folders, with and without --magmom
MgO is refused without the flag (exit 1), naming --magmom; with Mg:1.0 it enumerates
ferrimagnetic_by_motif accepts the flag
the five malformed --magmom values are each refused
```

No package bug was found here.

## 6. Pass / fail criterion

Exact throughout. The `MAGMOM`/`POSCAR` alignment is exact in every folder, and
one mismatch fails the test. Distinctness is counted, not judged: the number of
distinct MAGMOM vectors must exceed one. The magnitudes, the ordering count and
the sign patterns are compared as strings; a magnitude is the number asked for
or it is not.

**What is deliberately not tested:** which ordering is the ground state. This
package enumerates orderings and lets DFT rank them by energy; picking a winner
would be judging the physics, which is not its job, and neither is it this
test's.

**What is deliberately not done.** pymatgen's enumerator does not accept a
different starting magnitude per symmetrically inequivalent site of one
species: `_sanitize_input_structure` strips per-site magmoms and rebuilds them
from a `{species: magnitude}` dict with `overwrite_magmom_mode="replace_all"`.
Writing that enumeration by hand is exactly the thing this package does not do.
What pymatgen **does** offer is `ferrimagnetic_by_motif`, which splits sites by
Wyckoff symbol and gives them different moments in the output — reachable
through `--strategies`, and checked here.

## 7. Verdict

**PASSED** — 24 assertions, 0 failed. See `logs/run.log`.

## Sources

The enumeration strategies, their automatic selection and the
`default_magmoms` argument are pymatgen's `MagneticStructureEnumerator`, the
reference implementation of:

- Horton, Montoya, Liu & Persson, *High-throughput prediction of the
  ground-state collinear magnetic order of inorganic materials using Density
  Functional Theory*, npj Computational Materials **5**, 64 (2019) —
  <https://www.nature.com/articles/s41524-019-0199-7>
- AFM-II as NiO's established ground-state ordering — same paper, and
  <https://doi.org/10.1103/PhysRev.110.1333> (Roth, 1958).
- `MAGMOM`, including the `N*value` shorthand the flag also accepts —
  <https://www.vasp.at/wiki/index.php/MAGMOM>
