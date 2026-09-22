# test_01_cases

> the benchmark structures themselves, checked against published PBE values

## 1. Definition

Verifies the five reference cells every other test quotes numbers from: first
their crystallography, then — by running VASP — the physical quantity each one
exists to provide.

## 2. Purpose

Every other test in this suite takes a number from one of these cells. If a
cell is wrong, every test downstream is wrong with it **and all of them still
pass**. So the structures are verified before anything is built on them.

## 3. How it is executed

```
tests/run_all.sh test_01_cases
```

Builds the cells with `pymatgen` from space group + Wyckoff positions, checks
their site counts and space groups, then runs VASP on Fe, Si and Al.
About two minutes on 4 ranks.

## 4. Expected results

| case | sites | exercises | reference | source |
|---|---|---|---|---|
| Si diamond | 2 | a semiconductor | indirect gap ≈ 0.6 eV (PBE/PAW) | [1] |
| Al fcc | 1 | a free-electron metal | **no gap** | [2] |
| MgO rocksalt | 2 | a wide-gap insulator | gap ≈ 4.5 eV | [1] |
| Fe bcc | 1 | an itinerant ferromagnet | **2.2 μB/atom** | [3] |
| NiO rocksalt AFM-II | **4** | DFT+U, AFM ordering | gap opens with U | [4] |

Si and Al are the pair that matters: **opposite answers through the same code
path**. A tool that invents a gap passes Si and fails Al; one that smears gaps
away passes Al and fails Si.

NiO is four sites deliberately — AFM-II does not exist in a 2-atom cell, so a
2-site NiO would make `test_10_magnetic` silently test a different ordering.

## 5. Obtained results

| quantity | measured | published |
|---|---|---|
| Fe moment | **2.241 μB** | 2.2 μB (PBE); 2.22 experiment |
| Si indirect gap | **0.598 eV** | ≈0.6 eV (PBE/PAW); 1.17 experiment |
| Al gap | **0.000 eV** | metal, no gap |

Crystallography: Si 2 sites Fd-3m, Al 1 Fm-3m, MgO 2 Fm-3m, Fe 1 Im-3m,
NiO 4 Fm-3m — all as specified.

## 6. Pass / fail criterion

| assertion | tolerance | why |
|---|---|---|
| site count and space group | exact | a different cell is a different test |
| Fe moment | 2.2 ± 0.35 μB | excludes 0.0, which is what a lost `ISPIN` gives |
| Si gap | 0.6 ± 0.25 eV | excludes 0.0 and the 1.17 eV experimental value |
| Al gap | 0.0 ± 0.05 eV | excludes any invented gap |

## 7. Verdict

**PASSED** — 8 assertions, 0 failed. See `logs/run.log`.

## Sources

1. Yang, Peng, Sun & Perdew, Table I — Si: Exp 1.17, LDA 0.60, PBE 0.71
   (all-electron), HSE 1.11, SCAN 0.97 eV. arXiv:1603.00512 —
   <https://arxiv.org/pdf/1603.00512>. VASP/PAW gives ≈0.6 eV.
2. The Si cell and the `L-Γ-X-U|K-Γ` path are the VASP wiki's own example —
   <https://vasp.at/wiki/Si_bandstructure>
3. bcc Fe ≈ 2.2 μB/atom in PBE — arXiv:2012.12763 —
   <https://arxiv.org/pdf/2012.12763>; experimental 2.22 μB (Kittel,
   *Introduction to Solid State Physics*, ch. 12).
4. NiO AFM-II as the ground-state ordering, and the magnetic-enumeration
   method — Horton, Montoya, Liu & Persson, npj Comput. Mater. **5**, 64
   (2019) — <https://www.nature.com/articles/s41524-019-0199-7>

