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
    run_pipelines.sh    <- submits the whole sweep

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

  magnetic_configs/run_pipelines.sh --dry-run   # then, to launch the sweep
  magnetic_configs/run_pipelines.sh
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


def _write_master_pipeline(out_root, folders):
    """Write the script that runs the whole pipeline in every folder at once.

    Nine configurations means nine times dry-run -> recommend -> test, and doing
    that by hand is both tedious and easy to get half-done. The stages are not
    independent, though: recommend reads what the dry run measured, and test
    reads what recommend chose. So they are chained with a SLURM DEPENDENCY
    rather than run in sequence here -- the whole sweep is submitted in one go
    and SLURM does the waiting, which means it survives you logging out.

    Per folder: the stage-1 job, then one small driver job holding
    afterok:<stage-1> that runs stages 2 and 3. vasp-test submits stage 3
    itself, so three jobs per folder in total.

    The driver runs on a COMPUTE node, so it carries what a compute node may not
    have: the absolute path of this interpreter (conda will not be activated
    there) and a copy of the cluster profile (on clusters whose $HOME is a
    project filesystem, compute nodes do not mount it -- the same trap that made
    every benchmark job exit 2 with "this cluster has not been configured").
    """
    import os
    import shutil as _sh

    toolkit = os.path.dirname(os.path.realpath(__file__))
    conf = os.environ.get("WOLFPACK_CLUSTER_CONF") or os.path.join(
        os.path.expanduser("~"), ".config", "wolfpack-dft", "cluster.conf")
    staged = out_root / "cluster.conf"
    if os.path.isfile(conf):
        try:
            _sh.copyfile(conf, staged)
        except OSError:
            pass

    rel = [str(Path(f).relative_to(out_root.name)) for f in folders]
    listing = "\n".join(f'    "{r}"' for r in rel)
    path = out_root / "run_pipelines.sh"
    path.write_text(f'''#!/usr/bin/env bash
# Run the parallelisation pipeline in every magnetic configuration, at once.
# Generated by build-magnetic-configs. Safe to re-run: folders that have already
# been launched are skipped unless you pass --force.
#
#   ./run_pipelines.sh            # submit everything
#   ./run_pipelines.sh --dry-run  # print what would be submitted, submit nothing
#   ./run_pipelines.sh --force    # relaunch folders that already have state
#
# Per folder this submits:
#   STAGE 1  vasp-dry-run                      (a 1-rank VASP dry run)
#   STAGE 2+3  a driver job, afterok:STAGE 1,  which runs vasp-recommend-slurm
#              and then vasp-test; vasp-test submits the benchmark itself.
# SLURM does the waiting, so you can log out.
set -uo pipefail
cd "$(dirname "$(readlink -f "${{BASH_SOURCE[0]}}")")" || exit 1

TOOLKIT="{toolkit}"
PYBIN="{sys.executable}"
DRY=0; FORCE=0
for a in "$@"; do
    case "$a" in
        --dry-run|-n) DRY=1 ;;
        --force|-f)   FORCE=1 ;;
        -h|--help)    sed -n '2,14p' "$0" | sed 's/^# \\{{0,1\\}}//'; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

# The profile staged beside this script: a compute node may not be able to read
# the one in $HOME, and the driver job runs on one.
CONF="$PWD/cluster.conf"
[[ -f "$CONF" ]] || CONF="${{WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}}"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"
PART="${{WP_DEBUG_PARTITION:-${{WP_MAIN_PARTITION:-}}}}"
BASE="$PWD"
# Both stages read the profile; point them at the same one this script used, so
# a folder cannot end up sized by a different cluster than the one just checked.
export WOLFPACK_CLUSTER_CONF="$CONF"
if [[ -z "$PART" ]]; then
    echo "ERROR: no partition in the cluster profile. Run vasp-configure first." >&2
    exit 2
fi

FOLDERS=(
{listing}
)

printf '%-34s %-12s %-12s %s\\n' "folder" "stage 1" "stage 2+3" "note"
printf '%s\\n' "------------------------------------------------------------------------------"
n_sub=0; n_skip=0
for d in "${{FOLDERS[@]}}"; do
    note=""; j1="-"; j2="-"
    if [[ ! -f "$d/POTCAR" ]]; then
        note="SKIPPED: no POTCAR (species order did not match the root one)"
        n_skip=$((n_skip+1))
    elif [[ -f "$d/.wolfpack/pipeline.jobid" && $FORCE -eq 0 ]]; then
        # The mark is written when the jobs are SUBMITTED, not when they finish.
        # Guarding on .wolfpack/state.env instead would not work: the dry run
        # writes that from inside its job, so running this script twice in a row
        # would double-submit the whole sweep and burn the allocation twice.
        note="skipped: already submitted as $(cat "$d/.wolfpack/pipeline.jobid") (--force to redo)"
        n_skip=$((n_skip+1))
    elif (( DRY )); then
        note="would submit"; j1="(dry)"; j2="(dry)"
    else
        mkdir -p "$d/.wolfpack"
        log="$BASE/$d/.wolfpack/submit.log"
        out=$(cd "$d" && "$TOOLKIT/vasp_dry_run.sh" 2>"$log" | tail -n1)
        j1="${{out##* }}"
        if [[ ! "$j1" =~ ^[0-9]+$ ]]; then
            # Say WHY. Swallowing stage 1's stderr here would reproduce exactly
            # the class of message that wastes an afternoon: a refusal with no
            # reason attached.
            why=$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -n1)
            note="STAGE 1 did not submit: ${{why:-see .wolfpack/submit.log}}"
            j1="-"; n_skip=$((n_skip+1))
        else
            mkdir -p "$d/.wolfpack"
            drv="$d/.wolfpack/slurm_pipeline.sh"
            {{
                echo "#!/bin/bash"
                echo "#SBATCH --job-name=wp_pipe"
                echo "#SBATCH --partition=${{PART}}"
                echo "#SBATCH --nodes=1"
                echo "#SBATCH --ntasks=1"
                echo "#SBATCH --time=00:20:00"
                echo "#SBATCH --dependency=afterok:${{j1}}"
                echo "#SBATCH --output=.wolfpack/pipeline-%j.out"
                echo "#SBATCH --error=.wolfpack/pipeline-%j.err"
                echo ""
                echo '# STAGES 2 and 3, held until the dry run above finishes.'
                echo 'cd "$SLURM_SUBMIT_DIR" || exit 1'
                echo "# conda is not activated on a compute node: reach the toolkit's"
                echo "# interpreter by absolute path, and put it first on PATH so the"
                echo "# python the shell tools find is the one with pymatgen."
                echo "export PATH=\\"$(dirname "$PYBIN"):\\$PATH\\""
                echo "export WOLFPACK_CLUSTER_CONF=\\"${{CONF}}\\""
                echo "\\"$PYBIN\\" \\"$TOOLKIT/vasp_recommend_slurm.py\\" || exit 1"
                echo "exec \\"$TOOLKIT/vasp_test.sh\\""
            }} > "$drv"
            chmod +x "$drv"
            out2=$(cd "$d" && sbatch ".wolfpack/slurm_pipeline.sh" 2>&1 | tail -n1)
            j2="${{out2##* }}"
            [[ "$j2" =~ ^[0-9]+$ ]] || {{ j2="-"; note="stage 2+3 not submitted: $out2"; }}
            echo "$j1 $j2" > "$d/.wolfpack/pipeline.jobid"
            n_sub=$((n_sub+1))
        fi
    fi
    printf '%-34s %-12s %-12s %s\\n' "$d" "$j1" "$j2" "$note"
done
printf '%s\\n' "------------------------------------------------------------------------------"
echo "submitted: $n_sub    skipped: $n_skip"
(( DRY )) && echo "(dry run -- nothing was submitted)"
echo "watch with:  squeue -u \\$USER"
''')
    path.chmod(0o755)
    return f"{out_root}/run_pipelines.sh"


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
        runner = _write_master_pipeline(out_root, [s[0] for s in summary])
        print(f"\nWrote {made} configuration(s) under {MAG_DIR}/   (index: {MAG_DIR}/SUMMARY.txt)")
        if runner:
            print(f"Launch the whole sweep with:  {runner}   (add --dry-run to look first)")
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
    p.add_argument("--magnetic-species", metavar="EL,EL",
                   help="Treat exactly these elements as magnetic, e.g. 'V,Fe'. "
                        "Default: every element pymatgen has a default moment "
                        "for.")
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
