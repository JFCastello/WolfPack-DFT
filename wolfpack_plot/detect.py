"""
wolfpack_plot.detect
====================
Work out WHAT was calculated in a folder, so the plotter can be pointed at a
bare calculation directory instead of the classic ``Scf/ Bands/ Dos/`` tree.

Two layouts are supported:

  * **workflow**  -- ``<root>/Scf``, ``<root>/Bands``, ``<root>/Dos`` exist.
    Band structure + DOS are combined into one figure (the original behaviour).

  * **single**    -- ``<root>`` IS a calculation (INCAR/KPOINTS/vasprun.xml in
    place). The kind is read off the inputs and only the matching plots are
    produced: a band-structure figure OR a density-of-states figure.

The kind is decided from the INPUTS (INCAR + KPOINTS), because those state the
INTENT, and only then confirmed against the outputs that are actually present:

  KPOINTS line-mode                       -> band structure (the k-path IS the
                                             defining feature of a band run)
  regular mesh + tetrahedron/LORBIT/NEDOS -> density of states
  Wannier90 outputs present               -> interpolated bands / DOS (w90.py)

Nothing here imports the heavy scientific stack.
"""
from __future__ import annotations

import re
from pathlib import Path

# Kinds this module can report.
KIND_BANDS = "bands"
KIND_DOS = "dos"
KIND_BOTH = "both"
KIND_W90 = "wannier90"

# Files that mean "a band structure was computed here" / "a DOS was computed
# here".  vasprun.xml carries both, so it never discriminates on its own.
_BAND_OUTPUTS = ("EIGENVAL", "PROCAR", "vasprun.xml")
_DOS_OUTPUTS = ("DOSCAR", "vasprun.xml")


# --------------------------------------------------------------------------- #
# INCAR / KPOINTS parsing (tolerant: these files are hand-edited constantly)
# --------------------------------------------------------------------------- #
def read_incar_tags(path):
    """Parse an INCAR into {TAG: value-string}.  Missing file -> {}.

    Handles ``A = 1 ; B = 2`` on one line, inline ``#``/``!`` comments and any
    capitalisation.  Values stay strings; callers coerce what they need.
    """
    tags = {}
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return tags
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].split("!", 1)[0].strip()
        if not line:
            continue
        for part in line.split(";"):
            if "=" not in part:
                continue
            key, _, val = part.partition("=")
            key = key.strip().upper()
            if key:
                tags[key] = val.strip()
    return tags


def _as_int(val, default=None):
    try:
        return int(str(val).split()[0])
    except (TypeError, ValueError, IndexError):
        return default


def _as_bool(val):
    return str(val).strip().upper().startswith((".T", "T"))


# --------------------------------------------------------------------------- #
# meta-GGA
# --------------------------------------------------------------------------- #
# A tau-dependent meta-GGA (SCAN, R2SCAN, TPSS, MBJ, ...) is NOT a functional of
# the density alone: the XC potential also needs the kinetic-energy density
#
#     tau(r) = (h^2/2m) SUM_nk f_nk |grad psi_nk(r)|^2
#
# which is built from the OCCUPIED ORBITALS over the whole Brillouin zone. The
# CHGCAR stores n(r) and nothing else, so the ordinary band recipe -- freeze the
# charge, diagonalise along a k-path with ICHARG=11 -- cannot reconstruct the
# Hamiltonian. VASP does NOT abort: it runs and emits a plausible-looking band
# structure computed with the wrong potential. Hence a meta-GGA band run must be
# SELF-CONSISTENT on a regular mesh, with the high-symmetry path supplied
# separately in KPOINTS_OPT (the same scheme hybrids use).
#
# Consequence for THIS module: for a meta-GGA band run KPOINTS is a regular MESH,
# so the "KPOINTS is line-mode" test that identifies an ordinary band run fails.
# KPOINTS_OPT is what marks it, and it must be checked FIRST.
_METAGGA_OFF = {"", "NONE", "--", "FALSE", ".FALSE.", "0"}


def metagga_of(tags):
    """The active METAGGA functional name, or None. Case-normalised."""
    val = str(tags.get("METAGGA", "")).strip().strip("'\"").upper()
    return None if val in _METAGGA_OFF else val


def find_kpoints_opt(folder):
    """Path to a usable KPOINTS_OPT in `folder`, or None.

    Only counts when it really carries a k-PATH (line-mode or an explicit list);
    an empty or malformed file is ignored so callers fall back to KPOINTS.
    """
    p = Path(folder) / "KPOINTS_OPT"
    try:
        if not (p.is_file() and p.stat().st_size > 0):
            return None
    except OSError:
        return None
    return p if kpoints_mode(p) in ("line", "explicit") else None


def kpoints_mode(path):
    """Classify a KPOINTS file: 'line' | 'mesh' | 'explicit' | None.

    Line 3 (0-indexed 2) holds the mode character; VASP only looks at its first
    letter.  'L' => line-mode (a band path).  'G'/'M' => a regular mesh.  When
    line 2 (the count) is > 0 the list is explicit.  A missing/short file gives
    None so callers can fall back to other evidence.
    """
    try:
        lines = [l.strip() for l in Path(path).read_text(errors="replace").splitlines()]
    except OSError:
        return None
    if len(lines) < 3:
        return None
    nk = _as_int(lines[1], 0) or 0
    head = lines[2][:1].upper() if lines[2] else ""
    if head == "L":
        return "line"
    if head in ("G", "M", "A"):
        return "mesh"
    if nk > 0:
        # Explicit list: a band path is often given this way too. Treat a long
        # list with no weights column as explicit; the caller weighs it lightly.
        return "explicit"
    return "mesh"


# --------------------------------------------------------------------------- #
# Wannier90 presence
# --------------------------------------------------------------------------- #
def find_wannier90(folder):
    """Return a dict of Wannier90 artefacts found in `folder` (empty if none).

    Recognises both post-processing routes:
      wannier90.x  bands_plot  ->  *_band.dat  (+ *_band.kpt / *_band.gnu)
      postw90.x    kpath/dos   ->  *-bands.dat / *-path.kpt , *-dos.dat
    """
    folder = Path(folder)
    found = {}
    if not folder.is_dir():
        return found

    def first(patterns):
        for pat in patterns:
            hits = sorted(folder.glob(pat))
            if hits:
                return hits[0]
        return None

    found["win"] = first(["*.win"])
    # bands: wannier90.x style first, then postw90 style
    found["band_dat"] = first(["*_band.dat", "*-bands.dat", "*_bands.dat"])
    found["band_kpt"] = first(["*_band.kpt", "*-path.kpt", "*_bands.kpt"])
    found["band_gnu"] = first(["*_band.gnu", "*-bands.gnu"])
    found["dos_dat"] = first(["*-dos.dat", "*_dos.dat"])
    found["hr_dat"] = first(["*_hr.dat"])
    return {k: v for k, v in found.items() if v is not None}


# --------------------------------------------------------------------------- #
# The detector
# --------------------------------------------------------------------------- #
def detect_calc(folder):
    """Describe what a single calculation folder contains.

    Returns a dict:
        kind      'bands' | 'dos' | 'both' | 'wannier90' | None
        why       short human explanation of the decision
        tags      the parsed INCAR tags
        kmode     the KPOINTS mode ('line' / 'mesh' / ...)
        w90       dict of Wannier90 artefacts (possibly empty)
        has_*     which outputs are on disk
    """
    folder = Path(folder)
    tags = read_incar_tags(folder / "INCAR")
    kmode = kpoints_mode(folder / "KPOINTS")
    w90 = find_wannier90(folder)

    def present(name):
        p = folder / name
        try:
            return p.is_file() and p.stat().st_size > 0
        except OSError:
            return False

    has_dos = present("DOSCAR")
    # A KPOINTS_OPT run writes NO EIGENVAL_OPT and no DOSCAR_OPT -- checked
    # against the VASP 6.5.1 source, where the only extra output file is
    # PROCAR_OPT (src/linear_response.F:1863, gated on LORBIT>10). The
    # KPOINTS_OPT eigenvalues live inside vasprun.xml, in the
    # <eigenvalues_kpoints_opt> block.
    has_eig = present("EIGENVAL")
    has_vr = present("vasprun.xml")
    has_procar = present("PROCAR") or present("PROCAR_OPT")

    ismear = _as_int(tags.get("ISMEAR"))
    lorbit = _as_int(tags.get("LORBIT"))
    nedos = _as_int(tags.get("NEDOS"))
    icharg = _as_int(tags.get("ICHARG"))
    lwannier = _as_bool(tags.get("LWANNIER90", ""))

    mgga = metagga_of(tags)
    kopt = find_kpoints_opt(folder)

    # Physics problems that make the DATA wrong, not just the plot. Surfaced to
    # the user rather than silently plotted, because VASP produced them without
    # complaining and they look completely normal on a figure.
    problems = []
    if mgga and icharg is not None and icharg >= 10:
        problems.append(
            f"METAGGA={mgga} with ICHARG={icharg}: a meta-GGA Hamiltonian needs "
            "the kinetic-energy density tau, which is built from the orbitals "
            "and is NOT in the CHGCAR, so a frozen charge density is not enough. "
            "VASP REFUSES this combination outright -- 'ICHARG>9 is currently "
            "not supported for meta-GGA functionals' (src/fock.F) -- so any "
            "output in this folder was NOT produced by this INCAR. Run it "
            "self-consistently on a regular mesh instead"
            + (", with the high-symmetry path in KPOINTS_OPT."
               if kmode == "line" or kopt else "."))
    if mgga and kmode == "line" and not kopt:
        problems.append(
            f"METAGGA={mgga} with a line-mode KPOINTS and no KPOINTS_OPT: tau "
            "cannot be evaluated on a bare k-path. Use a regular mesh in KPOINTS "
            "and put the high-symmetry path in KPOINTS_OPT.")

    def result(kind, why, **extra):
        d = dict(kind=kind, why=why, tags=tags, kmode=kmode, w90=w90,
                 has_dos=has_dos, has_bands=has_eig or has_vr,
                 has_procar=has_procar, metagga=mgga, kpoints_opt=kopt,
                 problems=problems)
        d.update(extra)
        return d

    # --- Wannier90 wins when its post-processing output is actually present, --
    # --- because then the interpolated curves are the point of the folder.  ---
    if w90.get("band_dat") or w90.get("dos_dat"):
        return result(KIND_W90, "Wannier90 output found "
                      f"({', '.join(sorted(k for k in w90 if k.endswith('dat')))})")

    # --- KPOINTS_OPT: the k-path lives in its OWN file ----------------------
    # Checked BEFORE the line-mode test, because the whole point of the scheme is
    # that KPOINTS is a regular MESH (it drives the self-consistent part) while
    # the path sits in KPOINTS_OPT. Judging by KPOINTS alone would classify a
    # meta-GGA/hybrid band run as a DOS run.
    if kopt is not None:
        # KPOINTS_OPT is not meta-GGA-only -- any functional may use it, and a
        # plain PBE run that does should not be described as a meta-GGA scheme.
        scheme = f"METAGGA={mgga}" if mgga else "KPOINTS_OPT scheme"
        # ONE run carries BOTH halves of the figure. KPOINTS is the regular mesh
        # that drove self-consistency (and produced the DOS); KPOINTS_OPT is the
        # path VASP diagonalised afterwards in one shot. They land in the SAME
        # vasprun.xml -- the bands under <eigenvalues_kpoints_opt>, the DOS under
        # the ordinary <dos> -- so a meta-GGA run gets the same combined
        # bands+DOS figure a PBE Scf/ Bands/ Dos/ tree gets, from one folder and
        # with no extra command.
        if has_dos and has_vr:
            return result(KIND_BOTH,
                          "KPOINTS_OPT holds the k-path and KPOINTS the mesh "
                          "that made it self-consistent, so this one run "
                          f"carries both bands and DOS ({scheme})")
        return result(KIND_BANDS,
                      "KPOINTS_OPT holds the k-path (self-consistent band run; "
                      f"{scheme})")

    # --- band structure: a k-path is the defining evidence -------------------
    if kmode == "line":
        return result(KIND_BANDS, "KPOINTS is line-mode (a band path)")

    # --- DOS: a regular mesh plus any DOS-specific intent --------------------
    dos_hints = []
    if ismear is not None and ismear <= -4:
        dos_hints.append(f"ISMEAR={ismear} (tetrahedron)")
    if nedos:
        dos_hints.append(f"NEDOS={nedos}")
    if lorbit is not None and lorbit >= 10:
        dos_hints.append(f"LORBIT={lorbit}")
    if icharg is not None and icharg >= 10:
        dos_hints.append(f"ICHARG={icharg} (non-self-consistent)")

    if kmode in ("mesh", "explicit", None) and dos_hints and has_dos:
        return result(KIND_DOS, "regular k-mesh + " + ", ".join(dos_hints))

    # --- last resort: decide from what is on disk ---------------------------
    if has_dos and kmode != "line":
        return result(KIND_DOS, "DOSCAR present on a regular mesh")
    if has_eig or has_vr:
        return result(KIND_BANDS, "eigenvalues present")

    return result(None, "no VASP output found in this folder")


def detect_layout(root, bands_dir="Bands", dos_dir="Dos", scf_dir="Scf"):
    """Decide how to treat `root`: the classic workflow tree or one calculation.

    Returns a dict with:
        layout   'workflow' | 'single'
        kind     what to plot ('both' for a complete workflow tree)
        bands    folder holding the band data   (None if not applicable)
        dos      folder holding the DOS data    (None if not applicable)
        scf      folder holding the Fermi level (may equal bands/dos)
        why      human explanation
        w90      Wannier90 artefacts when kind == 'wannier90'
    """
    root = Path(root)
    b, d, s = root / bands_dir, root / dos_dir, root / scf_dir
    if b.is_dir() and d.is_dir():
        # Still inspect the two sub-calculations: this branch short-circuits on
        # the DIRECTORY NAMES, so without this a meta-GGA tree would be plotted
        # with no warning that its band run used the wrong (ICHARG=11) recipe.
        binfo, dinfo = detect_calc(b), detect_calc(d)
        return dict(layout="workflow", kind=KIND_BOTH, bands=b, dos=d,
                    scf=s if s.is_dir() else b, w90={},
                    why=f"workflow tree ({bands_dir}/ + {dos_dir}/ found)",
                    metagga=binfo["metagga"] or dinfo["metagga"],
                    kpoints_opt=binfo["kpoints_opt"],
                    problems=binfo["problems"] + dinfo["problems"],
                    info=binfo)

    info = detect_calc(root)
    kind = info["kind"]
    common = dict(layout="single", kind=kind, w90=info["w90"], why=info["why"],
                  metagga=info["metagga"], kpoints_opt=info["kpoints_opt"],
                  problems=info["problems"], info=info)
    if kind == KIND_BOTH:
        # One self-consistent run holding both (the KPOINTS_OPT scheme). Both
        # readers point at the same folder and pick their own half out of the
        # same vasprun.xml.
        return dict(common, bands=root, dos=root, scf=root)
    if kind == KIND_BANDS:
        return dict(common, bands=root, dos=None, scf=root)
    if kind == KIND_DOS:
        return dict(common, bands=None, dos=root, scf=root)
    if kind == KIND_W90:
        return dict(common, bands=root, dos=root, scf=root)
    return dict(common, bands=None, dos=None, scf=root)
