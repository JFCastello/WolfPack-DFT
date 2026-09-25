# test_05_structure

> wolfpack-structure: the POSCAR->CONTCAR diff, against a deformation we injected; in vasp-check, a chained relaxation's whole

## 1. Definition

Deforms a known cell in a known way, hands the before/after pair to
`wolfpack-structure`, and checks the strain it reports against the closed-form
answer for that deformation.

Then it checks the same comparison through `vasp-check`, on a folder that
looks like a finished `vasp-relax-loop` chain. There it must report the whole
relaxation, not the last chunk's.

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

And one that is quiet in the worst possible way. `vasp-relax-loop` runs every
chunk in its own directory (`wolfpack_chain/001`, `002`, …), never overwrites
the folder's `POSCAR`, and copies the latest `CONTCAR` into the folder. So
`vasp-check`'s POSCAR → CONTCAR is the **whole** relaxation. Comparing the last
chunk's start with its end instead would print a number that is **small**, and
small is what "converged" looks like.

## 3. How it is executed

```
tests/run_all.sh test_05_structure
```

Four injected cases plus three malformed ones. Then Si, 2 atoms, with one atom
moved in two stages: 0.25 (the input `POSCAR`) → 0.28 (where chunk 3 started,
`wolfpack_chain/003/POSCAR`) → 0.29 fractional along x (the `CONTCAR`). The
whole relaxation moves it 0.04; the last chunk moves it 0.01. Seconds; no VASP.

## 4. Expected results

| injected | expected | why that number |
|---|---|---|
| every lattice vector × 1.01 | **1.005 %** | `E = (FᵀF − I)/2`, `F = 1.01·I` → `(1.01² − 1)/2` |
| 30° rotation about z, nothing else | **0.000 %** | `FᵀF = I` for any rotation, by construction |
| one atom displaced | reported | |
| the same pair, rendered | data only: no verdicts ("contracted", "symmetry fell", notes, warnings); one side-by-side table with each quantity once; `--labels` names the columns | the report states numbers, the reader interprets them |
| different site counts | says so, reports no displacements | a site-by-site comparison is meaningless |
| vasp-check, a chained folder | "chained relaxation: POSCAR is the input, CONTCAR the latest of 3 completed chunk(s)" | |
| vasp-check, the displacement there | **0.1536 Å** | the whole chain's 0.04 fractional: `0.04 × 5.43 × √0.5` |
| vasp-check, the same folder unchained | the same heading, no chain note | |
| the control: the last chunk alone (0.28 → 0.29) | **0.0384 Å** | a quarter of the above, so the two answers are distinguishable |

The expected 1.005 % is **computed in the test**, not typed, so the test cannot
drift into agreeing with a wrong convention.

## 5. Obtained results

```
a 1% uniform stretch is reported as Green-Lagrange strain   1.0050 %
a pure 30-degree rotation registers as ZERO strain          0.0000 %
a displaced atom is reported
the comparison is data only: no verdicts or interpretation in it
one side-by-side table (before, after, change, %), each quantity once
--labels names the two columns
a missing file is refused, not assumed empty
a file that is not a structure is refused
cells with different site counts: says so, reports no displacements
vasp-check on a chain says what POSCAR and CONTCAR are
vasp-check reports the WHOLE chain's displacement             0.1536 A
an unchained relaxation: the same heading, no chain note
the last chunk alone is a different number                    0.0384 A
```

The report was rewritten on 2026-09-24 after a user found it unreadable. Each
structure used to be described in full, and then everything was repeated as a
diff. Verdicts were mixed into the data: "<-- contracted", "symmetry FELL", a
paragraph about ISYM, a note on tolerances. Now it is side-by-side tables of
numbers only. The strain, displacement and refusal checks above are unchanged.

## 6. Pass / fail criterion

| quantity | tolerance | why |
|---|---|---|
| uniform strain | 1.005 ± 0.002 % | excludes 1.000 %, the engineering-strain answer |
| rotation | 0.000 ± 0.01 % | excludes any rotation leaking in |
| chained displacement | 0.1536 ± 0.02 Å | excludes 0.0384, the last chunk's answer |
| control displacement | 0.0384 ± 0.005 Å | proves the two answers are distinguishable |

The first tolerance is chosen so the wrong convention fails. The two answers
differ by 0.005 %, so the band must be narrower than that. It used to be
±0.02 %, which **included** 1.000 %: the test could not tell the two
conventions apart, and this README claimed it could. The report prints four
decimals, so ±0.002 % is comfortably wider than rounding.

## 7. Verdict

**PASSED** — 13 assertions, 0 failed. See `logs/run.log`.

## Sources

- Green–Lagrange strain `E = ½(FᵀF − I)` with `F = L_after · L_before⁻¹` is the
  standard finite-strain measure; its defining property is invariance under
  rigid rotation, which assertion 2 verifies directly.
  <https://en.wikipedia.org/wiki/Finite_strain_theory#Finite_strain_tensors>
- `CONTCAR` as the geometry a relaxation ends at, and the next one starts
  from — <https://www.vasp.at/wiki/index.php/CONTCAR>

