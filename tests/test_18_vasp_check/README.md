# test_18_vasp_check

> vasp-check: does it report what a finished run actually holds

## 1. Definition

Runs four real VASP calculations whose answers are known and verified against
published values, hands each to `vasp-check`, and checks the numbers it reports
and the checks it raises.

## 2. Purpose

`vasp-check` reports data: the gap, the partially occupied states, the
moment, the SCF iterations. It checks those against the run's own criteria.
Since 2026-09-24 it draws no physical conclusions: no "metallic", no
"insulator", no "antiferromagnetic", no advice. The reader draws them.

That makes the data the thing to test. A gap, a count of partially occupied
states or a moment that misreads the run is worse than no post-mortem, because
it is acted on. So is a check that calls an unconverged run converged.

## 3. How it is executed

```
tests/run_all.sh test_18_vasp_check
```

Four runs on 4 ranks, a few minutes in total, plus an empty directory.

| case | must say | why this one |
|---|---|---|
| **Si** | 0 partially occupied states, gap ≈ 0.6 eV, converged | the ordinary healthy run |
| **Al** | partially occupied states > 0, printed next to any gap, and that gap below the smearing width | a checker that finds a gap everywhere passes Si and fails here |
| **Fe** | a magnetization section, net moment ≈ 2.2 μB | a checker that ignores `ISPIN` reports no moment |
| **Si, `NELM = 2`, `EDIFF = 1E-8`** | `[FAIL] SCF reached NELM=2`, exit code 1 | the run completes and writes a perfectly normal OUTCAR |
| all four reports | no physical label and no advice | the report is data; the conclusions are the reader's |

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
Si: no partially occupied state; gap 0.5975 eV; converged
Al: 177 partially occupied states; a gap of 0.03 eV (pymatgen reads 0.000),
    below the 0.2 eV smearing width, printed next to that count
Fe: magnetization section present; net moment 2.2410 uB
Si with NELM=2: [FAIL] SCF reached NELM=2 ...; exit code 1
no report carries a physical label or advice
an empty directory: no crash, reported as having nothing to check
```

Two package defects came out of the rewrite, both older than it. The shortest
nearest-neighbour distance of a one-atom cell (Al, Fe) printed as `inf`: it was
computed between distinct sites only, missing the atom's own periodic images.
And the check "occupied bands match NELECT" fired a warning on every metal,
where that count is a threshold rather than a number of electrons. It now
applies only when no band is partially occupied.

On the first run of this test, two assertions failed; both were **my own**.


## 6. Pass / fail criterion

| quantity | tolerance | what it excludes |
|---|---|---|
| Si gap | 0.6 ± 0.25 eV | 0.0 (gap washed out) and 1.17 (the experimental value) |
| Fe moment | 2.2 ± 0.4 μB | 0.0, which is what a lost `ISPIN` gives |
| Al gap | < 0.2 eV (the smearing width) | any invented gap |

A gap printed for aluminium is not by itself a failure — 0.03 eV is the k-mesh,
not a gap — but printing it **without the partially-occupied count next to it**
is, because a reader who sees only that line is misled.

**What is not asserted:** whether the numbers are good physics. PBE
underestimates semiconductor gaps by roughly a factor of two; that is a
property of the functional, not a defect in the checker. The test asserts that
`vasp-check` reports what the run contains.

## 7. Verdict

**PASSED** — 13 assertions, 0 failed. See `logs/run.log`; each case keeps its
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
