# test_27_magmom_flag

> build-magnetic-configs --magmom: the magnitudes change, the orderings do not

## 1. Definition

Enumerates the same cell three times — with a per-species magnitude, with the
INCAR's MAGMOM shorthand, and with pymatgen's defaults — and compares the
moments and the sign patterns that come out.

## 2. Purpose

The flag says **how large** a moment each species starts with. It does not say
where the up and down sites go: that is the enumeration, and the enumeration is
pymatgen's `MagneticStructureEnumerator`, untouched.

So what this checks is exactly that division of labour. The flag must change
the magnitudes and **nothing else**; the orderings must be the same ones
pymatgen produces without it. A flag that also changed which orderings appeared
would mean this package had started deciding the magnetic structure, which is
not its job.

## 3. How it is executed

```
tests/run_all.sh test_27_magmom_flag
```

NiO (4 sites, AFM-II) for the main comparisons, MgO for the case pymatgen calls
non-magnetic. About a minute; `pymatgen` + `enumlib`, no VASP.

## 4. Expected results

| input | expected |
|---|---|
| `--magmom "Ni:1.0"` | every generated moment is 1.0 |
| `--magmom "2*3.0 2*0.0"` (INCAR shorthand, one entry per ion in POSCAR order) | every generated moment is 3.0 |
| all three runs | the **same number of orderings** and the **same sign patterns** |
| pymatgen's default | a different magnitude (5.0), so the checks above are not vacuous |
| every folder | `MAGMOM` lines up site-for-site with its own `POSCAR` |
| MgO without the flag | refused, and the refusal names `--magmom` |
| MgO with `--magmom "Mg:1.0"` | enumerates |
| `--strategies ...,ferrimagnetic_by_motif` | accepted alongside the flag |
| `Fe:3.0` on a cell with no Fe, `Ni:abc`, a wrong value count, all zeros, empty | each refused with a message naming the problem |

## 5. Obtained results

```
EL:value form -- every moment is the 1.0 asked for  (0.0 1.0)
INCAR shorthand -- every moment is the 3.0 asked for (0.0 3.0)
--magmom produces the same NUMBER of orderings as pymatgen's defaults (9)
and the same sign patterns -- the magnitude changed, the orderings did not
pymatgen's default magnitude differs from the flag's (0.0 5.0 vs 0.0 1.0)
MAGMOM lines up with the POSCAR in all 9 folder(s) built with --magmom
MgO is refused without the flag; with --magmom Mg:1.0 it enumerates
```

No package bug was found here.

## 6. Pass / fail criterion

Exact throughout: the set of magnitudes, the ordering count and the sign
patterns are compared as strings. There is nothing approximate to be tolerant
about — a magnitude is the number asked for or it is not.

**What is deliberately not done.** pymatgen's enumerator does not accept a
different starting magnitude per symmetrically inequivalent site of one
species: `_sanitize_input_structure` strips per-site magmoms and rebuilds them
from a `{species: magnitude}` dict with `overwrite_magmom_mode="replace_all"`.
Writing that enumeration by hand is exactly the thing this package does not do.
What pymatgen **does** offer is `ferrimagnetic_by_motif`, which splits sites by
Wyckoff symbol and gives them different moments in the output — reachable
through `--strategies`, and checked here.

## 7. Verdict

**PASSED** — 16 assertions, 0 failed. See `logs/run.log`.

## Sources

- `MagneticStructureEnumerator` and its `default_magmoms` argument, the
  reference implementation of: Horton, Montoya, Liu & Persson, npj
  Computational Materials **5**, 64 (2019) —
  <https://www.nature.com/articles/s41524-019-0199-7>
- `MAGMOM`, including the `N*value` shorthand this flag also accepts —
  <https://www.vasp.at/wiki/index.php/MAGMOM>
