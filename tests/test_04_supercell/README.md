# test_04_supercell

> build-supercell: the cell maths, against answers derived rather than copied

## 1. Definition

Builds supercells from the reference cells and checks site count and volume
against values **computed from the input cell**, not copied from a previous run
of the same code. Then feeds it specifications that are wrong in three
different ways.

## 2. Purpose

If the expected numbers came from a previous run, the test would only prove the
code still agrees with itself — including agreeing with its own mistake. So
every expectation here is `natoms × det(S)` and `V × det(S)`, derived.

The asymmetric case exists to catch a tool that quietly symmetrises: MgO 1×1×3
must give 6 sites, and a tool that applied 3 in every direction would give 27
and look entirely healthy.

## 3. How it is executed

```
tests/run_all.sh test_04_supercell
```

Si 2×2×2, MgO 1×1×3, Fe 1×1×1, then `-s 2 0 2`, `-s 2 -1 2`, a missing POSCAR
and a file that is not a POSCAR. Seconds; `pymatgen` only, no VASP.

## 4. Expected results

| input | expected |
|---|---|
| Si 2×2×2 | 2 → 16 sites, volume exactly 8× |
| MgO 1×1×3 | 2 → 6 sites, volume exactly 3× (**not** 27×) |
| Fe 1×1×1 | identity, 1 site |
| `-s 2 0 2` | refused |
| `-s 2 -1 2` | refused |
| missing POSCAR | refused, naming the file |
| a file that is not a POSCAR | refused, no traceback |

## 5. Obtained results

All nine as expected; Si 320.3830 Å³ = 8 × 40.0479, MgO 56.0436 Å³ = 3 ×
18.6812.

**Three package bugs were found here and fixed:**

- **`-s 2 -1 2` was ACCEPTED.** `diag(2, −1, 2)` has determinant −4, so it built
  a **mirrored** 8-atom cell and reported `natoms=8 V=160.191 (×4)` as if all
  were well. Nobody asks for −1 on purpose; a mistyped `2 -1 2` is what produces
  it, and the handedness of the result is flipped with no hint.
- **`-s 2 0 2` crashed** with `numpy.linalg.LinAlgError: Singular matrix` from
  deep inside pymatgen. A zero collapses a lattice vector.
- **A file that is not a POSCAR crashed** with whatever pymatgen's parser hit.

All three are refusals now, with a message naming the problem. A full 3×3 matrix
may legitimately carry negative entries — that is how a non-diagonal supercell
is written — so for those only the **determinant** is checked: zero is singular,
negative mirrors.

## 6. Pass / fail criterion

Site counts exact. Volumes to 1e-4 Å³ — floating point only; there is no physics
in this test to be approximate about. Every malformed input must be refused with
a message that names the problem, and no input may produce a traceback.

## 7. Verdict

**PASSED** — 9 assertions, 0 failed. See `logs/run.log`.

## Sources

- The determinant of the scaling matrix is the cell multiplier — standard
  crystallography; see e.g. pymatgen's `Structure.make_supercell`
  <https://pymatgen.org/pymatgen.core.html#pymatgen.core.structure.Structure.make_supercell>
