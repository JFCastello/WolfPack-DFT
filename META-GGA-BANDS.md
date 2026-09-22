# Bands + DOS with a meta-GGA (r2SCAN) in VASP 6.5.1

How the plotting flow differs from PBE/PBEsol, why, and what WolfPack-DFT
detects on its own. Everything here is either quoted from the VASP wiki or
read out of the VASP 6.5.1 source in `Vasp.6.5.1/src/`; sources at the end.

---

## 1. Why the PBE recipe does not work

The usual band-structure recipe is two runs:

1. self-consistent SCF on a regular mesh → `CHGCAR`
2. non-self-consistent run along the k-path with `ICHARG = 11`, reading that
   frozen `CHGCAR`

Step 2 **cannot be done with a meta-GGA**. r2SCAN is not a functional of the
density alone: it also depends on the kinetic-energy density τ(r), and τ is
not stored in `CHGCAR`. There is nothing to reconstruct it from at the new
k-points.

VASP does not let you try. `Vasp.6.5.1/src/fock.F:457`:

```fortran
IF ( XC%LDOMETAGGA .AND. ICHARG >= 10 ) THEN
   ... "ICHARG>9 is currently not supported for meta-GGA functionals."
```

The wiki says the same thing positively — a regular mesh has to be present so
that τ can be computed:

> For band-structure calculations with METAGGA functionals, follow the same
> procedure as for band-structure calculations using hybrid functionals.
> [...] a regular k mesh has to be provided in order to compute the
> kinetic-energy density.

So the k-path points have to ride along **inside a self-consistent run** that
also carries a regular mesh. Two ways to do that.

---

## 2. The recommended way: `KPOINTS_OPT` (VASP ≥ 6.3)

One run. `KPOINTS` holds the regular mesh that drives self-consistency;
`KPOINTS_OPT` holds the high-symmetry path. VASP converges on the mesh, then
does a one-shot diagonalisation at the path k-points:

> VASP first performs a self-consistent calculation using the k points
> specified in the KPOINTS file and then performs an additional one-shot
> calculation to obtain the Kohn–Sham orbitals and eigenenergies at the k
> points specified in the KPOINTS_OPT file.

### INCAR

```
SYSTEM  = Si r2SCAN bands + DOS
METAGGA = R2SCAN
LASPH   = .TRUE.      # required for accuracy: aspherical PAW one-centre terms
PREC    = Accurate
ENCUT   = 520         # meta-GGAs want a harder cutoff than PBE
ALGO    = All         # damped/all is steadier than blocked-Davidson for tau
EDIFF   = 1E-6
ISMEAR  = 0 ; SIGMA = 0.05
LORBIT  = 11          # orbital projections -> fat bands and site/orbital DOS
NEDOS   = 3001        # a smooth DOS from the same run
LWAVE   = .FALSE. ; LCHARG = .FALSE.
```

`LASPH` is the one the wiki calls out by name:

> For accuracy, it is strongly recommended to set LASPH=.TRUE. to account for
> aspherical contributions to the PAW one-centre terms.

The POTCAR must carry the core kinetic-energy density. The modern PAW sets do;
you can check with `grep -c "kinetic energy-density" POTCAR` (expect ≥ 1).

### KPOINTS — the mesh that makes τ

```
regular mesh (drives the SCF and the DOS)
0
Gamma
 11 11 11
  0  0  0
```

### KPOINTS_OPT — the path that makes the bands

```
k-points along L-G-X-U|K-G
40
line
reciprocal
  0.50000 0.50000 0.50000   1
  0.00000 0.00000 0.00000   1

  0.00000 0.00000 0.00000   1
  0.00000 0.50000 0.50000   1

  0.00000 0.50000 0.50000   1
  0.25000 0.62500 0.62500   1

  0.37500 0.75000 0.37500   1
  0.00000 0.00000 0.00000   1
```

### Where the results land — and this is the part the wiki does not spell out

A `KPOINTS_OPT` run writes **no `EIGENVAL_OPT` and no `DOSCAR_OPT`**. A grep
over all 400-odd `.F` files of VASP 6.5.1 turns up exactly one extra output
file. From `Vasp.6.5.1/src/linear_response.F`:

| what | where | source line |
|---|---|---|
| path eigenvalues | `vasprun.xml`, tag `<eigenvalues_kpoints_opt>` | `linear_response.F:1835` |
| path projections | `vasprun.xml`, tag `projected_kpoints_opt` | `linear_response.F:1862` |
| path projections | `PROCAR_OPT` (only when `LORBIT > 10`) | `linear_response.F:1863` |
| mesh DOS | `vasprun.xml` `<dos>`, `DOSCAR` | normal output |
| both, HDF5 | `vaspout.h5`, groups `electron_eigenvalues_kpoints_opt`, `electron_dos_kpoints_opt` | `linear_response.F:1844-1846` |

**One `vasprun.xml` therefore holds both halves of the figure**: the DOS from
the regular mesh, and the bands from the path. That is the key difference from
PBE, where they come from two different folders.

---

## 3. The legacy way: zero-weighted k-points

Before 6.3, and still valid: append the path points to the mesh in a single
`KPOINTS` file with **weight 0**, so they are diagonalised but do not enter the
density or the Fermi level.

```
cp IBZKPT KPOINTS      # the irreducible mesh, with its weights
# then append the path points with weight 0, and fix the count on line 2
```

Set `NELMIN` to at least 5 so the zero-weight points cannot end the SCF early.
This works, but everything lands in the ordinary `EIGENVAL`/`PROCAR` mixed in
with the mesh points, so the plotting tool has to separate them by weight.
`KPOINTS_OPT` keeps them apart for you, which is why it is preferred here.

---

## 4. What WolfPack-DFT does with this

Nothing extra to type. `vasp-quick-plots` reads the INCAR and the k-point files
and decides:

- `METAGGA` set **and** `KPOINTS_OPT` present → the self-consistent one-run
  scheme. High-symmetry labels are taken from `KPOINTS_OPT`, not from the mesh
  `KPOINTS`; the DOS is taken from the mesh in the same `vasprun.xml`. One
  combined bands+DOS figure, exactly as for a PBEsol `Scf/ Bands/ Dos/` tree.
- `METAGGA` set **and** `ICHARG >= 10` → a loud `WRONG RECIPE` banner. VASP
  refuses this combination outright, but if the numbers came from somewhere
  else the figure would look perfectly normal, so a quiet note would be read
  as "fine".
- `METAGGA` set **and** a line-mode `KPOINTS` with no `KPOINTS_OPT` → same
  banner: τ cannot be built from a bare path.

The classic PBE/PBEsol three-folder tree keeps working unchanged.

---

## Sources

- [Band-structure calculation using meta-GGA functionals — VASP Wiki](https://vasp.at/wiki/index.php/Band-structure_calculation_using_meta-GGA_functionals)
  — "follow the same procedure as for hybrid functionals"; "a regular k mesh
  has to be provided in order to compute the kinetic-energy density".
- [KPOINTS_OPT — VASP Wiki](https://vasp.at/wiki/index.php/KPOINTS_OPT) — the
  one-shot-after-SCF description, available as of VASP 6.3.0; `PROCAR_OPT`
  written when `LORBIT>10`; `vaspout.h5` fields marked `_kpoints_opt_`.
- [METAGGA — VASP Wiki](https://www.vasp.at/wiki/index.php/METAGGA) — `LASPH`
  strongly recommended; POTCARs must include the core kinetic-energy density.
- [Si bandstructure — VASP Wiki](https://vasp.at/wiki/Si_bandstructure) — the
  Si POSCAR and the L-G-X-U|K-G path used above.
- VASP 6.5.1 source, read directly for the output-file names and the ICHARG
  guard: `src/fock.F:457-459`, `src/linear_response.F:1833-1863`.
