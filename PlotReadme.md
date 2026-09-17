# vasp-plot-fatbandsdos

Publication-ready **fat-band + DOS** figures from a standard VASP run. The band
panel encodes projection weight as **marker opacity** (rgb/duo/one_orbital/cmyk)
or **circle area** (stacked); the DOS panel shares the energy axis and is
projected onto the same atom/orbital groups. Energies are referenced to
E_F = 0; spin polarisation and SOC are detected automatically.

---

## 1. Folder layout

```
<root>/
    Scf/    vasprun.xml             # reference Fermi level (dense SCF)
    Bands/  vasprun.xml  KPOINTS    # line-mode bands, LORBIT=11
    Dos/    vasprun.xml             # dense-mesh DOS, LORBIT=11
```
Output is written to `<root>/Plots/fatbands_dos.{png,pdf}` plus a text
`analysis_report.txt` summarising structure, gap, projections and INCAR tags.
(Sub-folder names are set at the top of the script: `SCF_DIR`, `BANDS_DIR`,
`DOS_DIR`, `OUT_DIR`.)

> **LORBIT:** use `LORBIT = 11` for the Bands and DOS runs so lm-resolved
> orbitals (`px`, `dz2`, …) are available. `LORBIT = 10` (s/p/d sums) still
> works for `s`, `p`, `d`, `f` groups.

---

## 2. Quick start

```bash
# step 1 — inspect species, atom tokens, and available orbitals
vasp-plot-fatbandsdos --root . --list

# step 2 — plot with a chosen method (--method is REQUIRED)
vasp-plot-fatbandsdos --root . --method rgb \
    --projections "(Cu-d),(V-d),(S-p)" \
    --title "MoS_2 - G_0W_0"
```

With no `--projections`, the script colours one group per element so you always
get a figure to sanity-check first.

---

## 3. `--method` (REQUIRED)

A **very thin, very pale grey backbone** traces every band in the background of
*every* method (it is the only line drawn by `plain`). Method names are
case-insensitive and accept `-`/space for `_` (e.g. `One_Orbital`, `one-orbital`).

| Method | Groups | Encodes |
|--------|--------|---------|
| `plain` | 0 | no projection: pale backbone + a small **solid black circle at every k-point** where eigenvalues were computed; DOS shows the total only |
| `one_orbital` | exactly 1 | **pure-blue** circles; opacity = w_group / w_total (the duo/rgb opacity law with a single channel) |
| `duo` | exactly 2 | gradient between two vivid colours; opacity = total weight |
| `rgb` | 1–3 | additive RGB: colour = relative mix of groups; opacity = total weight |
| `cmyk` | exactly 4 | subtractive **CMYK** mix (group 0→cyan, 1→magenta, 2→yellow, 3→black); opacity = total weight. A 4-orbital generalisation of `rgb` |
| `stacked` | any number | sumo-style circles; area proportional to weight² |

```bash
vasp-plot-fatbandsdos ... --method plain        # no projection; black k-point dots
vasp-plot-fatbandsdos ... --method one_orbital  # 1 group -> pure-blue circles
vasp-plot-fatbandsdos ... --method duo          # exactly 2 groups
vasp-plot-fatbandsdos ... --method rgb          # up to 3 groups -> R / G / B
vasp-plot-fatbandsdos ... --method cmyk         # exactly 4 groups -> C / M / Y / K
vasp-plot-fatbandsdos ... --method stacked      # any number of groups
```

The **`cmyk`** colour at each point is the CMYK→RGB conversion of the four
normalised group weights `(C,M,Y,K)`:
`R=(1-C)(1-K), G=(1-M)(1-K), B=(1-Y)(1-K)`. A band dominated by group 0 shows
cyan, group 1 magenta, group 2 yellow, group 3 black; opacity still tracks the
combined weight of the four groups relative to the total.

### Auto-pick projections over an energy window (`--auto-projections N`)

Instead of giving `--projections`, let the tool choose the `N` most-important
`(element, dominant-l)` units over `[--emin, --emax]`. "Most important" is the
**projected DOS integrated over the window** (a proper states integral, summed
over spin) — a faithful, reproducible measure of which orbitals dominate the
range. For the fixed-count methods `N` is implied (`one_orbital`→1, `duo`→2,
`rgb`→3, `cmyk`→4); `stacked` takes the `N` you pass. If the cell has fewer
distinct elements than `N`, selection falls back to inequivalent **Wyckoff
sites** of the same element (`Pt1-d, Pt2-d, …`), always in descending
contribution order.

```bash
# the dominant orbital character between -3 and +3 eV, as pure-blue fat bands:
vasp-plot-fatbandsdos --root . --method one_orbital --auto-projections 1 \
    --emin -3 --emax 3 --name homo_character

# top-3 elements by window weight, as RGB:
vasp-plot-fatbandsdos --root . --method rgb --auto-projections 3 --emin -6 --emax 6
```

`--name BASENAME` controls the output filename written under `Plots/`
(default `fatbands_dos`).

### `vasp-quick-plots` — one figure per method, organised into folders

```bash
conda activate wolfpack-dft
vasp-quick-plots --emin -6 --emax 6 --title "MoS_2"
vasp-quick-plots --methods plain,rgb,cmyk          # subset
vasp-quick-plots --stacked-n 6                      # 6 units in the stacked plot
```

`vasp-quick-plots` runs `vasp-plot-fatbandsdos` once per method with the right
`--auto-projections` count, writing each method into its own numbered sub-folder
of `Plots/` (and keeps going if one method fails):

```
Plots/
  0_Plain/     1_ONE/     2_DUO/     3_RGB/     4_CMYK/     5_Stacked/
```

`5_Stacked` auto-picks the **5** most-contributing units (override `--stacked-n`).

**Spin routing (ISPIN=2):**

- `--spin both` → every folder gets separate **spin-up** and **spin-down** plots
  (`rgb_up`, `rgb_down`, …). `0_Plain` **additionally** gets the overlaid
  blue/orange plain plot (`plain_overlay`).
- `--spin up` / `--spin down` → every folder gets only that one channel.

---

## 4. `--projections` syntax

Comma-separated, parenthesised groups: `(ATOM-ORBITAL),(ATOM-ORBITAL),...`

| Part | Examples | Meaning |
|------|----------|---------|
| **ATOM** | `Cu` | all atoms of element Cu |
| | `S1`, `S2`, `S3` | the 1st / 2nd / 3rd inequivalent S site (1-based) |
| **ORBITAL** | `s` `p` `d` `f` | orbital group (`f` only if the run stored it) |
| | `px` `dz2` … | a specific lm orbital (needs `LORBIT=11`) |
| | `d+s` | several orbitals combined with `+` |
| *(omitted)* | `(Cu)` | sum over all orbitals of that atom |

**Site numbering:** how `S1`, `S2`, … are assigned is controlled by `--group`
(default: symmetry-inequivalent Wyckoff orbits from spglib). Run `--list` to
see the exact per-site assignment before plotting.

### Projection errors
Clear, actionable errors are raised for:
```
(Y-d)     Atom of species "Y" was not found. Species present: Cu, V, S.
(S4-p)    Requested S4, but only 3 inequivalent S sites exist.
(Cu-f)    The "f" orbital is not available (projections contain only s, p, d).
(Cu-dz2)  Orbital "dz2" needs lm-resolved projections (LORBIT=11).
(Cu-xyz)  Unknown orbital "xyz". Use s, p, d, f or a specific lm orbital.
```

---

## 5. Titles (journal style)

`--title` accepts a light TeX-ish string with upright element/letter runs and
neat subscripts:

| Input | Renders as |
|-------|-----------|
| `MoS_2 - G_0W_0` | MoS₂ – G₀W₀ |
| `MoS_2 monolayer` | MoS₂ monolayer |
| `Fe_{12}O_{19}` | Fe₁₂O₁₉ |

With no `--title` the reduced formula is used; `--no-title` suppresses it.

---

## 6. All CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--root PATH` | `.` | calculation root containing `Scf/ Bands/ Dos/` |
| `--list` | – | print species / atom tokens / orbitals, then exit |
| **`--method {plain,one_orbital,duo,rgb,cmyk,stacked}`** | **(REQUIRED)** | projection method (see §3) |
| `--projections "..."` | auto (one group/element) | atom+orbital groups (see §4) |
| `--auto-projections N` | `0` (off) | auto-pick the top-N `(element, l)` units over the window (see §3) |
| `--name BASENAME` | `fatbands_dos` | output base filename written under `Plots/` |
| `--subdir NAME` | – | write into `Plots/NAME/` (used by `vasp-quick-plots`) |
| `--spin {both,up,down}` | `both` | ISPIN=2: choose spin channel(s). Ignored for ISPIN=1 (one channel; see below). |
| `--no-overlay-plain` | (overlay on) | for `--spin both`, do **not** also write the overlaid blue/orange plain plot |
| `--title "..."` | reduced formula | journal-style title (see §5) |
| `--no-title` | – | suppress the title |
| `--emin` / `--emax` | auto-fit to bands | energy window (eV, rel. E_F); also bounds `--auto-projections` |
| `--group {symmetry,formula,element}` | `symmetry` | how S1/S2/… map to atoms |
| `--symprec F` | `0.01` Å | spglib tolerance for `--group symmetry` |
| `--markers N` | `0` (one per k-pt) | subsample markers on a dense k-path |
| `--marker-size F` | `3.0` pt² | fixed circle area (rgb/duo/one_orbital/cmyk); weight → opacity |
| `--plain-marker-size F` | `4.0` pt² | black k-point circle area (plain) |
| `--alpha-min F` | `0.06` | min opacity at zero weight (rgb/duo/one_orbital/cmyk) |
| `--alpha-max F` | `1.0` | max opacity at full weight (rgb/duo/one_orbital/cmyk) |
| `--circle-size F` | `45` | circle area scale factor (stacked) |
| `--pickle` | off | also save the figure as `.fig.pkl` for later editing |
| `--formats png,pdf` | `png,pdf` | comma-separated output formats |
| `--dpi` | `300` | raster DPI |
| `--figw` / `--figh` | `8.2` / `5.2` in | figure size |
| `--font {sans-serif,serif}` | `sans-serif` | `serif` ≈ Times / PRB look |

> **Note:** `--smear`, `--fatness`, and `--no-normalize` are **not** CLI flags.
> DOS smearing is set automatically from `Dos/INCAR` (ISMEAR / SIGMA); a light
> Gaussian is applied only if no INCAR is found. These parameters are available
> when calling `generate()` from Python.

### Spin polarisation (ISPIN)

The plotter detects ISPIN automatically:

- **ISPIN = 1** (non spin-polarised): one channel. `--spin` is meaningless and
  is ignored (a single set of bands/DOS is drawn); passing `--spin up/down`
  prints a harmless note rather than an error.
- **ISPIN = 2** (collinear spin):
  - `--spin up` / `--spin down` draws that one channel with the **standard
    circles** (normal colour/opacity, no special markers or edges), written as
    `<name>_up` / `<name>_down`.
  - `--spin both` writes **three** figures: the spin-up plot, the spin-down plot
    (each in the chosen method), **and** a dedicated **overlaid plain plot**
    `<name>_overlay`.
- **ISPIN ≥ 3** (non-collinear / spinor, 4 components): not implemented — the
  tool stops with a clear message instead of producing a wrong figure.

> The previous cyan/magenta up/down **triangle** styling has been **removed**;
> the two channels are never overlaid in a projected figure any more.

**The overlaid plain plot (`--spin both`).** Both channels in one *plain* plot
(no projections): spin-up bands are **pure-RGB blue**, spin-down **vivid
orange**, drawn as the usual slightly-translucent plain circles. The single grey
backbone is replaced by **two per-spin backbones** — very thin, **dashed**,
highly transparent, pale blue (up) and pale orange (down). The DOS panel mirrors
the two channels (up positive/blue, down negative/orange).

**Stacked + both spins.** `--method stacked --spin both` follows the same rule:
one stacked figure per spin (`<name>_up`, `<name>_down`) plus the overlaid plain
plot. The stacked mode faithfully reproduces **sumo**'s algorithm (per-point
weights normalised over the selected groups, spline-interpolated bands, circle
**area = `circle_size · w²`**, sumo colour cycle, weights below the projection
cutoff dropped).

---

## 7. Python API

```python
from vasp_plot_fatbandsdos import generate

fig, axes = generate(root="path/to/calc",
                     method="rgb",
                     projections="(Cu-d),(S-p)",
                     title="MoS_2", return_axes=True)
axes["bands"][0].set_ylim(-2, 2)    # tweak anything
fig.savefig("custom.pdf")
```

Or reload a pickled figure (written with `--pickle`):
```python
import pickle, matplotlib.pyplot as plt
fig = pickle.load(open("Plots/fatbands_dos.fig.pkl", "rb"))
fig.axes[0].set_title("edited"); fig.savefig("edited.png")
```

`generate()` accepts the same parameters as the CLI flags plus:
- `smear` — explicit Gaussian broadening σ (eV); `None` = auto from INCAR
- `emin`, `emax` — float or `None` (auto-fit)
- `return_data` — also return the parsed bands/DOS dicts

---

## 8. Install & package layout

Install the whole toolkit (this command included) with the repo installer:

```bash
cd WolfPack-DFT
./install.sh                 # symlinks the command + creates env 'wolfpack-dft'
conda activate wolfpack-dft  # provides pymatgen/numpy/matplotlib/scipy
```

The command `vasp-plot-fatbandsdos` is a `~/.local/bin` symlink to
`vasp_plot_fatbandsdos.py`. That file is a **thin master shim**: the real code
lives in the sibling `wolfpack_plot/` package, and the shim adds its own
(symlink-resolved) directory to `sys.path` so the package imports correctly even
when run through the symlink. Edits to any module take effect immediately — but
**keep `vasp_plot_fatbandsdos.py` next to the `wolfpack_plot/` folder.**

```
WolfPack-DFT/
    vasp_plot_fatbandsdos.py     # master entry point (command + import shim)
    wolfpack_plot/
        config.py      formatting.py   structure.py   vaspio.py
        physics.py     plotting.py     core.py        __init__.py
```

---

## 9. Troubleshooting

- **`fat bands will not be drawn`** — the Bands run has no projections; rerun
  with `LORBIT=11`. The DOS panel still works from the DOS run.
- **Garbled or missing high-symmetry labels** — labels come from your line-mode
  `Bands/KPOINTS`; make sure every segment endpoint is labelled after `!`.
- **Wrong Fermi level** — E_F is read from `Scf/` (vasprun → OUTCAR), falling
  back to `Bands/` only if necessary; point `--root` at a run with a dense SCF.
- **`--method rgb` error with > 3 groups** — rgb encodes at most 3 channels;
  use `--method stacked` for more groups or narrow your `--projections`.

## Where you run it: the workflow tree, or one calculation

**Nothing changes for the classic layout.** If the folder you point at contains
`Bands/` and `Dos/`, it is treated exactly as before -- the combined band-structure +
DOS figure, same code path, same look. That check runs first and short-circuits; the
`INCAR` is not even consulted.

Only when there is **no** `Bands/`+`Dos/` tree does the plotter fall back to inspecting
the folder itself, so you can stand inside a single calculation. It then creates
`Plots/` and writes only the figures that folder can support:

| what the folder holds | how it is recognised | what you get |
|---|---|---|
| the classic tree | `Bands/` + `Dos/` exist | combined bands + DOS (unchanged) |
| band structure | `KPOINTS` is line-mode (a k-path) | a standalone band-structure figure |
| density of states | regular k-mesh **and** `ISMEAR<=-4` / `NEDOS` / `LORBIT>=10` / `ICHARG>=10` | a standalone DOS figure (energy on the x-axis) |
| Wannier90 output | any `*_band.dat` / `*-dos.dat` present | the interpolated bands and/or DOS |

`vasp-quick-plots` behaves the same way: every method folder (`0_Plain` ... `5_Stacked`)
is filled with the plots that folder supports, with the same automatic projections.

```bash
cd 3_Dos            # a DOS run, no Scf/Bands/Dos tree
vasp-quick-plots    # -> Plots/{0_Plain,...}/  with DOS plots only
```

## Wannier90 (interpolated bands and DOS)

Point the plotter at a Wannier90 folder and it reproduces the same figures as vanilla
VASP with **nothing else to specify**:

```bash
cd 4_Wann
vasp-plot-fatbandsdos --method plain     # or: vasp-quick-plots
```

It reads `seedname_band.dat` (band-outer blocks: k-distance, energy), takes the
high-symmetry labels and their positions from the `set xtics (...)` line of
`seedname_band.gnu` (falling back to the `kpoint_path` block of the `.win`), and reads
`seedname-dos.dat` (energy, total, plus the spin-up/down columns when `spin_decomp` is on).

**Wannier90 energies are absolute**, so the Fermi level is resolved automatically:
`fermi_energy` in the `.win` -> a VASP run in the same folder -> a VASP run in the parent
folder (the DFT step the Wannierisation came from). Override with `--efermi`.

Interpolated bands are drawn as continuous curves rather than per-k-point markers,
because they are an interpolation onto a dense path, not computed eigenvalues.
