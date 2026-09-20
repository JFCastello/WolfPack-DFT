#!/usr/bin/env python3
"""
build_supercell.py  (invoked on PATH as: build-supercell)
Build a VASP supercell from a POSCAR.

==================================================================
WHAT THIS SCRIPT DOES
==================================================================
Reads a VASP POSCAR, applies an integer scaling transformation to
the lattice vectors, and writes the resulting supercell to a new
POSCAR. Site properties from the input (selective dynamics flags,
velocities) are preserved on every replicated image. The original
comment line is also kept and annotated with the scaling used.

Spin orderings are a separate job with separate concerns; they
live in build-magnetic-configs.

This script is intended for "plain" supercells, i.e. periodic
replication of an existing structure. It does NOT introduce
vacancies, substitutions, or interstitials — apply those separately,
before or after this step.

==================================================================
SUPERCELL THEORY (short version)
==================================================================
Given primitive lattice vectors (a1, a2, a3), a supercell is
defined by a 3x3 integer matrix M with new lattice vectors

                   A_i = sum_j  M_ij * a_j .

Two equivalent ways to specify M with --scaling:

  • Diagonal scaling (na nb nc):
        M = diag(na, nb, nc)
    Each lattice vector is replicated along itself. This is the
    common case (e.g. 2x2x2 bulk, 3x3x1 slab supercells).

  • Full 3x3 integer matrix (9 numbers, row-major):
        M = [[m11 m12 m13],
             [m21 m22 m23],
             [m31 m32 m33]]
    Useful to change shape, not just size. Examples:
      - primitive FCC -> conventional cubic:
            -1  1  1   1 -1  1   1  1 -1
      - primitive BCC -> conventional cubic:
             0  1  1   1  0  1   1  1  0
      - orthogonal supercell from a hexagonal primitive cell.

The number of primitive cells inside the supercell equals
|det(M)|, and the atom count multiplies by the same factor.

==================================================================
PHYSICAL / PRACTICAL NOTES
==================================================================
1. k-points. Brillouin-zone folding means a supercell N× larger
   in some direction needs roughly N× fewer k-points along that
   direction to keep equivalent BZ sampling. Update KPOINTS
   accordingly; otherwise CPU is wasted.

2. Cost. SCF cost scales ~O(N^3) with electron number; memory
   ~O(N^2). 100–300 atoms is comfortable on small clusters;
   500–1000 becomes expensive. A soft warning is printed above
   500 atoms.

3. POTCAR ordering. VASP reads species in the order they appear
   in POSCAR; the concatenated POTCAR must follow the same order.
   --sort reorders sites by electronegativity, giving a canonical,
   reproducible ordering — convenient if you regenerate POTCARs
   from a script. If your POTCAR is already prepared in a specific
   order, leave --sort off.

4. Coordinate system. Direct (fractional) coordinates are the
   default and preferred for supercells: replicated positions
   stay exact rationals and don't accumulate floating-point drift.
   Use --cartesian only when a downstream tool requires it.

5. Selective dynamics & velocities. If present in the input
   POSCAR, they are copied to every image in the supercell. This
   is correct for plain replication, but each original constraint
   then applies to multiple atoms after replication — review
   before running MD or relaxation.

6. Symmetry is NOT refined. A non-diagonal M can intentionally
   change cell shape (e.g. primitive -> conventional). If you
   want a standardized cell, do that before calling this script
   (e.g. pymatgen's SpacegroupAnalyzer.get_conventional_standard_structure).

7. Integer-only scaling. Non-integer scalings would break lattice
   periodicity and are rejected. Use a finer/coarser primitive
   cell instead if you really need it.


==================================================================
USAGE
==================================================================
  build-supercell POSCAR                           # default 2x2x2
  build-supercell POSCAR -s 3 3 1                  # 3x3x1 slab
  build-supercell POSCAR -s 2 2 2 --sort           # group species
  build-supercell POSCAR -s -1 1 1 1 -1 1 1 1 -1 -o POSCAR_conv
        # primitive FCC -> conventional cubic via full 3x3 matrix
"""

import argparse
import sys
from pathlib import Path

from pymatgen.io.vasp import Poscar


def _raw_title(poscar_path):
    """Line 1 of a POSCAR, exactly as written.

    pymatgen parses POSCARs through clean_lines, which cuts every line at the
    first '#'. VASP does no such thing -- line 1 is free text -- so a title
    carrying a space group or a Materials Project URL loses everything from the
    '#' onwards if taken from Poscar.comment.
    """
    try:
        first = Path(poscar_path).read_text(errors="replace").splitlines()[:1]
    except (OSError, IndexError):
        return ""
    return first[0].strip() if first else ""





def parse_scaling(values):
    """Return a scaling spec from 3 ints (diagonal) or 9 ints (row-major 3x3)."""
    if len(values) == 3:
        return list(values)
    if len(values) == 9:
        return [values[0:3], values[3:6], values[6:9]]
    raise ValueError("--scaling expects 3 ints (na nb nc) or 9 ints (3x3 row-major)")


def main():
    """CLI entry point: build a supercell from a POSCAR and write it out."""
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("poscar", type=Path, nargs="?", default=Path("POSCAR"),
                   help="Input POSCAR file (any VASP 4/5 POSCAR is accepted). "
                        "Defaults to ./POSCAR.")
    p.add_argument("-s", "--scaling", type=int, nargs="+", default=[2, 2, 2],
                   metavar="N",
                   help="Either 3 ints 'na nb nc' for a diagonal scaling, "
                        "or 9 ints for a full row-major 3x3 transformation "
                        "matrix. All entries must be integers. Default: 2 2 2.")
    p.add_argument("-o", "--output", type=Path, default=None,
                   help="Output filename. Default: POSCAR_NaxNbxNc for diagonal "
                        "scaling, POSCAR_supercell for the 3x3-matrix case.")
    p.add_argument("--sort", action="store_true",
                   help="Sort sites by electronegativity. Groups equal species "
                        "together and produces a canonical ordering matching a "
                        "regenerated POTCAR. Leave off if your POTCAR is already "
                        "fixed.")
    p.add_argument("--cartesian", action="store_true",
                   help="Write Cartesian instead of Direct (fractional) "
                        "coordinates. Direct is recommended for supercells.")
    args = p.parse_args()

    if not args.poscar.is_file():
        sys.exit(f"error: '{args.poscar}' not found")

    try:
        scaling = parse_scaling(args.scaling)
    except ValueError as e:
        sys.exit(f"error: {e}")

    # Poscar (not Structure.from_file) preserves selective dynamics, velocities, comment
    poscar_in = Poscar.from_file(str(args.poscar), check_for_potcar=False)
    structure = poscar_in.structure
    n0, v0 = len(structure), structure.volume

    structure.make_supercell(scaling)
    if args.sort:
        structure.sort()

    if args.output is None:
        tag = "x".join(map(str, args.scaling)) if len(args.scaling) == 3 else "supercell"
        args.output = Path(f"POSCAR_{tag}")

    # _raw_title, not poscar_in.comment: pymatgen truncates line 1 at '#'.
    comment = f"{_raw_title(args.poscar) or poscar_in.comment} | supercell {args.scaling}"
    Poscar(structure, comment=comment).write_file(str(args.output), direct=not args.cartesian)

    a, b, c = structure.lattice.abc
    al, be, ga = structure.lattice.angles
    n1, v1 = len(structure), structure.volume
    print(f"In : {args.poscar}  natoms={n0}  V={v0:.3f} Å³")
    print(f"Out: {args.output}  natoms={n1}  V={v1:.3f} Å³  (×{n1 // n0})")
    print(f"Lattice: a={a:.4f}  b={b:.4f}  c={c:.4f} Å | α={al:.2f}° β={be:.2f}° γ={ga:.2f}°")
    print(f"Formula: {structure.composition.formula}")
    if n1 > 500:
        print(f"warning: large cell ({n1} atoms) — SCF cost scales ~O(N^3)", file=sys.stderr)


if __name__ == "__main__":
    main()
