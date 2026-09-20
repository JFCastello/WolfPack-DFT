#!/usr/bin/env python3
"""
wolfpack_structure.py -- what a relaxation actually did to the structure.

Used by vasp-check; also runnable on its own:

    wolfpack_structure.py POSCAR CONTCAR     # before -> after
    wolfpack_structure.py POSCAR             # one structure, no comparison

==================================================================
WHY
==================================================================
"reached required accuracy" tells you the forces are small. It does not tell
you WHAT the relaxation did, and that is usually the thing worth knowing: a run
can converge beautifully onto a structure that is not the one you meant to
study. The cell can collapse or balloon, an atom can hop to a different site,
the symmetry can rise (ISYM freezing you into a saddle point) or fall (the
distortion you were hoping for, or a broken run). None of that shows up in the
force table.

So: space group before and after, at several tolerances; how far every atom
moved, with the biggest movers named; how the cell changed, as lengths, angles,
volume and a strain tensor; and what happened to the nearest-neighbour bonds.

==================================================================
HOW DISPLACEMENTS ARE MEASURED
==================================================================
VASP writes CONTCAR with the same site order as the POSCAR it started from, so
atom i is atom i -- no structure matching is needed or wanted here.

The displacement is the difference in FRACTIONAL coordinates, wrapped to the
nearest periodic image, then taken into Angstrom with the FINAL lattice. Doing
it that way separates the two things that move: the cell (reported on its own as
strain) and the atoms inside it. Measuring Cartesian positions directly would
mix them, so a pure uniform expansion would look like every atom having moved.
"""

import sys

import numpy as np

SYMPRECS = (1e-5, 1e-3, 1e-2, 0.1)   # 1e-5 is what VASP itself uses for ISYM


def _sg(struct, symprec):
    try:
        return struct.get_space_group_info(symprec=symprec)
    except Exception:
        return ("?", 0)


def _spacegroups(struct):
    return {p: _sg(struct, p) for p in SYMPRECS}


def _nn_distances(struct):
    """Shortest distance from each site to any other, in site order."""
    d = struct.distance_matrix.copy()
    np.fill_diagonal(d, np.inf)
    return d.min(axis=1)


def _fmt_sg(sgs):
    return "   ".join(f"{p:g}: {n} ({i})" for p, (n, i) in sgs.items())


def describe(struct, label="structure", out=print):
    """Everything worth saying about ONE structure."""
    lat = struct.lattice
    out(f"  {label}")
    out(f"    formula        : {struct.composition.reduced_formula}"
        f"   ({len(struct)} sites, {struct.composition.formula})")
    out(f"    a b c   (A)    : {lat.a:.6f}  {lat.b:.6f}  {lat.c:.6f}")
    out(f"    alpha beta gam : {lat.alpha:.4f}  {lat.beta:.4f}  {lat.gamma:.4f}")
    out(f"    volume  (A^3)  : {lat.volume:.6f}       density: {struct.density:.4f} g/cm^3")
    sgs = _spacegroups(struct)
    out(f"    space group    : {_fmt_sg(sgs)}")
    if sgs[1e-5][1] != sgs[1e-2][1]:
        out(f"    NOTE           : the space group depends on the tolerance -- this cell is"
            f" only APPROXIMATELY at the higher symmetry.")
    nn = _nn_distances(struct)
    out(f"    nearest bond   : {nn.min():.4f} A (shortest in the cell)"
        f"   mean over sites: {nn.mean():.4f} A")


def compare(before, after, out=print, top=8, moved_threshold=1e-4):
    """What changed between two structures with the SAME site order."""
    if len(before) != len(after):
        out(f"  cannot compare: {len(before)} sites before, {len(after)} after.")
        return
    if [s.specie.symbol for s in before] != [s.specie.symbol for s in after]:
        out("  cannot compare: the species order differs between the two files.")
        return

    la, lb = before.lattice, after.lattice

    # ---- the cell ---------------------------------------------------------
    out("  CELL")
    for name, x, y, unit in (
        ("a", la.a, lb.a, "A"), ("b", la.b, lb.b, "A"), ("c", la.c, lb.c, "A"),
        ("alpha", la.alpha, lb.alpha, "deg"), ("beta", la.beta, lb.beta, "deg"),
        ("gamma", la.gamma, lb.gamma, "deg"),
        ("volume", la.volume, lb.volume, "A^3"),
    ):
        pct = 100.0 * (y - x) / x if abs(x) > 1e-12 else 0.0
        flag = "" if abs(pct) < 0.05 else ("   <-- " + ("expanded" if pct > 0 else "contracted"))
        out(f"    {name:<8s} {x:14.6f} -> {y:14.6f} {unit:<4s} "
            f"({y - x:+.6f}, {pct:+.3f} %){flag}")

    # Green-Lagrange strain: F = L_after . L_before^-1, E = (F^T F - I)/2.
    # Symmetric and rotation-free, so a cell that was merely re-oriented shows
    # zero strain instead of a spurious shear.
    try:
        F = np.linalg.inv(la.matrix) @ lb.matrix
        E = 0.5 * (F.T @ F - np.eye(3))
        out("    strain (Green-Lagrange, %):")
        for row in E:
            out("      " + "  ".join(f"{100 * v:+9.4f}" for v in row))
        out(f"    max |strain|   : {100 * np.abs(E).max():.4f} %")
    except np.linalg.LinAlgError:
        pass

    # ---- symmetry ---------------------------------------------------------
    sa, sb = _spacegroups(before), _spacegroups(after)
    out("  SYMMETRY")
    for p in SYMPRECS:
        arrow = "->" if sa[p][1] == sb[p][1] else "=>"
        change = "" if sa[p][1] == sb[p][1] else (
            "   CHANGED, symmetry " + ("ROSE" if sb[p][1] > sa[p][1] else "FELL"))
        out(f"    symprec {p:<7g}: {sa[p][0]:>10s} ({sa[p][1]:3d}) {arrow} "
            f"{sb[p][0]:>10s} ({sb[p][1]:3d}){change}")
    if sa[1e-5][1] != sb[1e-5][1]:
        out("    ^ at 1e-5, which is the tolerance VASP itself uses for ISYM. A rise means")
        out("      the relaxation found a more symmetric structure; with ISYM>0 it can also")
        out("      mean it was never allowed to leave one.")

    # ---- displacements ----------------------------------------------------
    # Fractional difference, minimum image, then into Angstrom with the FINAL
    # lattice -- see the module docstring for why not Cartesian directly.
    df = after.frac_coords - before.frac_coords
    df -= np.round(df)
    disp = df @ lb.matrix
    dist = np.linalg.norm(disp, axis=1)

    out("  ATOMIC DISPLACEMENTS  (periodic images resolved; cell change excluded)")
    out(f"    max            : {dist.max():.4f} A        "
        f"mean: {dist.mean():.4f} A        RMS: {np.sqrt((dist ** 2).mean()):.4f} A")
    per = {}
    for site, d in zip(before, dist):
        per.setdefault(site.specie.symbol, []).append(d)
    for el, v in sorted(per.items()):
        v = np.array(v)
        out(f"    {el:<4s} n={len(v):<4d} max {v.max():.4f}   mean {v.mean():.4f}   "
            f"RMS {np.sqrt((v ** 2).mean()):.4f} A")

    order = np.argsort(-dist)
    n_moved = int((dist > moved_threshold).sum())
    out(f"    {n_moved} of {len(dist)} atoms moved more than {moved_threshold} A")
    if n_moved:
        out(f"    biggest movers (index, species, distance, direction in fractional coords):")
        for i in order[:top]:
            if dist[i] <= moved_threshold:
                break
            out(f"      #{i + 1:<4d} {before[i].specie.symbol:<3s} {dist[i]:8.4f} A"
                f"   d(frac) = [{df[i][0]:+.5f} {df[i][1]:+.5f} {df[i][2]:+.5f}]")

    # A uniform shift of every atom is a change of origin, not of structure.
    drift = disp.mean(axis=0)
    if np.linalg.norm(drift) > 1e-4:
        out(f"    centre-of-coordinates drift: {np.linalg.norm(drift):.4f} A "
            f"[{drift[0]:+.4f} {drift[1]:+.4f} {drift[2]:+.4f}]  "
            f"(a rigid shift is a change of origin, not of geometry)")

    # ---- bonds ------------------------------------------------------------
    na, nb = _nn_distances(before), _nn_distances(after)
    out("  NEAREST-NEIGHBOUR BONDS")
    out(f"    shortest in cell : {na.min():.4f} -> {nb.min():.4f} A "
        f"({nb.min() - na.min():+.4f})")
    out(f"    mean over sites  : {na.mean():.4f} -> {nb.mean():.4f} A "
        f"({nb.mean() - na.mean():+.4f})")
    if nb.min() < 0.8 * na.min():
        out("    WARNING: the shortest bond collapsed by more than 20 % -- check the geometry")
        out("             before trusting anything else in this run.")


def report(before_path, after_path=None, out=print):
    """Print the whole report. `after_path` None -> describe one structure."""
    from pymatgen.core import Structure

    before = Structure.from_file(before_path)
    if after_path is None:
        describe(before, f"{before_path}", out=out)
        return
    after = Structure.from_file(after_path)
    describe(before, f"BEFORE  ({before_path})", out=out)
    out("")
    describe(after, f"AFTER   ({after_path})", out=out)
    out("")
    out("  " + "-" * 72)
    out(f"  WHAT CHANGED  ({before_path} -> {after_path})")
    out("  " + "-" * 72)
    compare(before, after, out=out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        report(args[0], args[1] if len(args) > 1 else None)
    except Exception as exc:                      # a report is never worth a crash
        print(f"  structure report unavailable: {type(exc).__name__}: {exc}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
