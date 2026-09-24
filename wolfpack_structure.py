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
_SP = {1e-5: "1e-5", 1e-3: "1e-3", 1e-2: "1e-2", 0.1: "1e-1"}

# The report is data only: numbers, side by side, with the change. What they
# mean for the calculation is the reader's call, not this script's.
W_NAME, W_VAL = 22, 14


def _sg(struct, symprec):
    try:
        return struct.get_space_group_info(symprec=symprec)
    except Exception:
        return ("?", 0)


def _spacegroups(struct):
    return {p: _sg(struct, p) for p in SYMPRECS}


def _nn_distances(struct):
    """Shortest distance from each site to any other atom, in site order --
    periodic images included, its OWN images too. The distance matrix between
    distinct sites misses those, and gave 'inf' for a one-atom cell."""
    r = 1.5 * (struct.volume / max(len(struct), 1)) ** (1.0 / 3.0)
    for _ in range(5):
        nbrs = struct.get_all_neighbors(r)
        if all(len(n) for n in nbrs):
            return np.array([min(x.nn_distance for x in n) for n in nbrs])
        r *= 2.0
    return np.array([min((x.nn_distance for x in n), default=np.inf) for n in nbrs])


def _cell_rows(struct):
    lat = struct.lattice
    return [("a", "A", lat.a, 6), ("b", "A", lat.b, 6), ("c", "A", lat.c, 6),
            ("alpha", "deg", lat.alpha, 4), ("beta", "deg", lat.beta, 4),
            ("gamma", "deg", lat.gamma, 4), ("volume", "A^3", lat.volume, 4),
            ("density", "g/cm^3", float(struct.density), 4)]


def _z(v, dp):
    """No "-0.0000": a value that rounds to zero prints as zero."""
    return 0.0 if abs(v) < 0.5 * 10.0 ** (-dp) else v


def _sg_text(sg):
    return f"{sg[0]} ({sg[1]})"


def _title(struct):
    c = struct.composition
    return f"{c.reduced_formula}, {len(struct)} sites ({c.formula})"


def describe(struct, label="structure", out=print):
    """ONE structure, as a table."""
    out(f"  {label}   {_title(struct)}")
    out("")
    out("  CELL")
    for name, unit, v, dp in _cell_rows(struct):
        out(f"    {name + ' (' + unit + ')':<{W_NAME - 2}}{v:>{W_VAL}.{dp}f}")
    out("")
    out("  SPACE GROUP")
    for p, sg in _spacegroups(struct).items():
        out(f"    {'symprec ' + _SP[p]:<{W_NAME - 2}}{_sg_text(sg):>{W_VAL}}")
    out("")
    nn = _nn_distances(struct)
    out("  NEAREST NEIGHBOUR (A)")
    out(f"    {'shortest':<{W_NAME - 2}}{nn.min():>{W_VAL}.4f}")
    out(f"    {'mean over sites':<{W_NAME - 2}}{nn.mean():>{W_VAL}.4f}")


def compare(before, after, out=print, top=3, moved_threshold=1e-4,
            names=("POSCAR", "CONTCAR")):
    """What changed between two structures with the SAME site order."""
    if len(before) != len(after):
        out(f"  cannot compare: {len(before)} sites before, {len(after)} after.")
        return
    if [s.specie.symbol for s in before] != [s.specie.symbol for s in after]:
        out("  cannot compare: the species order differs between the two files.")
        return
    # A column header wider than its column would shear the whole table.
    nb, na_ = (n if len(n) <= W_VAL - 2 else n[:W_VAL - 3] + "~" for n in names)
    head = f"{nb:>{W_VAL}}{na_:>{W_VAL}}{'change':>{W_VAL}}{'%':>9}"

    # ---- the cell ---------------------------------------------------------
    out(f"  {'CELL':<{W_NAME}}{head}")
    for (name, unit, x, dp), (_, _, y, _) in zip(_cell_rows(before), _cell_rows(after)):
        pct = _z(100.0 * (y - x) / x if abs(x) > 1e-12 else 0.0, 3)
        out(f"    {name + ' (' + unit + ')':<{W_NAME - 2}}{x:>{W_VAL}.{dp}f}{y:>{W_VAL}.{dp}f}"
            f"{_z(y - x, dp):>+{W_VAL}.{dp}f}{pct:>+8.3f}%")
    # Green-Lagrange strain: F = L_after . L_before^-1, E = (F^T F - I)/2.
    # Symmetric and rotation-free, so a cell that was merely re-oriented shows
    # zero strain instead of a spurious shear.
    la, lb = before.lattice, after.lattice
    try:
        F = np.linalg.inv(la.matrix) @ lb.matrix
        E = 0.5 * (F.T @ F - np.eye(3))
        out(f"    {'max |strain| (%)':<{W_NAME - 2}}{'':>{W_VAL}}{'':>{W_VAL}}"
            f"{100 * np.abs(E).max():>{W_VAL}.4f}   Green-Lagrange")
    except np.linalg.LinAlgError:
        pass
    out("")

    # ---- symmetry ---------------------------------------------------------
    sa, sb = _spacegroups(before), _spacegroups(after)
    out(f"  {'SPACE GROUP':<{W_NAME}}{nb:>{W_VAL}}{na_:>{W_VAL}}")
    for p in SYMPRECS:
        out(f"    {'symprec ' + _SP[p]:<{W_NAME - 2}}{_sg_text(sa[p]):>{W_VAL}}{_sg_text(sb[p]):>{W_VAL}}")
    out("")

    # ---- nearest neighbours -------------------------------------------------
    na, nbb = _nn_distances(before), _nn_distances(after)
    out(f"  {'NEAREST NEIGHBOUR (A)':<{W_NAME}}{nb:>{W_VAL}}{na_:>{W_VAL}}{'change':>{W_VAL}}")
    for name, x, y in (("shortest", na.min(), nbb.min()),
                       ("mean over sites", na.mean(), nbb.mean())):
        out(f"    {name:<{W_NAME - 2}}{x:>{W_VAL}.4f}{y:>{W_VAL}.4f}{_z(y - x, 4):>+{W_VAL}.4f}")
    out("")

    # ---- displacements ----------------------------------------------------
    # Fractional difference, minimum image, then into Angstrom with the FINAL
    # lattice -- see the module docstring for why not Cartesian directly.
    df = after.frac_coords - before.frac_coords
    df -= np.round(df)
    disp = df @ lb.matrix
    dist = np.linalg.norm(disp, axis=1)

    out(f"  {'ATOMIC DISPLACEMENTS (A)':<{W_NAME}}{'max':>{W_VAL}}{'mean':>{W_VAL}}{'RMS':>{W_VAL}}"
        f"   cell change excluded")

    def _stat_row(label, v):
        v = np.asarray(v)
        out(f"    {label:<{W_NAME - 2}}{v.max():>{W_VAL}.4f}{v.mean():>{W_VAL}.4f}"
            f"{np.sqrt((v ** 2).mean()):>{W_VAL}.4f}")
    _stat_row(f"all  ({len(dist)})", dist)
    per = {}
    for site, d in zip(before, dist):
        per.setdefault(site.specie.symbol, []).append(d)
    for el, v in sorted(per.items()):
        _stat_row(f"{el:<4s} ({len(v)})", v)
    n_moved = int((dist > moved_threshold).sum())
    order = [i for i in np.argsort(-dist)[:top] if dist[i] > moved_threshold]
    largest = ", ".join(f"#{i + 1} {before[i].specie.symbol} {dist[i]:.4f}" for i in order)
    out(f"    moved > {moved_threshold:g} A : {n_moved} of {len(dist)}"
        + (f"      largest: {largest}" if largest else ""))
    drift = disp.mean(axis=0)
    if np.linalg.norm(drift) > 1e-4:
        out(f"    mean shift (all atoms): {np.linalg.norm(drift):.4f} A  "
            f"[{drift[0]:+.4f} {drift[1]:+.4f} {drift[2]:+.4f}]")


def report(before_path, after_path=None, out=print, labels=None):
    """Print the whole report. `after_path` None -> describe one structure.
    `labels` names the two columns; the file names by default."""
    from pymatgen.core import Structure

    before = Structure.from_file(before_path)
    if after_path is None:
        describe(before, f"{before_path}", out=out)
        return
    after = Structure.from_file(after_path)
    import os
    names = tuple(labels) if labels else (os.path.basename(before_path),
                                          os.path.basename(after_path))
    if len(before) != len(after) or \
            [x.specie.symbol for x in before] != [x.specie.symbol for x in after]:
        describe(before, f"{names[0]}", out=out)
        out("")
        describe(after, f"{names[1]}", out=out)
        out("")
        compare(before, after, out=out, names=names)
        return
    out(f"  {_title(before)}")
    out("")
    compare(before, after, out=out, names=names)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    labels = None
    for a in sys.argv[1:]:
        if a.startswith("--labels="):                # --labels=BEFORE,AFTER
            labels = a.split("=", 1)[1].split(",")[:2]
            if len(labels) != 2:
                labels = None
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        report(args[0], args[1] if len(args) > 1 else None, labels=labels)
    except Exception as exc:                      # a report is never worth a crash
        print(f"  structure report unavailable: {type(exc).__name__}: {exc}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
