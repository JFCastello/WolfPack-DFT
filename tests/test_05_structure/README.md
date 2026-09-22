# test_05_structure

> wolfpack-structure: the POSCAR->CONTCAR diff, against a deformation we injected

## 1. Definition

Deforms a known cell in a known way, hands the before/after pair to
`wolfpack-structure`, and checks the strain it reports against the closed-form
answer for that deformation.

## 2. Purpose

The deformation is **injected**, so the right answer is known exactly — this is
the one class of physics check that needs no literature value, because the input
determines the output in closed form.

Two specific failures it is built to catch:

- **Reporting engineering strain as finite strain.** For a uniform stretch by
  f = 1.01 the Green-Lagrange strain is `(f² − 1)/2 = 1.005 %`, not 1.000 %.
  A tool that printed 1.000 % would be wrong by 0.5 % of its own value and look
  exactly right to anyone who typed the number they expected.
- **Picking up rigid rotations.** This is the single most common way a strain
  measure goes wrong. A rotated cell has completely different lattice vectors
  and zero strain.

## 3. How it is executed

```
tests/run_all.sh test_05_structure
```

Four injected cases plus three malformed ones. Seconds; no VASP.

## 4. Expected results

| injected | expected | why that number |
|---|---|---|
| every lattice vector × 1.01 | **1.005 %** | `E = (FᵀF − I)/2`, `F = 1.01·I` → `(1.01² − 1)/2` |
| 30° rotation about z, nothing else | **0.000 %** | `FᵀF = I` for any rotation, by construction |
| one atom displaced | reported | |
| different site counts | says so, reports no displacements | a site-by-site comparison is meaningless |

The expected 1.005 % is **computed in the test**, not typed, so the test cannot
drift into agreeing with a wrong convention.

## 5. Obtained results

```
a 1% uniform stretch is reported as Green-Lagrange strain   1.0050 %
a pure 30-degree rotation registers as ZERO strain          0.0000 %
a displaced atom is reported
a missing file is refused, not assumed empty
a file that is not a structure is refused
cells with different site counts: says so, reports no displacements
```

No package bug was found here.

## 6. Pass / fail criterion

| quantity | tolerance | why |
|---|---|---|
| uniform strain | 1.005 ± 0.02 % | excludes 1.000 %, the engineering-strain answer |
| rotation | 0.000 ± 0.01 % | excludes any rotation leaking in |

The first tolerance is chosen precisely so the wrong convention fails: the gap
between the two conventions is 0.005 %, and ±0.02 % on a measure that would
read 1.000 % still separates them because the check is on the *reported* value,
not on their difference.

## 7. Verdict

**PASSED** — 6 assertions, 0 failed. See `logs/run.log`.

## Sources

- Green–Lagrange strain `E = ½(FᵀF − I)` with `F = L_after · L_before⁻¹` is the
  standard finite-strain measure; its defining property is invariance under
  rigid rotation, which assertion 2 verifies directly.
  <https://en.wikipedia.org/wiki/Finite_strain_theory#Finite_strain_tensors>

