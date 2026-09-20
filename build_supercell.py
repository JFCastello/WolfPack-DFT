#!/usr/bin/env python3
"""
build_supercell.py  (invoked on PATH as: build-supercell)
Build a VASP supercell from a POSCAR, or enumerate magnetic orderings.

==================================================================
WHAT THIS SCRIPT DOES
==================================================================
Reads a VASP POSCAR, applies an integer scaling transformation to
the lattice vectors, and writes the resulting supercell to a new
POSCAR. Site properties from the input (selective dynamics flags,
velocities) are preserved on every replicated image. The original
comment line is also kept and annotated with the scaling used.

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
MAGNETIC CONFIGURATIONS  (--magnetic-configs)
==================================================================
A second, separate mode. Instead of building one supercell it
enumerates the inequivalent collinear spin orderings of ./POSCAR
and writes one ready-to-run folder per ordering, grouped by type:

  magnetic_configs/
    00_NM/config_01/    POSCAR INCAR KPOINTS POTCAR
                        NM_config_01.cif  NM_config_01.vesta
    01_FM/config_01/
    02_AFM/config_01/ config_02/ ...
    03_FiM/config_01/
    SUMMARY.txt         <- the index: type, net moment, cell, notes

Each folder gets an INCAR derived from ./INCAR with only ISPIN and
MAGMOM changed. Points worth knowing:

* MAGMOM MAGNITUDES come from your own INCAR's MAGMOM when it has
  one (per element, largest |value|); the SIGNS come from each
  ordering. Without a MAGMOM it falls back to pymatgen's defaults,
  which are high-spin (V 5, Fe 5, Ni 5, Cu 1.73) and usually differ
  from what you would have chosen. The output says which was used.

* NUPDOWN IS DELIBERATELY NOT SET, and an inherited one is
  commented out: it would force every ordering to the same total
  moment, which is the opposite of what you are comparing. The
  MAGMOM seed is what steers each calculation, and an ordering that
  collapses to another is telling you something real.

* YOUR CELL IS KEPT WHEREVER THE ORDERING FITS IN IT. The
  enumerator does not return the cell it was given -- it reduces
  the basis, so the same lattice comes back with different vectors,
  different fractional coordinates and a different site order.
  Those orderings are mapped back onto your POSCAR, so the folder
  holds YOUR cell, YOUR site order and YOUR KPOINTS untouched, with
  only MAGMOM added.

* SOME CELLS STILL DIFFER, and the index says which. An ordering
  has its own magnetic periodicity and your cell need not admit it
  (on conventional NiO, five of eight orderings have exactly your
  atom count and still do not fit). Antiferromagnets often need a
  supercell, and pymatgen may find a smaller primitive cell. Those
  folders are marked SUPERCELL, primitive cell or CELL REBUILT --
  compare energies PER ATOM, and note that selective dynamics is
  dropped there, because the frozen atoms have no counterpart.
  KPOINTS is rescaled from the RECIPROCAL lattice vectors, which is
  what the mesh subdivides; an unchanged lattice is left alone.

* THE POTCAR IS CHECKED, NOT ASSUMED. Enumeration can reorder the
  species blocks; a POTCAR whose order no longer matches is NOT
  copied, and the folder says so. Copying it blindly would give a
  run that completes and is silently meaningless.

* EVERY FOLDER CARRIES ITS OWN PICTURE. Alongside the inputs go a
  .cif and a .vesta named after the configuration, both drawing an
  arrow on each magnetic atom -- red for up, blue for down, length
  proportional to the moment, so a ferrimagnet reads as such at a
  glance. Open either in VESTA to check the folder really holds the
  ordering you think it does before spending compute on it. VASP
  reads neither.

Needs the enumlib binaries (enum.x, makestr.x), which install.sh
pulls into the conda environment. Without them pymatgen can only
build the ferromagnetic ordering.

==================================================================
USAGE
==================================================================
  build-supercell POSCAR                           # default 2x2x2
  build-supercell POSCAR -s 3 3 1                  # 3x3x1 slab
  build-supercell POSCAR -s 2 2 2 --sort           # group species
  build-supercell POSCAR -s -1 1 1 1 -1 1 1 1 -1 -o POSCAR_conv
        # primitive FCC -> conventional cubic via full 3x3 matrix

  build-supercell --magnetic-configs --dry-run     # look before writing
  build-supercell --magnetic-configs               # write the folders
  build-supercell --magnetic-configs --magnetic-species V
        # treat only V as magnetic, ignoring Cu
"""

import argparse
import math
import sys
import re
import shutil
from pathlib import Path

from pymatgen.io.vasp import Poscar


# =============================================================================
# MAGNETIC CONFIGURATION ENUMERATION  (--magnetic-configs)
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


def _incar_set_line(text, key, value, note=""):
    """Replace KEY's whole line in INCAR text, or append it.

    Whole-line replacement, because whether VASP honours the first or the last
    occurrence of a repeated tag is version-dependent -- appending a duplicate
    would make the result depend on the build. Anchoring after the tag also
    keeps MAGMOM from matching a commented line.
    """
    cc = _incar_comment_char(text)
    line = f"{key} = {value}" + (f"   {cc} {note}" if note else "")
    pat = re.compile(rf"^[ \t]*{key}[ \t]*=.*$", re.IGNORECASE | re.MULTILINE)
    if pat.search(text):
        return pat.sub(line, text, count=1)
    return text.rstrip("\n") + "\n" + line + "\n"


def _incar_comment_line(text, key, note):
    """Comment KEY out, preserving it for the record.

    The line is disabled with '#' -- which VASP always honours -- while the
    note that explains why uses whatever the file annotates with.
    """
    cc = _incar_comment_char(text)
    pat = re.compile(rf"^([ \t]*)({key}[ \t]*=.*)$", re.IGNORECASE | re.MULTILINE)
    return pat.sub(rf"\1# \2   {cc} {note}", text)


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


def _incar_comment_char(text):
    """The character this INCAR already uses for a TRAILING comment ('!' or '#').

    VASP honours both, so this is only about handing back a file that still
    reads like the one that came in. Only trailing comments are counted: a file
    can annotate with '!' while commenting whole tags out with '#', and it is
    the annotation style that the lines written here have to match.
    """
    trailing = re.findall(r"=[ \t]*\S+[ \t]+([!#])", text)
    return "!" if trailing.count("!") > trailing.count("#") else "#"


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


def _in_reference_cell(ref, struct):
    """The same ordering written in the cell of the POSCAR the user handed in.

    The enumerator does not return the cell it was given. enumlib's adaptor
    reduces the basis, so LaMnO3's Pnma cell comes back with c -> c + a: same
    lattice, same volume, same structure -- but different lattice vectors,
    different fractional coordinates and a different site order. Everything
    downstream then disagrees with the user's own reference run, and the MAGMOM
    they read refers to sites in an order that is not theirs.

    When the ordering fits in their cell, this puts it back there: their
    coordinates, their site order, their selective dynamics, their KPOINTS left
    untouched because the lattice is then literally identical.

    Returns None when it does not fit. That is a real physical outcome, not a
    defensive branch -- a magnetic ordering has its own periodicity, and a given
    cell need not admit it. On conventional NiO five of eight orderings have
    exactly the reference's 8 sites and still cannot be expressed in it.
    """
    import numpy as np
    from pymatgen.analysis.structure_matcher import StructureMatcher, ElementComparator

    if len(struct) != len(ref):
        return None
    if abs(struct.lattice.volume - ref.lattice.volume) > 1e-3 * ref.lattice.volume:
        return None
    matcher = StructureMatcher(primitive_cell=False, attempt_supercell=True,
                               comparator=ElementComparator())
    like = matcher.get_s2_like_s1(ref, _demagnetised(struct))
    if like is None or len(like) != len(ref):
        return None
    if [s.specie.symbol for s in like] != [s.specie.symbol for s in ref]:
        return None
    # The guard that carries the weight. get_s2_like_s1 returns its best
    # alignment whether or not one exists, so demand that every site land ON a
    # reference site rather than merely near one -- otherwise a plausible-looking
    # near-match would write the ordering onto the wrong atoms.
    if any(ref.lattice.get_all_distances(like[i].frac_coords,
                                         ref[i].frac_coords)[0][0] > 1e-3
           for i in range(len(ref))):
        return None
    out = ref.copy()
    out.add_site_property("magmom", list(like.site_properties["magmom"]))
    return out


# --- visualisation: one .cif and one .vesta per configuration ---------------
# Reading a MAGMOM and reconstructing the ordering in your head is slow and
# error-prone. Seeing arrows on the magnetic atoms is the fastest way to notice
# that a folder does not hold the ordering you thought it did -- before spending
# hours of compute on it.
#
# Both files are for LOOKING at. VASP never reads either one.

VESTA_ARROW_A = 1.5     # longest arrow, in Angstrom: visible without reaching
                        # into the neighbouring atoms
VESTA_UP = "255 0 0"    # red
VESTA_DOWN = "0 0 255"  # blue


def _write_magnetic_cif(struct, path, title):
    """Write a magCIF carrying the structure and its initial moments."""
    from pymatgen.io.cif import CifWriter
    # symprec must stay None: CifWriter refuses to combine it with write_magmoms,
    # and reducing by symmetry would merge sites that this ordering distinguishes
    # precisely by their spin.
    # Only ask for the magnetic loop when there is something to put in it:
    # with every moment zero, CifWriter emits the four _atom_site_moment_*
    # headers followed by no data rows at all. An empty loop_ is malformed CIF
    # and breaks readers -- pymatgen's own parser raises on it.
    has_moment = any(abs(m) > 1e-6 for m in _spins(struct))
    cif = CifWriter(_demagnetised(struct), write_magmoms=has_moment)
    text = str(cif).replace("# generated using pymatgen",
                            f"# {title} -- generated by build-supercell", 1)
    Path(path).write_text(text)


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

    # ---- which atoms carry a moment -------------------------------------
    if args.magnetic_species:
        mag_els = [s.strip() for s in args.magnetic_species.split(",") if s.strip()]
        present = {el.symbol for el in ref.composition.elements}
        unknown = [e for e in mag_els if e not in present]
        if unknown:
            sys.exit(f"error: {', '.join(unknown)} not in this structure "
                     f"(it has {', '.join(sorted(present))})")
    else:
        mag_els = _magnetic_elements(ref)
        if not mag_els:
            sys.exit("error: no magnetic elements detected in "
                     f"{ref.composition.reduced_formula}.\n"
                     "       Detection uses pymatgen's default-moment table; if an element\n"
                     "       here should be magnetic, name it: --magnetic-species Fe,Ni")

    # ---- moment magnitudes ----------------------------------------------
    incar_path = root / "INCAR"
    incar_text = incar_path.read_text() if incar_path.is_file() else ""
    magnitudes, mag_src = None, "pymatgen defaults (high-spin)"
    if incar_text:
        try:
            magnitudes = _magmom_magnitudes_from_incar(Incar.from_file(str(incar_path)), ref)
        except Exception:
            magnitudes = None
        if magnitudes:
            mag_src = "MAGMOM in ./INCAR"
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

    # ---- collect, with the non-magnetic reference first --------------------
    entries = []
    nm = ref.copy()
    nm.add_site_property("magmom", [0.0] * len(nm))
    entries.append(("NM", nm, "reference, ISPIN=2 with zero moments", True))
    for struct, origin in zip(enum.ordered_structures, enum.ordered_structure_origins):
        # Put the ordering back in the user's own cell wherever it fits, so the
        # folder holds THEIR POSCAR with only the moments added.
        mapped = _in_reference_cell(ref, struct)
        struct = mapped if mapped is not None else struct
        entries.append((_ordering_of(struct), struct, origin, mapped is not None))

    order = {"NM": 0, "FM": 1, "AFM": 2, "FiM": 3}
    entries.sort(key=lambda e: order.get(e[0], 9))

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
    for kind, struct, origin, own_cell in entries:
        counts[kind] = counts.get(kind, 0) + 1
        folder = out_root / f"{order.get(kind, 9):02d}_{kind}" / f"config_{counts[kind]:02d}"
        spins = _spins(struct)
        net = sum(spins)
        # pymatgen reduces the input to its PRIMITIVE cell before enumerating,
        # so a configuration can have FEWER sites than the POSCAR it came from.
        # Calling that a supercell would be backwards.
        if len(struct) > len(ref):
            cellnote = f"SUPERCELL x{len(struct) / len(ref):g}"
        elif len(struct) < len(ref):
            cellnote = f"primitive cell ({len(ref)} -> {len(struct)} sites)"
        elif not own_cell:
            # Same site count, still not the user's cell: this ordering has a
            # magnetic periodicity their cell cannot hold, so pymatgen built its
            # own. Worth saying plainly -- it is the one case where the POSCAR
            # differs from theirs without the atom count hinting at it.
            cellnote = "CELL REBUILT (your cell cannot hold this ordering)"
        else:
            cellnote = ""
        expanded = len(struct) != len(ref)
        note = ""

        # POSCAR and MAGMOM come from ONE object in ONE order; never re-read.
        # De-spun, because Poscar leaks "Mn,spin=np.int64(5)" into the label
        # column of a Species(spin=...) structure.
        out_struct = _demagnetised(struct)
        if not own_cell and "selective_dynamics" in out_struct.site_properties:
            # When pymatgen rebuilds the cell it hands each site the properties
            # of its whole symmetry orbit, so the flags arrive SMEARED: on
            # conventional NiO one frozen O and one part-frozen Ni came back as
            # four of each. In a cell whose atoms have no counterpart in the
            # user's there is no right answer, and a wrong constraint is far
            # worse than none -- it relaxes a structure nobody asked for and
            # says nothing. Drop them, and put it in the index.
            out_struct.remove_site_property("selective_dynamics")
            note = "selective dynamics DROPPED (different cell, no site correspondence)"

        if not args.dry_run:
            folder.mkdir(parents=True, exist_ok=True)
            Poscar(out_struct, comment=f"{ref_title} | {kind} ({origin})"
                   ).write_file(str(folder / "POSCAR"))

            txt = incar_text
            txt = _incar_set_line(txt, "ISPIN", "2", "spin-polarised")
            txt = _incar_set_line(txt, "MAGMOM",
                                  Incar({"MAGMOM": spins}).get_str().split("=", 1)[1].strip(),
                                  f"{kind} ordering ({origin})")
            if re.search(r"^[ \t]*NUPDOWN[ \t]*=", txt, re.IGNORECASE | re.MULTILINE):
                # An inherited NUPDOWN would force every ordering to the same
                # total moment -- the opposite of what is being compared.
                txt = _incar_comment_line(txt, "NUPDOWN",
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
            _write_magnetic_cif(struct, folder / f"{stem}.cif", stem)
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
                        net, expanded, cellnote, note))

    # ---- report ------------------------------------------------------------
    hdr = (f"{'folder':<38} {'type':<4} {'origin':<12} {'sites':>5} {'net':>6}  notes")
    lines = [hdr, "-" * len(hdr)]
    for f, k, o, n, net, exp, cn, note in summary:
        lines.append(f"{f:<38} {k:<4} {o:<12} {n:>5} {net:>+6.1f}  "
                     f"{cn + '; ' if cn else ''}{note}")
    body = "\n".join(lines)
    print("\n" + body)

    if not args.dry_run:
        (out_root / "SUMMARY.txt").write_text(
            f"Magnetic configurations from {args.poscar}\n"
            f"Magnetic elements : {', '.join(mag_els)}\n"
            f"Moment magnitudes : {mag_src}\n\n{body}\n\n"
            "Each folder also carries <TYPE>_config_NN.cif and .vesta for viewing the\n"
            "ordering -- arrows on the magnetic atoms, red for up and blue for down.\n"
            "Neither is read by VASP.\n\n"
            "Every folder not marked SUPERCELL, primitive cell or CELL REBUILT carries\n"
            "YOUR cell, YOUR site order and YOUR KPOINTS, with only the moments added.\n"
            "The marked ones could not: pymatgen returns the cell the ordering needs,\n"
            "so their POSCAR is a different (equivalent or larger) cell.\n\n"
            "Cells of different size are NOT comparable directly -- compare energy PER ATOM.\n"
            "NUPDOWN is deliberately unset: the MAGMOM seed guides each ordering, and\n"
            "an ordering that collapses to another is telling you something real.\n")
        print(f"\nWrote {made} configuration(s) under {MAG_DIR}/   (index: {MAG_DIR}/SUMMARY.txt)")
        if any(s[5] for s in summary):
            print("note: some cells were expanded -- compare energies PER ATOM, not per cell.",
                  file=sys.stderr)


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

    m = p.add_argument_group("magnetic configuration enumeration")
    m.add_argument("--magnetic-configs", action="store_true",
                   help="Instead of building a supercell, enumerate the "
                        "inequivalent collinear spin orderings of ./POSCAR and "
                        "write one ready-to-run folder per ordering, grouped by "
                        "type (NM / FM / AFM / FiM). Each folder gets a POSCAR, "
                        "an INCAR derived from ./INCAR with ISPIN and MAGMOM "
                        "set, a KPOINTS rescaled if the cell was expanded, and "
                        "the POTCAR when its species order still matches. "
                        "Requires the enumlib binaries.")
    m.add_argument("--magnetic-species", metavar="EL,EL",
                   help="Treat exactly these elements as magnetic, e.g. 'V,Fe'. "
                        "Default: every element pymatgen has a default moment "
                        "for.")
    m.add_argument("--max-orderings", type=int, default=64, metavar="N",
                   help="Cap on how many orderings to enumerate. Default: 64 "
                        "(pymatgen's own).")
    m.add_argument("--strategies", metavar="A,B",
                   help="Enumeration families, comma-separated: ferromagnetic, "
                        "antiferromagnetic, ferrimagnetic_by_motif, "
                        "ferrimagnetic_by_species, antiferromagnetic_by_motif. "
                        "Default: ferromagnetic + antiferromagnetic, plus "
                        "whatever pymatgen adds automatically for this "
                        "structure.")
    m.add_argument("--dry-run", action="store_true",
                   help="List what would be written, without creating anything.")

    args = p.parse_args()

    # A separate mode: it enumerates orderings rather than building a supercell,
    # so none of the scaling options apply to it.
    if args.magnetic_configs:
        if args.sort:
            # Sorting a spin-bearing structure regroups sites by spin sign,
            # which would silently break the POSCAR/MAGMOM correspondence.
            sys.exit("error: --sort cannot be combined with --magnetic-configs "
                     "(it would reorder sites away from their moments)")
        enumerate_magnetic(args)
        return

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
