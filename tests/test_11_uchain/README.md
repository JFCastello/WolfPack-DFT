# test_11_uchain

> vasp-calculate-u: the linear-response Hubbard U, against VASP's own worked example

## 1. Definition

Checks that `vasp-calculate-u` turns a `U_data.dat` table into the Hubbard U by
the linear-response method, and that it refuses the four malformed inputs a
user can hand it.

## 2. Purpose

The command is two least-squares slopes and a subtraction. That is small enough
to verify **exactly** rather than approximately, so there is no excuse for it
being wrong — and a wrong U goes straight into an INCAR and into every result
built on it.

The failure it is designed to catch is a mis-stated formula: the right
magnitude with the wrong sign, which looks like a plausible number.

## 3. How it is executed

```
tests/run_all.sh test_11_uchain
```

Builds a `U_data.dat` whose fitted slopes are exactly VASP's, runs
`vasp-calculate-u`, then feeds it four malformed tables. No VASP, no scheduler.
Runs in under five seconds.

## 4. Expected results

From the VASP wiki tutorial **"Calculate U for LSDA+U"** — NiO 2×2×2 AFM-II,
a = 4.035 Å, perturbing the d shell of atom 1 with `LDAUTYPE = 3`,
`LDAUU = LDAUJ = 0.10`:

| quantity | tutorial's value |
|---|---|
| ground-state d occupancy, atom 1 | 8.439 |
| non-self-consistent (`ICHARG = 11`) | 8.488 |
| self-consistent | 8.452 |
| χ₀ = 0.050/0.1 | 0.50 (eV)⁻¹ |
| χ = 0.012/0.1 | 0.12 (eV)⁻¹ |
| **U = χ⁻¹ − χ₀⁻¹ = 1/0.12 − 1/0.5** | **6.33 eV** |

The occupancy **rises** with a positive α (8.439 → 8.488), so both slopes are
positive and U comes out positive.

Also expected: a missing file, a single data point, a malformed table and a
zero response are each **refused with a message**, never a traceback and never
`U = inf`.

## 5. Obtained results

```
chi_0 = 0.500000 e/eV   (non-self-consistent response)
chi   = 0.120000 e/eV   (self-consistent response)
U = 6.333 eV
```

All four malformed inputs refused with a message naming the problem.

## 6. Pass / fail criterion

| assertion | tolerance | why that tolerance |
|---|---|---|
| U = 6.33 eV | ±0.02 | the tutorial quotes two decimals; anything outside is a different calculation |
| U > 0 | — | a negative U would mean the terms are subtracted the wrong way round |
| χ₀ = 0.50, χ = 0.12 reported | ±0.005 | they must be shown, not just folded into U |
| four malformed inputs | exact | refusal **with** a message; a traceback fails |

## 7. Verdict

**PASSED** — 10 assertions, 0 failed. See `logs/run.log`.

## Sources

- **VASP wiki, "Calculate U for LSDA+U"** — the worked NiO example, its
  occupancies, its χ values and its 6.33 eV:
  <https://vasp.at/wiki/Calculate_U_for_LSDA%2BU>
- M. Cococcioni & S. de Gironcoli, Phys. Rev. B **71**, 035105 (2005) —
  <https://doi.org/10.1103/PhysRevB.71.035105>

