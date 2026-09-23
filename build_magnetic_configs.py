#!/usr/bin/env python3
"""
build_magnetic_configs.py  (invoked on PATH as: build-magnetic-configs)
Enumerate the inequivalent collinear spin orderings of a POSCAR.

==================================================================
WHAT THIS SCRIPT DOES
==================================================================
Reads ./POSCAR, asks pymatgen to enumerate the inequivalent
collinear spin orderings of it, and writes one ready-to-run folder
per ordering, grouped by type:

  magnetic_configs/
    00_NM/config_01/    POSCAR INCAR KPOINTS POTCAR
                        NM_config_01.cif  NM_config_01.vesta
                        SYMMETRY.txt
    01_FM/config_01/
    02_AFM/config_01/ config_02/ ...
    03_FiM/config_01/
    SUMMARY.txt         <- the index

pymatgen does the physics: the enumeration is
MagneticStructureEnumerator, the site matching is StructureMatcher,
the space groups are get_space_group_info, and the .cif is whatever
CifWriter produces. This script is the plumbing around that.

Each folder gets an INCAR derived from ./INCAR with only ISPIN and
MAGMOM changed. Points worth knowing:

* MAGMOM LINES UP WITH THE POSCAR site for site. Both are derived
  from one object in one order, never by re-reading a file: Poscar
  does not carry spin through, so a slip here would give a
  calculation that converges to something else without complaining.
  --sort is refused in this mode for the same reason.

* MAGMOM MAGNITUDES come from your own INCAR's MAGMOM when it has
  one (per element, largest |value|); the SIGNS come from each
  ordering. Without a MAGMOM it falls back to pymatgen's defaults,
  which are high-spin and usually differ from what you would have
  chosen. The output says which was used.

* NUPDOWN IS NOT WRITTEN, and an inherited one is commented out:
  it would force every ordering to the same total moment.

* THE INPUT POSCAR IS USED AS WRITTEN. The enumerator does not
  return the cell it was given -- it can reduce the basis, reorder
  the sites, and return different coordinates -- so each ordering is
  matched back onto the input with StructureMatcher and the folder
  carries the input's own coordinates. If an ordering needs a
  supercell, it is built from the input. Nothing is symmetrised
  unless --symmetrize is given, which is the only path on which
  SpacegroupAnalyzer touches the structure.

* WHEN PYMATGEN RETURNS A SMALLER CELL than the input, or a
  structure StructureMatcher cannot match, that structure is
  written as it comes and the index says so.

* THE POTCAR IS CHECKED, NOT ASSUMED. Enumeration can reorder the
  species blocks; a POTCAR whose order no longer matches is NOT
  copied, and the folder says so.

* KPOINTS is rescaled from the reciprocal lattice vectors when the
  cell differs; an unchanged lattice is left alone.

* SYMMETRY IS REPORTED, NOT USED. SUMMARY.txt carries a space group
  column and each folder a SYMMETRY.txt, both holding exactly what
  get_space_group_info returned for that folder's POSCAR.

* .cif AND .vesta ARE FOR LOOKING AT. The .cif carrying the moments
  comes out in P 1 because pymatgen disables symmetry detection
  when asked for magmoms; a second, symmetrised .cif without
  moments is written when pymatgen finds a space group.

Needs the enumlib binaries (enum.x, makestr.x), which install.sh
pulls into the conda environment. Without them pymatgen can only
build the ferromagnetic ordering.

==================================================================
USAGE
==================================================================
  build-magnetic-configs --dry-run          # look before writing
  build-magnetic-configs                    # write the folders
  build-magnetic-configs --magnetic-species V
        # treat only V as magnetic, ignoring Cu
  build-magnetic-configs --symmetrize --symprec 0.1
        # enumerate from pymatgen's symmetrised structure instead
  build-magnetic-configs POSCAR_relaxed     # start from another file
"""

import argparse
import math
import os
import sys
import re
import shutil
from pathlib import Path

# Make the sibling wolfpack_incar module importable regardless of how this file
# is reached -- in particular through a symlink in ~/.local/bin, whose directory
# does not contain it. realpath follows the symlink back to the toolkit.
_PKG_DIR = os.path.dirname(os.path.realpath(__file__))
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

from pymatgen.io.vasp import Poscar            # noqa: E402
from wolfpack_incar import set_tag, comment_tag, get_tag  # noqa: E402


# =============================================================================
# MAGNETIC CONFIGURATION ENUMERATION
# =============================================================================
# Finding a system's magnetic ground state means computing several spin
# orderings and comparing their energies. Setting those up by hand is tedious
# and easy to get wrong: MAGMOM has to line up site-for-site with the POSCAR,
# and a slip produces a calculation that converges to something else without
# ever complaining.
#
# The enumeration itself is pymatgen's. It needs the external enumlib binaries
# (enum.x, makestr.x); without them EVERY antiferromagnetic and ferrimagnetic
# strategy raises RuntimeError at construction, and only the ferromagnetic case
# -- which pymatgen special-cases in Python -- survives. install.sh pulls
# enumlib in with the rest of the conda environment.

MAG_DIR = "magnetic_configs"


def _magnetic_elements(structure):
    """Elements in `structure` that pymatgen treats as magnetic.

    Uses pymatgen's own DEFAULT_MAGMOMS table rather than a list of our own, so
    detection agrees with what the enumerator will actually do: anything absent
    from that table is treated as non-magnetic (moment 0) downstream.
    """
    from pymatgen.analysis.magnetism.analyzer import DEFAULT_MAGMOMS
    known = {k.rstrip("+-0123456789") for k in DEFAULT_MAGMOMS}
    return [el.symbol for el in structure.composition.elements if el.symbol in known]


def _magmom_magnitudes_from_incar(incar, structure):
    """Per-ELEMENT moment magnitudes taken from the root INCAR's MAGMOM.

    Per element, not per site, deliberately: under supercell expansion a site
    index means nothing, while the element still does. The magnitude kept for an
    element is the largest |value| it carries, and the SIGNS come from each
    enumerated ordering, never from here.

    Returns None when the INCAR has no usable MAGMOM, so the caller can fall
    back to pymatgen's defaults and say which it used.
    """
    mm = incar.get("MAGMOM")
    if not mm or len(mm) != len(structure):
        return None
    out = {}
    for site, m in zip(structure, mm):
        sym = site.specie.symbol
        out[sym] = max(out.get(sym, 0.0), abs(float(m)))
    return {k: v for k, v in out.items() if v > 0} or None


def parse_magmom_flag(spec, structure):
    """Per-ELEMENT moment magnitudes from --magmom, in either notation.

    Two forms, because both are things people already have in front of them:

      "Ti:1.0,V:2.5"     per species, which is what pymatgen takes
      "4*1.0 12*0.0"     the INCAR's own MAGMOM shorthand, pasted straight out
                         of a file. The POSCAR's site order says which element
                         each entry belongs to, exactly as VASP reads it.

    Magnitudes only. The SIGNS are not read from here and could not be: the
    whole point of enumerating orderings is that pymatgen decides which sites
    are up and which are down, and a sign given here would be overwritten by
    every ordering it generates. |value| is taken, and the largest one wins per
    element.

    Raises ValueError with a message that names the problem.
    """
    spec = (spec or "").strip()
    if not spec:
        raise ValueError("--magmom was given an empty value.")

    symbols = [site.specie.symbol for site in structure]
    known = set(symbols)

    # --- form 1: EL:value ---------------------------------------------------
    if ":" in spec:
        out = {}
        for chunk in spec.replace(",", " ").split():
            if ":" not in chunk:
                raise ValueError(
                    f"--magmom: '{chunk}' is not EL:value. Mixing the two "
                    "notations in one value is not supported -- use either "
                    "\"Ti:1.0,V:2.5\" or the INCAR form \"4*1.0 12*0.0\".")
            el, _, val = chunk.partition(":")
            el = el.strip()
            try:
                m = abs(float(val))
            except ValueError:
                raise ValueError(f"--magmom: '{val}' after '{el}:' is not a number.")
            if el not in known:
                raise ValueError(
                    f"--magmom: this cell has no {el}. It contains: "
                    f"{', '.join(sorted(known))}.")
            if m > 0:
                out[el] = max(out.get(el, 0.0), m)
        if not out:
            raise ValueError(
                "--magmom: every magnitude given is zero, so nothing is "
                "magnetic and there are no orderings to enumerate.")
        return out

    # --- form 2: the INCAR MAGMOM shorthand ---------------------------------
    values = []
    for tok in spec.replace(",", " ").split():
        if "*" in tok:
            n_s, _, v_s = tok.partition("*")
            try:
                n, v = int(n_s), float(v_s)
            except ValueError:
                raise ValueError(
                    f"--magmom: '{tok}' is not N*value (as in 4*1.0), and has "
                    "no ':' so it is not EL:value either.")
            if n < 0:
                raise ValueError(f"--magmom: '{tok}' repeats a value {n} times.")
            values.extend([v] * n)
        else:
            try:
                values.append(float(tok))
            except ValueError:
                raise ValueError(
                    f"--magmom: '{tok}' is neither a number, N*number, nor "
                    "EL:number.")
    if len(values) != len(symbols):
        raise ValueError(
            f"--magmom: {len(values)} value(s) for {len(symbols)} site(s).\n"
            "       In the INCAR notation there is one entry per ION, in POSCAR\n"
            f"       order ({' '.join(sorted(known))}). Expand N*value if you are\n"
            "       counting by hand, or use the EL:value form instead.")
    out = {}
    for sym, v in zip(symbols, values):
        if abs(v) > 0:
            out[sym] = max(out.get(sym, 0.0), abs(v))
    if not out:
        raise ValueError(
            "--magmom: every value is zero, so nothing is magnetic and there "
            "are no orderings to enumerate.")
    return out


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


def _potcar_species(potcar_path):
    """Element symbols in POTCAR order, from the TITEL lines.

    A TITEL reads "PAW_PBE Cu_sv_GW 10Dec2015"; the element is the second field
    with any suffix (_sv, _pv, _GW, _3) stripped.
    """
    syms = []
    try:
        for ln in Path(potcar_path).read_text(errors="replace").splitlines():
            if "TITEL" in ln:
                parts = ln.split("=", 1)[-1].split()
                if len(parts) >= 2:
                    syms.append(parts[1].split("_")[0])
    except OSError:
        return []
    return syms


def _rescale_kpoints(kpts, ref_lattice, new_lattice):
    """Scale an automatic mesh so the k-point RESOLUTION stays what it was.

    A supercell samples reciprocal space more finely for the same mesh, so
    reusing the root KPOINTS would oversample it -- wasted time, and energies
    not comparable at equal cost.

    The mesh subdivides the RECIPROCAL lattice vectors, so it has to be scaled
    by those, never by |a|, |b|, |c|. The two agree only for an orthogonal cell,
    and they part company exactly where it matters: the enumerator often returns
    the SAME lattice in a reduced basis. LaMnO3's c -> c + a leaves |a| and |b|
    untouched while shortening |c| from 9.57 to 7.78 A, so the real-space ratio
    demanded MORE k-points along c in a cell of identical volume. In the
    reciprocal basis that ratio is 1 and the mesh is correctly left alone.

    ceil, not round: this is VASP's own KSPACING rule. It makes an unchanged
    lattice reproduce the user's mesh exactly -- including an anisotropic one,
    where a shared-spacing formula would quietly coarsen the dense axes -- and
    never samples any axis more coarsely than the ratio asks.

    Only a Gamma/Monkhorst mesh is touched; a line-mode or explicit list is
    returned unchanged, because rescaling that automatically would be guessing.

    Returns the KPOINTS text (not a Kpoints object) so the user's own header
    line and explicit shift survive: Kpoints.gamma_automatic replaces the
    comment with "Automatic kpoint scheme" and drops a zero shift line.
    """
    style = str(kpts.style).lower()
    if "gamma" not in style and "monkhorst" not in style:
        return None
    mesh = list(kpts.kpts[0])
    if len(mesh) != 3:
        return None
    ref_b = ref_lattice.reciprocal_lattice.abc
    new_b = new_lattice.reciprocal_lattice.abc
    new = [max(1, math.ceil(m * n / r - 1e-9))
           for m, r, n in zip(mesh, ref_b, new_b)]
    if new == mesh:
        return None
    shift = tuple(kpts.kpts_shift or (0, 0, 0))
    text = (f"{kpts.comment}\n0\n{'Gamma' if 'gamma' in style else 'Monkhorst'}\n"
            f"{' '.join(map(str, new))}\n{' '.join(map(str, shift))}\n")
    return text, mesh, new


def _ordering_of(structure):
    """Classify a spin-bearing structure as FM / AFM / FiM / NM."""
    from pymatgen.analysis.magnetism.analyzer import CollinearMagneticStructureAnalyzer
    a = CollinearMagneticStructureAnalyzer(
        structure, overwrite_magmom_mode="none", make_primitive=False)
    return a.ordering.name


def _spins(structure):
    """Moments in SITE ORDER, from the same object the POSCAR is written from.

    Poscar does not carry spin through: the species-count header of a
    Species(spin=...) structure comes out with bare symbols ("La Mn O / 4 4 12"),
    while the per-site label column leaks pymatgen's internal string
    ("Mn,spin=np.int64(5)"). Neither is a moment VASP will read. So MAGMOM and
    the POSCAR can only be kept consistent by deriving both from one object in
    one order -- never by re-reading the file, and never after a sort().
    """
    out = []
    for site in structure:
        s = getattr(site.specie, "spin", None)
        if s is None:
            s = site.properties.get("magmom", 0.0)
        out.append(float(s or 0.0))
    return out


def _demagnetised(struct):
    """Same structure with bare elements and the moment moved to a site property.

    Both CifWriter and Poscar accept a Species(spin=...) structure, and both
    then write pymatgen's internal string where an element symbol belongs --
    "Ni0+,spin=4.0" in _atom_site_type_symbol, "Mn,spin=np.int64(5)" in the
    POSCAR's label column. No viewer should be asked to parse that. Moving the
    moment to site_properties keeps the symbols clean and changes nothing else.

    Other site properties are carried across: selective dynamics rides in one,
    and dropping it would silently free atoms the user had frozen.
    """
    from pymatgen.core import Structure
    props = dict(struct.site_properties)
    props["magmom"] = _spins(struct)
    return Structure(
        struct.lattice,
        [getattr(s.specie, "element", s.specie) for s in struct],
        [s.frac_coords for s in struct],
        site_properties=props,
    )


# --- putting the ordering back on the user's own atoms -----------------------
# The enumerator is asked ONE question -- which magnetic site points up and
# which points down -- and that is the only thing taken from its answer. Every
# coordinate comes from the POSCAR that was handed in.
#
# The matching is StructureMatcher's, with StructureMatcher's tolerances. There
# is deliberately none of our own: the enumerator can return the same structure
# in a different basis, in a different site order, and (through enumlib) with
# the positions idealised, and pymatgen is the thing that knows how much of that
# still counts as the same crystal.


def _on_user_positions(ref, struct, matcher):
    """`struct`'s spins on `ref`'s atomic positions, or None if they do not fit.

    Three cases, and only the first two can keep the user's coordinates:

      same size   -> map straight onto `ref`
      bigger      -> ask for the supercell matrix and build it FROM `ref`, so
                     even an expanded cell is made of the user's own atoms
      smaller     -> None. pymatgen found a cell with fewer atoms than the
                     input; that cell is cheaper to run and is kept as it comes.
    """
    import numpy as np

    dem = _demagnetised(struct)
    base = None
    if len(struct) == len(ref):
        base = ref
    elif len(struct) > len(ref):
        trans = matcher.get_transformation(dem, ref)
        if trans is None:
            return None
        base = ref.copy()
        base.make_supercell(np.round(trans[0]).astype(int))
        if len(base) != len(struct):
            return None
    else:
        return None

    like = matcher.get_s2_like_s1(base, dem)
    if like is None or len(like) != len(base):
        return None
    if [s.specie.symbol for s in like] != [s.specie.symbol for s in base]:
        return None
    out = base.copy()
    out.add_site_property("magmom", list(like.site_properties["magmom"]))
    return out


def _space_group(struct, symprec=None):
    """What pymatgen says the space group is: (symbol, number), or None.

    Reported, never acted on. The default symprec is pymatgen's own.
    """
    try:
        if symprec is None:
            return struct.get_space_group_info()
        return struct.get_space_group_info(symprec=symprec)
    except Exception:
        return None



# --- visualisation: .cif and .vesta per configuration ------------------------
# Both files are for LOOKING at. VASP never reads either one.

VESTA_ARROW_A = 1.5     # longest arrow, in Angstrom: visible without reaching
                        # into the neighbouring atoms
VESTA_UP = "255 0 0"    # red
VESTA_DOWN = "0 0 255"  # blue


def _write_cifs(struct, folder, stem, sg, symprec=None):
    """Whatever CifWriter can produce, written verbatim. Up to two files.

    `<stem>.cif` carries the moments. It comes out in P 1 because pymatgen
    disables symmetry detection when asked for magmoms -- CifWriter says so
    itself: "Magnetic symmetry cannot currently be detected by pymatgen". That
    is pymatgen's limit, and it is left alone rather than worked around.

    `<stem>_symmetrized.cif` is written only when pymatgen finds a space group,
    and carries no moments. refine_struct=False is the one non-default argument:
    the default would hand back get_refined_structure, whose cell need not be the
    one in this folder's POSCAR.
    """
    from pymatgen.core import Structure
    from pymatgen.io.cif import CifWriter

    spins = _spins(struct)
    has_moment = any(abs(m) > 1e-6 for m in spins)
    Path(folder / f"{stem}.cif").write_text(
        str(CifWriter(_demagnetised(struct), write_magmoms=has_moment)))

    if sg is None or sg[1] <= 1:
        return
    plain = Structure(struct.lattice,
                      [getattr(s.specie, "element", s.specie) for s in struct],
                      [s.frac_coords for s in struct])
    try:
        text = str(CifWriter(plain, symprec=symprec or 0.01, refine_struct=False))
    except Exception:
        return
    Path(folder / f"{stem}_symmetrized.cif").write_text(text)


def _write_symmetry_txt(path, sg, symprec):
    """What pymatgen returned for this folder's POSCAR. Nothing else."""
    call = f"get_space_group_info(symprec={symprec})" if symprec is not None \
        else "get_space_group_info()"
    found = f"{sg[0]} ({sg[1]})" if sg else "nothing returned"
    Path(path).write_text(
        "POSCAR in this folder\n"
        f"  pymatgen {call}: {found}\n")


def _write_vesta(struct, path, title):
    """Write VESTA's own format with one arrow per magnetic atom.

    The magCIF above should be enough on its own, but whether a given VESTA
    build renders those moments is not something this script can verify. This
    format states the vectors outright, so the arrows do not depend on it.

    Vector components are CARTESIAN, in Angstrom, matching the precedent in
    pymatgen's own VESTA writer (phonon/thermal_displacements.py).

    A collinear moment points along CARTESIAN z, not along the cell's c axis:
    pymatgen's Magmom(4.0) is the vector [0, 0, 4] in Cartesian space, and VASP
    means the same thing. The CIF stores those components projected onto the
    crystal axes, which is why a moment can appear there as (-4, 0, 0) -- same
    physical vector, different basis. Projecting onto c here instead would point
    every arrow the wrong way in any cell whose c is not along z, which is most
    of the cells the enumerator produces.
    """
    spins = _spins(struct)
    mags = [(i, m) for i, m in enumerate(spins) if abs(m) > 1e-6]
    peak = max((abs(m) for _, m in mags), default=0.0)
    scale = (VESTA_ARROW_A / peak) if peak > 0 else 0.0

    lat = struct.lattice
    out = ["#VESTA_FORMAT_VERSION 3.5.4", "", "", "CRYSTAL", "",
           "TITLE", title, "", "GROUP", "1 1 P 1", "", "CELLP",
           f"{lat.a:.6f} {lat.b:.6f} {lat.c:.6f} "
           f"{lat.alpha:.6f} {lat.beta:.6f} {lat.gamma:.6f}",
           "  0.000000   0.000000   0.000000   0.000000   0.000000   0.000000",
           "STRUC"]
    for i, site in enumerate(struct, start=1):
        el = getattr(site.specie, "element", site.specie)
        f = site.frac_coords
        out.append(f"{i} {el} {el}{i} 1.0000 {f[0]:.6f} {f[1]:.6f} {f[2]:.6f} 1a 1")
        out.append(" 0.000000 0.000000 0.000000 0.00")
    out.append("  0 0 0 0 0 0 0")

    # Only magnetic atoms get a vector; zero-length arrows on every other site
    # would be noise VESTA still has to draw.
    out.append("VECTR")
    for n_vec, (idx, m) in enumerate(mags, start=1):
        out.append(f"   {n_vec} 0.000000 0.000000 {m * scale:.6f} 0")
        out.append(f"   {idx + 1} 0 0 0 0")
        out.append(" 0 0 0 0 0")
    out.append(" 0 0 0 0 0")

    out.append("VECTT")
    for n_vec, (_, m) in enumerate(mags, start=1):
        out.append(f"{n_vec} 0.5 {VESTA_UP if m > 0 else VESTA_DOWN} 1")
    out.append(" 0 0 0 0 0")
    Path(path).write_text("\n".join(out) + "\n")


def enumerate_magnetic(args):
    """Write one folder per inequivalent spin ordering, grouped by type."""
    from pymatgen.io.vasp import Incar, Poscar
    from pymatgen.io.vasp.inputs import Kpoints

    root = Path(".")
    if not args.poscar.is_file():
        sys.exit(f"error: '{args.poscar}' not found (run this in the calculation folder)")

    poscar_in = Poscar.from_file(str(args.poscar), check_for_potcar=False)
    ref = poscar_in.structure
    # poscar_in.comment is NOT the user's title: pymatgen reads the POSCAR
    # through clean_lines, which truncates every line at '#'. A title like
    # "LaMnO3 - #62 (Pnma) - https://..." arrives as "LaMnO3 -". VASP treats
    # line 1 as free text, so take it raw.
    ref_title = _raw_title(args.poscar) or poscar_in.comment

    if args.symmetrize:
        # The only path on which SpacegroupAnalyzer touches the structure that
        # ends up in the folders. Off by default, because the POSCAR the user
        # wrote is the one they meant.
        from pymatgen.symmetry.analyzer import SpacegroupAnalyzer
        sga = (SpacegroupAnalyzer(ref, symprec=args.symprec) if args.symprec
               else SpacegroupAnalyzer(ref))
        ref = sga.get_refined_structure()
        print(f"--symmetrize: input replaced by get_refined_structure() "
              f"-> {len(ref)} sites, {_space_group(ref, args.symprec)}")

    # ---- which atoms carry a moment -------------------------------------
    # --magmom is read FIRST, because naming an element there is a statement
    # that it is magnetic. Read later, a cell whose elements are all
    # non-magnetic in pymatgen's default table would be refused below before
    # the flag was ever looked at -- and that cell is precisely the one someone
    # reaches for this flag to describe.
    flag_magnitudes = None
    if args.magmom is not None:
        try:
            flag_magnitudes = parse_magmom_flag(args.magmom, ref)
        except ValueError as exc:
            sys.exit(f"error: {exc}")

    if args.magnetic_species:
        mag_els = [s.strip() for s in args.magnetic_species.split(",") if s.strip()]
        present = {el.symbol for el in ref.composition.elements}
        unknown = [e for e in mag_els if e not in present]
        if unknown:
            sys.exit(f"error: {', '.join(unknown)} not in this structure "
                     f"(it has {', '.join(sorted(present))})")
    elif flag_magnitudes:
        # The flag says which, and that is the whole answer.
        mag_els = sorted(flag_magnitudes)
    else:
        mag_els = _magnetic_elements(ref)
        if not mag_els:
            sys.exit("error: no magnetic elements detected in "
                     f"{ref.composition.reduced_formula}.\n"
                     "       Detection uses pymatgen's default-moment table; if an element\n"
                     "       here should be magnetic, name it: --magnetic-species Fe,Ni\n"
                     "       or give it a moment directly: --magmom Fe:4.0")

    # ---- moment magnitudes ----------------------------------------------
    incar_path = root / "INCAR"
    # NO INCAR IS A HARD ERROR, not a default.
    #
    # Every configuration folder gets a copy of this file, so without it each
    # one carries a two-line INCAR -- ISPIN and MAGMOM and nothing else. That
    # is not a reduced calculation, it is a DIFFERENT one: no ENCUT, no
    # functional, no convergence criteria, no ionic block. A METAGGA=R2SCAN
    # relaxation silently becomes a default-cutoff PBE static run, and the only
    # sign is that the folders look complete.
    #
    # It has already happened once, to an INCAR misnamed `INACAR`. A typo in a
    # filename should not cost a week of compute, so say so here rather than
    # let the folders carry the omission.
    if not incar_path.is_file() and not args.no_incar:
        _near = sorted(x.name for x in root.iterdir()
                       if x.is_file() and x.name.upper().replace("A", "") == "INCR")
        sys.exit("error: no INCAR in this directory.\n"
                 "       Every configuration folder is built from it -- without one they\n"
                 "       would carry only ISPIN and MAGMOM, and run a calculation you did\n"
                 "       not ask for (no ENCUT, no functional, no ionic block).\n"
                 + (f"\n       Did you mean: {', '.join(_near)} ?\n" if _near else "")
                 + "\n       Put your INCAR here, or pass --no-incar to accept a minimal one.")
    incar_text = incar_path.read_text() if incar_path.is_file() else ""
    if not incar_text:
        print("note: no INCAR -- every folder will carry only ISPIN and MAGMOM "
              "(--no-incar was given).", file=sys.stderr)
    magnitudes, mag_src = None, "pymatgen defaults (high-spin)"
    if incar_text:
        try:
            magnitudes = _magmom_magnitudes_from_incar(Incar.from_file(str(incar_path)), ref)
        except Exception:
            magnitudes = None
        if magnitudes:
            mag_src = "MAGMOM in ./INCAR"
    # --magmom OVERRIDES both. It is the explicit statement of which species
    # you believe carry a moment and how large, and an explicit statement beats
    # a file that happens to be in the directory and a table of defaults.
    #
    # This is the only thing it does. It becomes default_magmoms, which is what
    # pymatgen's MagneticStructureEnumerator takes; the enumeration -- which
    # orderings exist, which are symmetry-equivalent, which survive -- is
    # entirely pymatgen's, and nothing here touches it.
    if flag_magnitudes:
        magnitudes = flag_magnitudes
        mag_src = "--magmom"
        # An element named in --magmom is an element the user says is magnetic,
        # whatever the default table thinks. Saying "Ti:1.0" and being told Ti
        # is not magnetic would be the tool overruling the person.
        for _el in magnitudes:
            if _el not in mag_els:
                mag_els.append(_el)
    default_magmoms = {e: magnitudes[e] for e in mag_els if magnitudes and e in magnitudes} or None

    print(f"Structure : {ref.composition.reduced_formula}  ({len(ref)} sites)")
    print(f"Magnetic  : {', '.join(mag_els)}")
    print(f"Magnitudes: {mag_src}"
          + (f"  -> {default_magmoms}" if default_magmoms else ""))

    # ---- enumerate --------------------------------------------------------
    # enumlib's adaptor emits UserWarnings about dummy species and missing
    # Wyckoff properties on every single structure it builds. They are internal
    # bookkeeping, not something the user can act on, and they bury the report.
    import warnings
    from pymatgen.analysis.magnetism.analyzer import MagneticStructureEnumerator
    strategies = (tuple(s.strip() for s in args.strategies.split(",") if s.strip())
                  if args.strategies else ("ferromagnetic", "antiferromagnetic"))
    # enumlib writes its scratch files into the CURRENT directory and does not
    # clean up after itself, so a run left readcheck_enum.out and friends sitting
    # next to the user's POSCAR. Note what is there before, remove what appeared.
    # Only files enumlib is known to write are considered, and only if they were
    # not already present -- so a file of the user's with a colliding name
    # survives.
    _enum_debris = ("readcheck_enum.out", "struct_enum.out", "struct_enum.in",
                    "symops_enum_parent_lattice.out", "debug_site_restrictions.out",
                    "VERSION.enum", "enum.out", "fort.11")
    _before = {n for n in _enum_debris if Path(n).exists()}
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            enum = MagneticStructureEnumerator(
                ref, default_magmoms=default_magmoms, strategies=strategies,
                automatic=not args.strategies, max_orderings=args.max_orderings)
    except RuntimeError as e:
        if "enumlib" in str(e).lower() or "Enumlib" in str(e):
            sys.exit("error: the magnetic enumeration needs the enumlib binaries "
                     "(enum.x, makestr.x),\n"
                     "       which are not on PATH. Without them pymatgen can only build the\n"
                     "       ferromagnetic ordering -- every AFM and ferrimagnetic strategy\n"
                     "       fails.\n\n"
                     "       Install into the toolkit environment:\n"
                     "           conda install -c conda-forge enumlib\n")
        raise
    except ValueError as e:
        if "Too many magnetic sites" in str(e):
            sys.exit("error: too many symmetrically distinct magnetic sites for pymatgen's\n"
                     "       enumerator, which refuses above 8.\n"
                     "       Narrow the problem with --magnetic-species, or start from a\n"
                     "       smaller primitive cell.\n")
        raise
    finally:
        for _n in _enum_debris:
            if _n not in _before:
                try:
                    Path(_n).unlink()
                except OSError:
                    pass

    # ---- collect, with the non-magnetic reference first --------------------
    entries = []
    nm = ref.copy()
    nm.add_site_property("magmom", [0.0] * len(nm))
    entries.append(("NM", nm, "reference, ISPIN=2 with zero moments", True))
    from pymatgen.analysis.structure_matcher import StructureMatcher, ElementComparator
    matcher = StructureMatcher(primitive_cell=False, attempt_supercell=True,
                               comparator=ElementComparator())
    for struct, origin in zip(enum.ordered_structures, enum.ordered_structure_origins):
        # Only the SPINS are taken from the enumerator; the coordinates come
        # from the POSCAR that was handed in, whenever pymatgen can match them.
        mapped = _on_user_positions(ref, struct, matcher)
        struct = mapped if mapped is not None else struct
        entries.append((_ordering_of(struct), struct, origin, mapped is not None))

    order = {"NM": 0, "FM": 1, "AFM": 2, "FiM": 3}
    # Sorted by TYPE, then by strategy, then by the moments themselves. Sorting
    # on type alone is stable, so folder numbering inherited the enumerator's
    # order -- which is not reproducible: two runs on the same POSCAR returned
    # the by_motif_2a and by_motif_2d orderings the other way round, silently
    # swapping what config_04 and config_05 mean. That matters because the whole
    # point is comparing energies folder by folder, quite possibly across runs
    # made days apart. Tying the order to the CONTENT makes a folder number mean
    # the same ordering every time.
    entries.sort(key=lambda e: (order.get(e[0], 9), e[2], tuple(_spins(e[1]))))

    # ---- POTCAR validity ---------------------------------------------------
    pot_path = root / "POTCAR"
    pot_syms = _potcar_species(pot_path) if pot_path.is_file() else []

    kpt_path = root / "KPOINTS"
    kpts_in = None
    if kpt_path.is_file():
        try:
            kpts_in = Kpoints.from_file(str(kpt_path))
        except Exception:
            kpts_in = None

    out_root = root / MAG_DIR
    if args.dry_run:
        print(f"\n[dry run] would write {len(entries)} configuration(s) under {MAG_DIR}/\n")
    elif out_root.exists():
        sys.exit(f"error: {MAG_DIR}/ already exists -- move or remove it first")

    summary, counts, made = [], {}, 0
    for kind, struct, origin, on_ref in entries:
        counts[kind] = counts.get(kind, 0) + 1
        folder = out_root / f"{order.get(kind, 9):02d}_{kind}" / f"config_{counts[kind]:02d}"
        spins = _spins(struct)
        net = sum(spins)
        if len(struct) > len(ref):
            cellnote = f"supercell x{len(struct) / len(ref):g}"
        elif len(struct) < len(ref):
            cellnote = f"{len(struct)} sites"
        else:
            cellnote = ""
        if not on_ref:
            cellnote = ((cellnote + "; ") if cellnote else "") + "structure from pymatgen"
        expanded = len(struct) != len(ref)
        note = ""
        sg = _space_group(struct, args.symprec)
        sgtxt = f"{sg[0]} ({sg[1]})" if sg else "none"

        # POSCAR and MAGMOM come from ONE object in ONE order; never re-read.
        # De-spun, because Poscar leaks "Mn,spin=np.int64(5)" into the label
        # column of a Species(spin=...) structure.
        out_struct = _demagnetised(struct)
        if not on_ref and "selective_dynamics" in out_struct.site_properties:
            # Only the user's own cell keeps them. Elsewhere the atoms have no
            # one-to-one counterpart, and a wrong constraint is far worse than
            # none: it relaxes a structure nobody asked for and says nothing.
            # (When pymatgen rebuilt the cell it also used to hand each site the
            # properties of its whole symmetry orbit, so on conventional NiO one
            # frozen O and one part-frozen Ni came back as four of each.)
            out_struct.remove_site_property("selective_dynamics")
            note = "selective dynamics DROPPED (different cell, no site correspondence)"

        if not args.dry_run:
            folder.mkdir(parents=True, exist_ok=True)
            Poscar(out_struct, comment=f"{ref_title} | {kind} ({origin})"
                   ).write_file(str(folder / "POSCAR"))

            txt = incar_text
            # A note only when the value actually changes. ISPIN was very often
            # already 2, and overwriting the user's own trailing comment with
            # ours would be exactly the gratuitous churn this library exists to
            # avoid -- set_tag keeps their comment when no note is given.
            txt = set_tag(txt, "ISPIN", "2",
                          "" if (get_tag(txt, "ISPIN") or "").strip() == "2"
                          else "spin-polarised")
            txt = set_tag(txt, "MAGMOM",
                                  Incar({"MAGMOM": spins}).get_str().split("=", 1)[1].strip(),
                                  f"{kind} ordering ({origin})")
            if re.search(r"^[ \t]*NUPDOWN[ \t]*=", txt, re.IGNORECASE | re.MULTILINE):
                # An inherited NUPDOWN would force every ordering to the same
                # total moment -- the opposite of what is being compared.
                txt = comment_tag(txt, "NUPDOWN",
                                          "removed: it would force all orderings to one moment")
            (folder / "INCAR").write_text(txt)

            if kpts_in is not None:
                res = _rescale_kpoints(kpts_in, ref.lattice, struct.lattice)
                if res is None:
                    shutil.copy2(kpt_path, folder / "KPOINTS")
                else:
                    text, oldm, newm = res
                    (folder / "KPOINTS").write_text(text)
                    note = (note + "; " if note else "") + \
                        f"KPOINTS {'x'.join(map(str, oldm))} -> {'x'.join(map(str, newm))}"

            # Visualisation only -- VASP reads neither. Named after the
            # configuration so several open at once stay distinguishable in
            # VESTA's tabs instead of all reading "structure".
            stem = f"{kind}_config_{counts[kind]:02d}"
            _write_cifs(struct, folder, stem, sg, args.symprec)
            _write_symmetry_txt(folder / "SYMMETRY.txt", sg, args.symprec)
            _write_vesta(struct, folder / f"{stem}.vesta", stem)

            if pot_syms:
                # Ask the POSCAR that was actually written, not the Structure.
                # With spin-bearing species, Ni(spin=+4) and Ni(spin=-4) are two
                # DIFFERENT species to pymatgen, so structure.symbol_set reports
                # ('Ni','Ni','O') -- which never matches a POTCAR and would
                # refuse to copy a perfectly good one. site_symbols is the
                # species-block order VASP will actually read.
                want = Poscar(out_struct).site_symbols
                if pot_syms == want:
                    shutil.copy2(pot_path, folder / "POTCAR")
                else:
                    note = (note + "; " if note else "") + \
                        f"POTCAR NOT copied (needs {'+'.join(want)}, " \
                        f"root has {'+'.join(pot_syms)})"
            made += 1

        summary.append((str(folder.relative_to(root)), kind, origin, len(struct),
                        net, expanded, sgtxt, "; ".join(x for x in (cellnote, note) if x)))

    # ---- report ------------------------------------------------------------
    hdr = (f"{'folder':<38} {'type':<4} {'origin':<12} {'sites':>5} {'net':>6} "
           f"{'space group':<14} notes")
    lines = [hdr, "-" * len(hdr)]
    for f, k, o, n, net, exp, sg, note in summary:
        lines.append(f"{f:<38} {k:<4} {o:<12} {n:>5} {net:>+6.1f} {sg:<14} {note}")
    body = "\n".join(lines)
    print("\n" + body)

    if not args.dry_run:
        sp = args.symprec if args.symprec is not None else "pymatgen default"
        (out_root / "SUMMARY.txt").write_text(
            f"Magnetic configurations from {args.poscar}\n"
            f"Magnetic elements : {', '.join(mag_els)}\n"
            f"Moment magnitudes : {mag_src}\n"
            f"Space group from  : pymatgen get_space_group_info, symprec {sp}\n"
            + (f"Input structure   : replaced by SpacegroupAnalyzer"
               f".get_refined_structure(symprec={args.symprec})\n"
               if args.symmetrize else "")
            + f"\n{body}\n\n"
            "Each folder holds POSCAR, INCAR, KPOINTS, POTCAR, a .cif and a .vesta for\n"
            "viewing, and SYMMETRY.txt. VASP reads none of the last three.\n\n"
            "Cells of different size are not comparable directly -- compare energy per atom.\n"
            "NUPDOWN is not written.\n")
        print(f"\nWrote {made} configuration(s) under {MAG_DIR}/   (index: {MAG_DIR}/SUMMARY.txt)")
        if any(s[5] for s in summary):
            print("note: some cells were expanded -- compare energies PER ATOM, not per cell.",
                  file=sys.stderr)


def main():
    """CLI entry point: enumerate spin orderings into ready-to-run folders."""
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("poscar", type=Path, nargs="?", default=Path("POSCAR"),
                   help="Structure to enumerate orderings of. Defaults to "
                        "./POSCAR.")
    p.add_argument("--magmom", metavar="SPEC", default=None,
                   help="initial moment MAGNITUDES, in either notation: "
                        "\"Ti:1.0,V:2.5\" per species, or the INCAR's own "
                        "\"4*1.0 12*0.0\" with one entry per ion in POSCAR "
                        "order. Overrides the root INCAR's MAGMOM and "
                        "pymatgen's defaults. Signs are NOT read from here -- "
                        "which sites are up and which are down is what the "
                        "enumeration decides.")
    p.add_argument("--magnetic-species", metavar="EL,EL",
                   help="Treat exactly these elements as magnetic, e.g. 'V,Fe'. "
                        "Default: every element pymatgen has a default moment "
                        "for.")
    p.add_argument("--no-incar", action="store_true",
                   help="Proceed without an INCAR. Each folder then gets a "
                        "minimal one -- ISPIN and MAGMOM only -- which is a "
                        "DIFFERENT calculation from anything you have set up. "
                        "Only useful if you intend to write the INCARs yourself.")
    p.add_argument("--max-orderings", type=int, default=64, metavar="N",
                   help="Cap on how many orderings to enumerate. Default: 64 "
                        "(pymatgen's own).")
    p.add_argument("--strategies", metavar="A,B",
                   help="Enumeration families, comma-separated: ferromagnetic, "
                        "antiferromagnetic, ferrimagnetic_by_motif, "
                        "ferrimagnetic_by_species, antiferromagnetic_by_motif. "
                        "Default: ferromagnetic + antiferromagnetic, plus "
                        "whatever pymatgen adds automatically for this "
                        "structure.")
    p.add_argument("--symmetrize", action="store_true",
                   help="Replace the input structure with pymatgen's symmetrised "
                        "one (SpacegroupAnalyzer.get_refined_structure) before "
                        "enumerating. Off by default: without it the input "
                        "POSCAR is used exactly as written and "
                        "SpacegroupAnalyzer is never called on the way to a "
                        "folder.")
    p.add_argument("--symprec", type=float, default=None, metavar="A",
                   help="Symmetry tolerance handed to pymatgen, for --symmetrize "
                        "and for the space group reported in SUMMARY.txt and "
                        "SYMMETRY.txt. Default: pymatgen's own.")
    p.add_argument("--dry-run", action="store_true",
                   help="List what would be written, without creating anything.")
    enumerate_magnetic(p.parse_args())


if __name__ == "__main__":
    main()
