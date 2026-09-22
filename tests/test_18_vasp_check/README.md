# test_18_vasp_check

> vasp-check: does it identify what a finished run actually was

## 1. Definition

Runs four real VASP calculations whose answers are known and verified against
published values, hands each to `vasp-check`, and checks the verdict it gives.

## 2. Purpose

`vasp-check` makes **claims** about a calculation: metal or insulator,
converged or not, magnetic or not, and what the gap is. A post-mortem that
mislabels a metal as an insulator is worse than no post-mortem, because by the
time you run it you are already looking for a verdict and you will take it.

## 3. How it is executed

```
tests/run_all.sh test_18_vasp_check
```

Four runs on 4 ranks, a few minutes in total, plus an empty directory.

| case | must say | why this one |
|---|---|---|
| **Si** | semiconductor/insulator, gap ≈ 0.6 eV, converged | the ordinary healthy run |
| **Al** | **metallic**, and any gap it prints below the smearing width | a checker that finds a gap everywhere passes Si and fails here |
| **Fe** | magnetic, moment ≈ 2.2 μB | a checker that ignores `ISPIN` reports a non-magnetic metal |
| **Si, `NELM = 2`, `EDIFF = 1E-8`** | **unconverged** | the run completes and writes a perfectly normal OUTCAR |

Al and Si are the pair that matters: same code path, same 2-atom-scale cell,
**opposite answers**. Neither can be got right by accident.

The `NELM = 2` case is the sharpest. VASP does not complain — it stops when it
is told to. The OUTCAR looks ordinary, the energy is plausible, and the result
is wrong. Nothing but the iteration count reveals it, and that is exactly the
situation the command exists for.

## 4. Expected results

| quantity | expected | source |
|---|---|---|
| Si indirect gap | ≈ 0.6 eV (PBE/PAW) | [1] |
| Al | no real gap — free-electron metal | [2] |
| Fe moment | 2.2 μB/atom | [3] |

Plus: an empty directory must not crash it, and must be reported as having
nothing to check.

## 5. Obtained results

```
Si: reported as a semiconductor/insulator; gap 0.5975 eV; converged
Al: the report says the system is metallic
Al: vasp-check prints a gap of 0.03 eV (pymatgen reads 0.000) -- below
    the 0.2 eV smearing width, with the metallic warning alongside it
Fe: magnetization section present; net cell moment 2.2410 uB
Si with NELM=2: reported as unconverged
an empty directory: no crash, reported as having nothing to check
```

No package bug was found here. Two assertions failed on the first run; both
were **my own**.


## 6. Pass / fail criterion

| quantity | tolerance | what it excludes |
|---|---|---|
| Si gap | 0.6 ± 0.25 eV | 0.0 (gap washed out) and 1.17 (the experimental value) |
| Fe moment | 2.2 ± 0.4 μB | 0.0, which is what a lost `ISPIN` gives |
| Al gap | < 0.2 eV (the smearing width) | any invented gap |

A gap printed for aluminium is not by itself a failure — 0.03 eV is the k-mesh,
not a gap — but printing it **without the metallic warning alongside** is,
because a reader who sees only that line is misled.

**What is not asserted:** whether the numbers are good physics. PBE
underestimates semiconductor gaps by roughly a factor of two; that is a
property of the functional, not a defect in the checker. The test asserts that
`vasp-check` reports what the run contains.

## 7. Verdict

**PASSED** — 11 assertions, 0 failed. See `logs/run.log`; each case keeps its
own `check.log` beside its OUTCAR under the work directory.

## Sources

1. Yang, Peng, Sun & Perdew, Table I — Si: Exp 1.17, LDA 0.60, PBE 0.71
   (all-electron), HSE 1.11 eV. arXiv:1603.00512 —
   <https://arxiv.org/pdf/1603.00512>. VASP/PAW gives ≈ 0.6 eV.
2. The cell and path are the VASP wiki's own example —
   <https://vasp.at/wiki/Si_bandstructure>
3. bcc Fe, ≈ 2.2 μB/atom in PBE — arXiv:2012.12763 —
   <https://arxiv.org/pdf/2012.12763>; experiment 2.22 μB (Kittel,
   *Introduction to Solid State Physics*, ch. 12).
