#!/usr/bin/env python3
"""The literature cases this suite tests against.

Chosen so that every one of them:
  * is a textbook benchmark with published PBE/PAW numbers to check against,
  * converges in seconds to a couple of minutes on 8 cores and 7 GB,
  * exercises a DIFFERENT code path (insulator / metal / magnet / +U / gamma-only).

Structures are built from space group + Wyckoff positions with pymatgen, so the
crystallography is pymatgen's rather than a hand-typed cell that could be subtly
wrong. The reference values below are what the checks compare against.
"""
import json
import sys
from pathlib import Path

from pymatgen.core import Lattice, Structure
from pymatgen.io.vasp import Poscar

# ---------------------------------------------------------------------------
# Reference values. PBE/PAW unless stated. Tolerances are deliberately loose
# enough that a correct-but-differently-converged run passes, and tight enough
# that a WRONG answer (missing spin polarisation, wrong smearing, frozen charge
# density) does not.
# ---------------------------------------------------------------------------
CASES = {
    "Si": dict(
        what="diamond silicon -- the canonical band-structure benchmark",
        why="the VASP wiki's own bandstructure example; insulator, 2 atoms",
        a0_pbe=5.47, a0_exp=5.431,
        gap_pbe=0.6, gap_exp=1.17, gap_tol=0.25,
        magnetic=False, metal=False,
        nelect=8,
    ),
    "Al": dict(
        what="fcc aluminium -- the canonical free-electron metal",
        why="no gap at all; catches a tool that assumes a semiconductor, and "
            "exercises the smearing path (ISMEAR must not be tetrahedron-only)",
        a0_pbe=4.04, a0_exp=4.05,
        gap_pbe=0.0, gap_tol=0.05,
        magnetic=False, metal=True,
        nelect=3,
    ),
    "MgO": dict(
        what="rocksalt MgO -- the canonical wide-gap ionic insulator",
        why="a large gap PBE still underestimates badly; the opposite extreme "
            "from Al in the same 2-atom cell",
        a0_pbe=4.25, a0_exp=4.212,
        gap_pbe=4.5, gap_exp=7.8, gap_tol=0.6,
        magnetic=False, metal=False,
        nelect=8,
    ),
    "Fe": dict(
        what="bcc iron -- the canonical itinerant ferromagnet",
        why="a tool that drops ISPIN or MAGMOM gets 0 instead of 2.2 muB, and "
            "the energy is wrong by ~0.5 eV/atom. One atom, seconds to run",
        a0_pbe=2.83, a0_exp=2.867,
        magmom_pbe=2.2, magmom_tol=0.35,
        magnetic=True, metal=True,
        nelect=8,
    ),
    "NiO": dict(
        what="rocksalt NiO in the AFM-II ordering -- the canonical DFT+U case",
        why="PBE makes it a metal; PBE+U opens a gap. The reference case for "
            "everything this toolkit does with U, magnetism and AFM ordering",
        a0_pbe=4.19, a0_exp=4.17,
        magmom_pbe=1.4, magmom_u=1.7, magmom_tol=0.4,
        gap_u=3.0, gap_exp=4.3, gap_tol=1.2,
        magnetic=True, metal=False, afm=True,
        nelect=26,
    ),
}


def si():
    # Fd-3m (227), 2-atom primitive cell. Experimental lattice constant: the
    # checks that quote a gap quote it AT this geometry, which is how the
    # literature values above were produced.
    return Structure.from_spacegroup(
        "Fd-3m", Lattice.cubic(5.431), ["Si"], [[0.0, 0.0, 0.0]],
    ).get_primitive_structure()


def al():
    return Structure.from_spacegroup(
        "Fm-3m", Lattice.cubic(4.05), ["Al"], [[0.0, 0.0, 0.0]],
    ).get_primitive_structure()


def mgo():
    return Structure.from_spacegroup(
        "Fm-3m", Lattice.cubic(4.212), ["Mg", "O"],
        [[0.0, 0.0, 0.0], [0.5, 0.5, 0.5]],
    ).get_primitive_structure()


def fe():
    return Structure.from_spacegroup(
        "Im-3m", Lattice.cubic(2.867), ["Fe"], [[0.0, 0.0, 0.0]],
    ).get_primitive_structure()


def nio_afm2():
    """NiO in the AFM-II ordering: ferromagnetic (111) sheets, alternating.

    Built as the rhombohedral 4-atom cell that carries the ordering -- the
    smallest cell in which AFM-II exists at all. A 2-atom cell CANNOT hold it,
    which is exactly the trap this case is here to catch.
    """
    # Conventional rocksalt, then the 4-atom cell doubled along [111].
    conv = Structure.from_spacegroup(
        "Fm-3m", Lattice.cubic(4.17), ["Ni", "O"],
        [[0.0, 0.0, 0.0], [0.5, 0.5, 0.5]])
    prim = conv.get_primitive_structure()
    prim.make_supercell([[1, 1, 0], [0, 1, 1], [1, 0, 1]])
    return prim


BUILDERS = {"Si": si, "Al": al, "MgO": mgo, "Fe": fe, "NiO": nio_afm2}


def main(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, build in BUILDERS.items():
        s = build()
        d = out / name
        d.mkdir(exist_ok=True)
        Poscar(s).write_file(str(d / "POSCAR"))
        sg, sgn = s.get_space_group_info(symprec=1e-3)
        meta = dict(CASES[name])
        meta.update(sites=len(s), formula=s.composition.reduced_formula,
                    spacegroup=sg, spacegroup_number=sgn,
                    elements=[el.symbol for el in s.composition.elements])
        manifest[name] = meta
        print(f"{name:5s} {len(s):2d} sites  {s.composition.reduced_formula:6s} "
              f"{sg} ({sgn})   {CASES[name]['what']}")
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
