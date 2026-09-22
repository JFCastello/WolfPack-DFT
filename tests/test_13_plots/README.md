# test_13_plots

> vasp-quick-plots: the figures, and the gap the data behind them carries

## 1. Definition

Runs a real silicon band-structure + DOS calculation, plots it, and checks both
that the figures are real files and that the **number** behind them matches a
published value.

## 2. Purpose

A figure that is merely ugly is a nuisance. A figure that is **wrong** looks
exactly like a right one — same axes, same smooth curves, same labels. So what
is checked is not the appearance but the eigenvalues the plotter is reading:
if the gap they carry is right, the plotter found the right data.

## 3. How it is executed

```
tests/run_all.sh test_13_plots
```

Silicon, 2 atoms — the VASP wiki's own band-structure example — in about a
minute on this laptop:

- `KPOINTS`: Γ-centred 9×9×9 mesh, which drives self-consistency and gives the
  DOS;
- `KPOINTS_OPT`: the `L-Γ-X` path, diagonalised in one shot afterwards;
- `LORBIT = 11`, `NEDOS = 1001`, `ENCUT = 400`, `EDIFF = 1E-6`, `ISMEAR = 0`,
  `SIGMA = 0.05`.

**One job**, and the same `vasprun.xml` carries both halves of the figure: the
bands under `<eigenvalues_kpoints_opt>` and the DOS under the ordinary `<dos>`.

## 4. Expected results

| check | expected |
|---|---|
| a directory with no VASP output | refused, with a message saying what it needs — not a traceback |
| the plotter | no traceback |
| figures | written, and each a real, non-empty PNG |
| the gap in the data plotted | **≈ 0.6 eV** (Si, PBE/PAW) |
| a bands-only folder (no DOS, **no OUTCAR**) | E_F read from the `vasprun.xml` alone; no crash; figures really produced |
| `--auto-projections` in that folder | a **refusal** that says what to do instead, not a traceback |

## 5. Obtained results

| quantity | measured | published |
|---|---|---|
| Si indirect gap | **0.573 eV** | ≈ 0.6 eV (PBE/PAW); 1.17 eV experiment |
| figures written | 4 PNG, all valid | |
| E_F from `vasprun.xml` alone | **6.0288 eV** | identical to the full folder's |
| bands-only figures | **4 PNG** | |

**Two package bugs were found here and fixed:**

- **The Fermi level could never be read from a `vasprun.xml`.** `read_fermi`
  called `Vasprun(..., parse_dos=False, ...)`, and pymatgen assigns
  `Vasprun.efermi` in exactly one place — `self.efermi = self.tdos.efermi`,
  inside the `elif parse_dos and tag == "dos"` branch of `Vasprun._parse` — so
  the attribute was always `None` and that whole branch was dead. It went
  unnoticed because the OUTCAR fallback answers whenever an OUTCAR is present.
  A folder holding a `vasprun.xml` and no OUTCAR — what you have after copying
  a band run off a cluster — could not be plotted at all: **0 figures of 6**.
- **`--auto-projections` in a folder with no DOS died with a traceback.**
  `_resolve_groups` read `dos_data["cdos"]` with `dos_data = None`:
  `TypeError: 'NoneType' object is not subscriptable`, five figures of six.
  It now refuses with a message naming the problem, and `vasp-quick-plots` no
  longer passes a flag that cannot work there — it falls back to the
  documented default of one group per element, which plots.

**What was deliberately NOT done.** Ranking the groups from the *band*
projections instead of the DOS was implemented and then removed. Measured on
the folder that has both, the band-derived ranking calls diamond silicon
**Si-d** where the DOS calls it **Si-p** — s 0.77, p 2.79, d 0.00 from the DOS
against s 10.5, p 10.3, d 23.4 from the bands. Shipping a substitute measure
that disagrees with the one it replaces, on a textbook case, would be this
package deciding the physics. It refuses instead.

## 6. Pass / fail criterion

Gap 0.6 ± 0.25 eV. Loose enough that a differently-converged run passes, tight
enough that a plotter reading the wrong eigenvalues — or washing the gap out
with smearing — does not. The **experimental** 1.17 eV is deliberately outside
the window: PBE underestimates the gap, so a result near 1.17 would mean
something had gone wrong, not right.

Every PNG must be non-zero and carry a valid PNG header.

**What is not judged:** whether the gap is *good*. PBE underestimates
semiconductor gaps by roughly a factor of two; that is a known property of the
functional, not a defect in the plotting. The test checks that the plotter
reports what the calculation contains.

## 7. Verdict

**PASSED** — 10 assertions, 0 failed. See `logs/run.log`.

The figures themselves are not versioned. They are rewritten on every run, and
a megabyte of PNG that changes each time would live in the history for good;
what the test actually asserts about them — that each is a real image, and that
the eigenvalues behind them carry silicon's published gap — is in the log. They
are left in the run's work directory to be looked at.

## Sources

1. The cell and the `L-Γ-X-U|K-Γ` path are the VASP wiki's own example —
   <https://vasp.at/wiki/Si_bandstructure>
2. Si fundamental gap by functional — Exp 1.17, LDA 0.60, PBE 0.71
   (all-electron), HSE 1.11 eV: Yang, Peng, Sun & Perdew, Table I,
   arXiv:1603.00512 — <https://arxiv.org/pdf/1603.00512>.
   VASP/PAW gives ≈ 0.6 eV, the value used here.
3. `KPOINTS_OPT` — one self-consistent run carrying both the mesh and the path:
   <https://vasp.at/wiki/index.php/KPOINTS_OPT>

