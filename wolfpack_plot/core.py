"""
wolfpack_plot.core
=================
Orchestration and the public/CLI surface: build a config, read everything,
resolve the projection groups (explicit, auto-selected over an energy window,
or one-per-element), build the figure, and the ``generate()`` API, ``--list``
discovery and ``main()`` entry point.
"""
from __future__ import annotations

import argparse
import pickle
import sys
import textwrap
import warnings
from pathlib import Path

from pymatgen.io.vasp.outputs import BSVasprun

from .config import (BANDS_DIR, DEFAULT_METHOD, DEFAULT_OUT_NAME,
                     DEFAULT_PROJECTIONS, DOS_DIR, DPI, EMAX, EMIN, FIG_H,
                     FIG_W, FONT_FAMILY, GROUP_MODE, MARKER_SIZE,
                     MARKER_TARGET, METHOD_N_UNITS, METHODS, OUT_DIR,
                     OUT_FORMATS, PLAIN_MARKER_SIZE, SCF_DIR, SHOW_TITLE,
                     SYMPREC, ALPHA_MAX, ALPHA_MIN, STACKED_CIRCLE_SIZE,
                     normalize_method)
from .formatting import format_kpt_label
from .physics import (analyze_band_gap, auto_select_units, classify_material,
                      contribution_table, units_to_projection_string,
                      write_report, _group_raw_weight)
from .detect import detect_layout
from .w90 import (describe as w90_describe, read_w90_bands,
                  read_w90_dos)
from .plotting import (build_bands_figure, build_dos_figure,
                       build_figure)
from .structure import (_auto_projection_groups, _partition, _reduced_formula,
                        _site_grouping, _species_counts, assign_channels,
                        parse_projection_spec)
from .vaspio import (_assign_labels, auto_energy_window,
                     auto_energy_window_dos, read_bands, read_dos,
                     read_fermi, resolve_dos_smearing)

try:
    from pymatgen.electronic_structure.core import Spin
except Exception:                                       # pragma: no cover
    Spin = None


# --------------------------------------------------------------------------- #
# Configuration, loading, public API
# --------------------------------------------------------------------------- #
def _make_cfg(**overrides):
    """Build a config namespace from defaults + overrides, validating method/group."""
    cfg = argparse.Namespace(
        root=Path("."), projections=None, method=DEFAULT_METHOD, spin="both",
        title=None, show_title=SHOW_TITLE, emin=None, emax=None,
        markers=MARKER_TARGET, marker_size=MARKER_SIZE,
        plain_marker_size=PLAIN_MARKER_SIZE,
        alpha_min=ALPHA_MIN, alpha_max=ALPHA_MAX,
        circle_size=STACKED_CIRCLE_SIZE,
        auto_projections=0, name=DEFAULT_OUT_NAME, subdir=None,
        overlay_plain=True,
        group=GROUP_MODE, symprec=SYMPREC,
        smear=None, efermi=None, dpi=DPI, figw=FIG_W, figh=FIG_H,
        font=FONT_FAMILY, formats=",".join(OUT_FORMATS), pickle=False,
        verbose=False)
    for k, v in overrides.items():
        if not hasattr(cfg, k):
            raise TypeError(f"generate(): unknown option {k!r}")
        setattr(cfg, k, v)
    cfg.method = normalize_method(cfg.method)
    if cfg.method not in METHODS:
        raise ValueError(f"method must be one of {METHODS}, got {cfg.method!r}")
    if cfg.group not in ("symmetry", "formula", "element"):
        raise ValueError('group must be "symmetry", "formula" or "element", '
                         f'got {cfg.group!r}')
    cfg.root = Path(cfg.root)
    return cfg


def _resolve_spins_value(spin, is_spin):
    # ISPIN=1 (non spin-polarised): there is only one channel, so --spin is
    # meaningless. Ignore it (warn only if the user explicitly asked for a
    # specific channel) and always plot the single set of bands.
    """Resolve --spin + ISPIN into the spin list and a both-channels flag."""
    if not is_spin:
        if spin in ("up", "down"):
            warnings.warn(
                f"the calculation is not spin-polarised (ISPIN=1); --spin "
                f"{spin} is ignored and the single channel is plotted.")
        return [Spin.up], False
    # ISPIN=2 (collinear spin): --spin selects up / down / both.
    if spin == "up":
        return [Spin.up], False
    if spin == "down":
        return [Spin.down], False
    return [Spin.up, Spin.down], True


def _spin_jobs(cfg, bands_data, spins, show_both):
    """Figures to render, as (spins, filename-suffix, title-note, overlay_plain).

    ISPIN=1            -> one plot (no suffix).
    ISPIN=2 --spin up  -> the spin-up channel  (suffix "up").
    ISPIN=2 --spin down-> the spin-down channel (suffix "down").
    ISPIN=2 --spin both-> spin-up + spin-down PLUS the overlaid blue/orange plain
                          plot (suffix "overlay"), unless cfg.overlay_plain=False.
    """
    # A DOS-only folder has no band data; fall back to the spins resolved from
    # the DOS itself (show_both) so --spin still selects up/down/both.
    is_spin = bands_data["is_spin"] if bands_data is not None else bool(show_both)
    if not is_spin:
        return [(spins, "", None, False)]
    if cfg.spin == "up":
        return [([Spin.up], "up", r"\uparrow", False)]
    if cfg.spin == "down":
        return [([Spin.down], "down", r"\downarrow", False)]
    jobs = [([Spin.up], "up", r"\uparrow", False),
            ([Spin.down], "down", r"\downarrow", False)]
    if getattr(cfg, "overlay_plain", True):
        jobs.append(([Spin.up, Spin.down], "overlay", r"\uparrow\!\downarrow", True))
    return jobs


def _resolve_groups(cfg, bands_data, dos_data, structure, n_orb, grouping, efermi):
    """Decide the projection groups for the chosen method.

    plain                   -> no groups.
    --projections given     -> parse them.
    --auto-projections N    -> rank (element|Wyckoff-site, dominant-l) over the
                               energy window and pick the top N.
    otherwise               -> one group per element (with per-method checks).
    """
    method = cfg.method
    if method == "plain":
        return []

    spec = cfg.projections if cfg.projections is not None else DEFAULT_PROJECTIONS
    auto_n = int(getattr(cfg, "auto_projections", 0) or 0)

    if not spec and auto_n > 0:
        fixed = METHOD_N_UNITS.get(method)
        n_needed = fixed if fixed else auto_n
        # WHERE THE RANKING WEIGHTS COME FROM: the DOS, and only the DOS.
        # Reaching into dos_data["cdos"] without checking it exists is what
        # killed five of the six quick plots in a bands-only folder, with
        # "'NoneType' object is not subscriptable".
        if dos_data is not None:
            chosen, level, ranking = auto_select_units(
                dos_data["cdos"], efermi, cfg.emin, cfg.emax, structure,
                grouping, n_needed, symprec=getattr(cfg, "symprec", SYMPREC))
        else:
            # No DOS in this folder. Ranking the units from the BAND
            # projections instead was tried and rejected: measured on a folder
            # that has both, the band-derived ranking calls diamond silicon
            # "Si-d" where the DOS calls it "Si-p". Substituting a measure that
            # disagrees with the one it replaces would be this tool deciding
            # the physics, so it refuses and says what to do instead.
            raise ValueError(
                "--auto-projections ranks the projection groups by their "
                "weight in the energy window, and this folder has no DOS to "
                "rank them by (KPOINTS is line-mode; there is no DOSCAR or "
                "<dos> block).\n"
                "Either name the groups explicitly with --projections, or run "
                "the plotter in a folder that also holds the DOS run.")
        if not chosen:
            raise ValueError(
                "auto-projection selection found no projected weight in the "
                f"window [{cfg.emin:g}, {cfg.emax:g}] eV. Check LORBIT and the "
                "energy bounds.")
        spec = units_to_projection_string(chosen)
        if cfg.verbose:
            print(f"      auto-projections: top {n_needed} unit(s) over "
                  f"[{cfg.emin:g}, {cfg.emax:g}] eV by window contribution "
                  f"(level: {level})")
            for line in contribution_table(ranking):
                print("    " + line)
            print(f"      -> --projections \"{spec}\"")
        # A method that needs EXACTLY k groups has to refuse when the system
        # cannot supply k, the same way it refuses without --auto-projections.
        # Warning and carrying on is how a two-colour figure of one physical
        # quantity got drawn: the shortfall is a fact about the CELL, and no
        # amount of ranking invents a distinction that is not there.
        if len(chosen) < n_needed:
            _names = ", ".join(u["token"] for u in chosen) or "none"
            if method in ("cmyk", "duo", "one_orbital"):
                raise ValueError(
                    f"--method {method} needs exactly {n_needed} projection "
                    f"group(s), but this cell offers only {len(chosen)} "
                    f"({_names}). Atoms that symmetry makes equivalent are one "
                    f"group, not several. Give {n_needed} groups explicitly with "
                    f'--projections, or use --method stacked (any number) or '
                    f"--method one_orbital (exactly 1). Run --list to see what "
                    f"this cell offers.")
            warnings.warn(
                f"auto-projections wanted {n_needed} unit(s) but this cell "
                f"offers {len(chosen)} ({_names}); {method} will draw "
                f"{len(chosen)}.")

    if spec:
        groups = parse_projection_spec(spec, structure, n_orb, grouping)
        if n_orb and bands_data is not None:
            for g in groups:
                if (_group_raw_weight(g, bands_data) or 0.0) <= 1e-8:
                    el, orb = g["plain"].split("-")[0], g["plain"].split("-", 1)[-1]
                    raise ValueError(
                        f'the projection group "{g["plain"]}" ({orb} on {el}) '
                        f'carries no projected weight in this calculation — check '
                        f'the orbital is in the PAW basis and LORBIT is set.')
    else:
        groups = _auto_projection_groups(structure, n_orb)
        n = len(groups)
        els = ", ".join(g["element"] for g in groups)
        if method == "one_orbital" and n != 1:
            raise ValueError(
                f"--method one_orbital draws exactly 1 group, but auto-detection "
                f"found {n} element(s) ({els}). Pass one explicitly, e.g. "
                f'--projections "({groups[0]["element"]}-d)", or use '
                f"--auto-projections 1 to pick the dominant one automatically.")
        if method == "rgb" and n > 3:
            raise ValueError(
                f"--method rgb encodes at most 3 groups, but this cell has "
                f"{n} elements ({els}). Give 3 groups explicitly, use "
                f"--auto-projections 3, or --method stacked. Run --list.")
        if method == "cmyk" and n != 4:
            raise ValueError(
                f"--method cmyk needs exactly 4 groups, but auto-detection found "
                f"{n} element(s) ({els}). Give 4 groups explicitly or use "
                f"--auto-projections 4.")
        if method == "duo" and n != 2:
            raise ValueError(
                f"--method duo needs exactly 2 groups, but auto-detection found "
                f"{n} element(s) ({els}). Pass two explicitly or use "
                f"--auto-projections 2.")
        if cfg.verbose:
            print("      No --projections / --auto-projections -> one group per "
                  "element. Run --list to choose atom+orbital groups.")
    return assign_channels(groups, method)


def resolve_layout(cfg):
    """Where the data lives and what can be plotted from it.

    Accepts BOTH the classic workflow tree (<root>/Scf, /Bands, /Dos -> one
    combined figure) and a bare calculation folder, whose kind is read off the
    INCAR/KPOINTS (see wolfpack_plot.detect) so that standing inside a DOS run
    produces DOS plots only, and inside a band run, band plots only.
    """
    root = cfg.root.expanduser().resolve()
    lay = detect_layout(root, bands_dir=BANDS_DIR, dos_dir=DOS_DIR,
                        scf_dir=SCF_DIR)
    if lay["kind"] is None:
        raise FileNotFoundError(
            f"nothing to plot in {root}: no {BANDS_DIR}/+{DOS_DIR}/ workflow tree, "
            f"and this folder is not a recognisable VASP calculation "
            f"({lay['why']}). Run the plotter inside a calculation folder or "
            f"one containing {SCF_DIR}/ {BANDS_DIR}/ {DOS_DIR}/.")

    # Physics problems that make the DATA wrong rather than the plot ugly. These
    # are printed LOUDLY and unconditionally (not gated on --verbose): VASP
    # produced the numbers without complaining and the resulting figure looks
    # entirely normal, so a quiet note would be read as "fine".
    for msg in lay.get("problems") or []:
        print("\n" + "!" * 78, file=sys.stderr)
        print("!! WRONG RECIPE -- the plot will look normal but the DATA is not",
              file=sys.stderr)
        print("!" * 78, file=sys.stderr)
        for line in textwrap.wrap(msg, 76):
            print("   " + line, file=sys.stderr)
        print("   See: https://vasp.at/wiki/index.php/"
              "Band-structure_calculation_using_meta-GGA_functionals\n",
              file=sys.stderr)
    return lay


def load_all(cfg):
    """Read VASP output and resolve projection groups from a config namespace.

    Returns (bands_data, dos_data, groups, spins, show_both, gap); bands_data or
    dos_data is None when the folder only holds one of the two.
    """
    lay = resolve_layout(cfg)
    cfg._layout = lay
    kind = lay["kind"]
    bands_dir, dos_dir, scf_dir = lay["bands"], lay["dos"], lay["scf"]
    want_bands = bands_dir is not None and kind in ("bands", "both")
    want_dos = dos_dir is not None and kind in ("dos", "both")

    if cfg.verbose:
        print(f"[0/4] Layout: {lay['layout']} -- {lay['why']}")
        print(f"      plotting: {kind}")

    # ---- Wannier90: interpolated curves, read straight from the w90 output --
    # Same dict shapes as the VASP readers, so every figure builder, projection
    # and spin path below works unchanged and the plots look identical.
    if kind == "wannier90":
        w90 = lay["w90"]
        if cfg.verbose:
            print(f"[1/4] Wannier90 output: {w90_describe(bands_dir, w90)}")
        bands_data = dos_data = None
        if w90.get("band_dat"):
            bands_data = read_w90_bands(bands_dir, w90,
                                        efermi=getattr(cfg, "efermi", None))
        if w90.get("dos_dat"):
            dos_data = read_w90_dos(dos_dir, w90,
                                    efermi=getattr(cfg, "efermi", None))
        src = bands_data if bands_data is not None else dos_data
        efermi = src["efermi"]
        if cfg.verbose:
            print(f"      E_F = {efermi:.4f} eV  ({src['efermi_source']})")
            print("      NOTE: Wannier90 energies are absolute; they are shifted "
                  "by E_F here.")
        spins, show_both = _resolve_spins_value(
            cfg.spin, len(((dos_data or {}).get("total")) or {}) > 1)
        if cfg.smear is None:
            cfg.smear = 0.0                # w90 already integrates onto its grid
        if bands_data is not None:
            auto_lo, auto_hi = auto_energy_window(bands_data)
        else:
            auto_lo, auto_hi = auto_energy_window_dos(dos_data)
        if cfg.emin is None:
            cfg.emin = auto_lo
        if cfg.emax is None:
            cfg.emax = auto_hi
        cfg._efermi = efermi
        # Wannier90 output carries no orbital projections, so every method
        # degrades to the plain backbone -- which is exactly the VASP look.
        if cfg.method != "plain" and cfg.verbose:
            print(f"      method={cfg.method} has no Wannier90 projections "
                  "available -> drawing the plain interpolated curves.")
        cfg.method = "plain"
        return bands_data, dos_data, [], spins, show_both, None

    ref_dir = bands_dir if want_bands else dos_dir
    if cfg.verbose:
        print(f"[1/4] Reading Fermi level from {scf_dir} ...")
    efermi = read_fermi(scf_dir, fallback_dir=ref_dir)
    if cfg.verbose:
        print(f"      E_F = {efermi:.4f} eV")

    bands_data = None
    spins, show_both = [Spin.up], False
    if want_bands:
        if cfg.verbose:
            print(f"[2/4] Reading band structure from {bands_dir} ...")
        bands_data = read_bands(bands_dir, efermi)
        ispin = bands_data.get("ispin", 1)
        if ispin >= 3:
            raise ValueError(
                f"ISPIN={ispin} is not supported yet — only ISPIN=1 (non "
                "spin-polarised) and ISPIN=2 (collinear spin) are implemented. "
                "Non-collinear/spinor output (4 spin components) is out of scope "
                "for this plotter.")
        spins, show_both = _resolve_spins_value(cfg.spin, bands_data["is_spin"])
        if cfg.verbose:
            print(f"      {sum(v.shape[0] for v in bands_data['bands'].values())} bands, "
                  f"{len(bands_data['distance'])} k-points, "
                  f"{len(bands_data['segments'])} path segment(s), "
                  f"ISPIN={ispin} (spin={'yes' if bands_data['is_spin'] else 'no'}), "
                  f"SOC={'yes' if bands_data['soc'] else 'no'}")

    dos_data = None
    if want_dos:
        if cfg.verbose:
            print(f"[3/4] Reading DOS from {dos_dir} ...")
        dos_data = read_dos(dos_dir, efermi)
        if bands_data is None:
            # DOS-only folder: the spin channels come from the DOS itself.
            is_spin = Spin.down in dos_data.get("total", {})
            spins, show_both = _resolve_spins_value(cfg.spin, is_spin)

    if getattr(cfg, "smear", None) is None:
        sigma, ismear, nedos, src = resolve_dos_smearing(
            [d for d in (dos_dir, scf_dir, bands_dir) if d is not None])
        cfg.smear = sigma
        if cfg.verbose:
            if src is not None:
                how = ("tetrahedron (ISMEAR=%d)" % ismear if (ismear is not None and ismear <= -4)
                       else "ISMEAR=%s" % ismear)
                grid = f", NEDOS={nedos}" if nedos else ""
                if sigma > 0:
                    print(f"      DOS: extra Gaussian {sigma:g} eV ({how}{grid}, from {src})")
                else:
                    print(f"      DOS: using VASP grid as-is, no extra smearing "
                          f"[{how}{grid}] (from {src})")
            else:
                print(f"      DOS: no INCAR found; applying light Gaussian "
                      f"{sigma:g} eV for smoothness")
                warnings.warn("No INCAR in Dos/Scf/Bands; applying a light "
                              f"default DOS Gaussian ({sigma:g} eV).")

    if bands_data is not None:
        auto_lo, auto_hi = auto_energy_window(bands_data)
    else:                                    # DOS-only: frame the non-zero DOS
        auto_lo, auto_hi = auto_energy_window_dos(dos_data)
    if cfg.emin is None:
        cfg.emin = auto_lo
    if cfg.emax is None:
        cfg.emax = auto_hi
    if cfg.verbose:
        tag = "auto" if (EMIN is None and EMAX is None) else "auto/override"
        print(f"      energy window: [{cfg.emin:g}, {cfg.emax:g}] eV "
              f"({tag}; use --emin/--emax to change)")

    src_data = bands_data if bands_data is not None else dos_data
    structure, n_orb = src_data["structure"], src_data["n_orb"]
    if structure is None:
        raise ValueError("could not read the structure (no vasprun.xml with "
                         "projections?) -- cannot resolve projection groups.")

    grouping = _site_grouping(structure, getattr(cfg, "group", GROUP_MODE),
                              getattr(cfg, "symprec", SYMPREC))
    if cfg.verbose:
        ginfo = grouping["info"]
        if grouping["mode"] == "symmetry":
            print(f"      site grouping: symmetry, space group "
                  f"{ginfo.get('spacegroup', '?')} (#{ginfo.get('number', '?')}), "
                  f"symprec={getattr(cfg, 'symprec', SYMPREC)} A")
            per = ", ".join(f"{el}:{n}" for el, n in grouping["n_sites"].items())
            print(f"      inequivalent sites per element: {per}")
        else:
            print(f"      site grouping: {grouping['mode']}")
        for w in ginfo.get("warnings", []):
            print(f"      WARNING: {w}")

    groups = _resolve_groups(cfg, bands_data, dos_data, structure, n_orb,
                             grouping, efermi)
    if cfg.verbose:
        if cfg.method == "plain":
            print("      method=plain; no projections (backbone + k-point dots).")
        else:
            mapping = " | ".join(
                f"{g.get('channel_name', '#%d' % (g.get('channel', 0) + 1))}: {g['plain']}"
                for g in groups)
            print(f"      method={cfg.method}; channels -> {mapping}")

    # Band-edge analysis needs eigenvalues along a path; a DOS-only folder has none.
    gap = analyze_band_gap(bands_data) if bands_data is not None else None
    cfg._efermi = efermi                             # stash for the report
    if cfg.verbose and gap is not None:
        if gap.get("metal"):
            print("      band gap: metallic (bands cross E_F)")
        else:
            kind_lbl = "direct" if gap["direct"] else "indirect"
            print(f"      band gap: {gap['gap']:.4f} eV ({kind_lbl}, "
                  f"{classify_material(gap)})")
    return bands_data, dos_data, groups, spins, show_both, gap


def _render(cfg, bands_data, dos_data, groups, job_spins, note, overlay, gap):
    """Draw the figure that matches what the folder actually contains.

    bands + DOS -> the combined figure (unchanged);
    bands only  -> a standalone band structure;
    DOS only    -> a standalone density of states.
    """
    if bands_data is not None and dos_data is not None:
        return build_figure(bands_data, dos_data, groups, cfg, job_spins,
                            show_both=overlay, gap=gap, spin_note=note,
                            overlay_plain=overlay)
    if bands_data is not None:
        return build_bands_figure(bands_data, groups, cfg, job_spins, gap=gap,
                                  spin_note=note, overlay_plain=overlay)
    return build_dos_figure(dos_data, groups, cfg, job_spins,
                            show_both=overlay, spin_note=note,
                            structure=dos_data.get("structure"))


def generate(root=".", *, return_axes=False, return_data=False, **kwargs):
    """Build the figure and return it (for use from another script)."""
    cfg = _make_cfg(root=root, **kwargs)
    bands_data, dos_data, groups, spins, show_both, gap = load_all(cfg)
    job_spins, _suffix, note, overlay = _spin_jobs(cfg, bands_data, spins,
                                                   show_both)[0]
    fig, axes = _render(cfg, bands_data, dos_data, groups, job_spins, note,
                        overlay, gap)
    result = [fig]
    if return_axes:
        result.append(axes)
    if return_data:
        result.append(dict(bands=bands_data, dos=dos_data, groups=groups))
    return fig if len(result) == 1 else tuple(result)


# --------------------------------------------------------------------------- #
# Discovery (--list)
# --------------------------------------------------------------------------- #
def list_structure(bands_dir: Path, group_mode=GROUP_MODE, symprec=SYMPREC):
    """Print species, site grouping, atom tokens and orbitals for --list."""
    vr = BSVasprun(str(bands_dir / "vasprun.xml"), parse_projected_eigen=True)
    bs = vr.get_band_structure(kpoints_filename=str(bands_dir / "KPOINTS"),
                               line_mode=True, efermi="smart")
    st = bs.structure
    n_orb = next(iter(bs.projections.values())).shape[2] if bs.projections else 0
    labels = _assign_labels(bs, bands_dir / "KPOINTS")
    path_labels = []
    for l in labels:
        if l and (not path_labels or path_labels[-1] != l):
            path_labels.append(l)

    red_formula, z = _reduced_formula(st)
    counts = _species_counts(st)
    grouping = _site_grouping(st, group_mode, symprec)
    site_label = grouping["labels"]
    info = grouping["info"]
    wyk = info.get("wyckoff", {})

    print(f"\nFormula unit   : {red_formula}   (cell {st.composition.formula}, "
          f"Z = {z} formula unit{'s' if z != 1 else ''})")
    print(f"Atoms          : {len(st)}")
    print(f"Spin polarised : {bs.is_spin_polarized}")
    if grouping["mode"] == "symmetry":
        print(f"Space group    : {info.get('spacegroup', '?')} "
              f"(#{info.get('number', '?')}), symprec = {symprec} A")
    print(f"Site grouping  : {grouping['mode']}"
          + (f"  (requested {group_mode}, fell back)" if grouping["mode"] != group_mode else ""))
    print(f"Orbital cols   : {n_orb}  "
          f"({'lm-resolved (LORBIT=11)' if n_orb >= 9 else 'spd-summed' if n_orb else 'none'})")
    avail = "s p d" + (" f" if n_orb >= 16 else "")
    print(f"Orbital tokens : {avail}"
          + ("  + lm: px,py,pz,dxy,dyz,dz2,dxz,dx2,..." if n_orb >= 9 else ""))
    if path_labels:
        print("k-path         : "
              + " - ".join(format_kpt_label(l).replace("$", "") for l in path_labels))

    if grouping["mode"] == "symmetry":
        desc = "each numbered token = one symmetry-inequivalent site (Wyckoff orbit)"
    elif grouping["mode"] == "formula":
        desc = (f"each numbered token = a block of Z={z} consecutive atoms "
                f"(POSCAR order)")
    else:
        desc = "each numbered token = a single atom (POSCAR index)"
    print(f"\nProjection grouping ({desc}):")
    has_wy = grouping["mode"] == "symmetry" and any(wyk.values())
    header = "  POSCAR  elem  token  " + ("wyck  " if has_wy else "") + "frac coords"
    print(header)
    for i, site in enumerate(st):
        el = site.specie.symbol
        a, b, c = site.frac_coords
        tok = site_label[i]
        wcol = (f"{(wyk.get(tok) or '-'):<4}  " if has_wy else "")
        print(f"  {i:>4}   {el:<4}  {tok:<5} {wcol}{a:7.4f} {b:7.4f} {c:7.4f}")

    tokens = []
    for el in counts:
        ns = grouping["n_sites"].get(el, 0)
        tokens.append(el)
        tokens += [f"{el}{k}" for k in range(1, ns + 1)] if ns > 1 else []
    print("\nValid atom tokens :", ", ".join(tokens))
    print("  (bare element = all its atoms; e.g. "
          + ", ".join(f"{el} = all {c}" for el, c in counts.items()) + ")")
    print('Example           : --projections "'
          + ",".join(f"({el}-d)" for el in counts) + '"')
    multi = [el for el in counts if grouping["n_sites"].get(el, 0) > 1]
    if multi:
        el = multi[0]
        per = ",".join(f"({el}{k}-p)" for k in range(1, grouping["n_sites"][el] + 1))
        print(f'  per-site example  : --projections "{per}"')

    note = info.get("note")
    if note:
        print(f"\nNote: {note}")
    for w in info.get("warnings", []):
        print(f"WARNING: {w}")

    if grouping["mode"] == "symmetry" and z > 1:
        formula_g = _site_grouping(st, "formula", symprec)
        if _partition(grouping["labels"]) != _partition(formula_g["labels"]):
            print("\nNote: the symmetry grouping differs from naive POSCAR "
                  "Z-blocks — the crystallographic result above is used. Pass "
                  "--group formula to force consecutive blocks instead.")
    print()


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def parse_args(argv=None):
    """Parse the vasp-plot-fatbandsdos command-line arguments."""
    p = argparse.ArgumentParser(
        prog="vasp-plot-fatbandsdos",
        description="Publication-ready fat-band + DOS plot from a VASP folder.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Examples:\n'
            '  vasp-plot-fatbandsdos --root . --list\n'
            '  vasp-plot-fatbandsdos --root . --method plain\n'
            '  vasp-plot-fatbandsdos --root . --method one_orbital \\\n'
            '      --auto-projections 1 --emin -3 --emax 3\n'
            '  vasp-plot-fatbandsdos --root . --method rgb \\\n'
            '      --projections "(Cu-d),(V-d),(S-p)" --title "MoS_2"\n'))
    p.add_argument("--root", default=".", type=Path,
                   help="Calculation root with Scf/ Bands/ Dos/ (default: .)")
    p.add_argument("--list", action="store_true",
                   help="Print species, per-element atom tokens and orbitals, then exit.")
    p.add_argument("--method", required=True,
                   help="REQUIRED method: plain | one_orbital | duo | rgb | cmyk "
                        "| stacked. 'plain': no projection (pale backbone + black "
                        "k-point dots). 'one_orbital': 1 group -> pure-blue "
                        "circles (opacity=weight). 'duo': 2 groups -> two-colour "
                        "gradient. 'rgb': up to 3 -> red/green/blue. 'cmyk': "
                        "exactly 4 -> CMYK colour mix. 'stacked': any number, "
                        "sumo circles (area ~ weight).")
    p.add_argument("--projections", default=None,
                   help="Projection groups, e.g. \"(Cu-d),(V-d),(S-p)\". "
                        "one_orbital: 1; duo: 2; rgb: 1-3; cmyk: 4; stacked: any.")
    p.add_argument("--subdir", default=None,
                   help="Optional sub-folder under <root>/Plots/ to write into "
                        "(used by vasp-quick-plots to group outputs).")
    p.add_argument("--no-overlay-plain", dest="overlay_plain",
                   action="store_false",
                   help="For ISPIN=2 --spin both, do NOT also write the overlaid "
                        "blue/orange plain plot (it is written by default).")
    p.add_argument("--auto-projections", dest="auto_projections", type=int,
                   default=0, metavar="N",
                   help="Instead of --projections, auto-pick the N most-"
                        "contributing (element, dominant-l) units over the "
                        "energy window (falls back to inequivalent Wyckoff sites "
                        "if there are too few elements). For fixed-count methods "
                        "(one_orbital/duo/rgb) N is taken from the method.")
    p.add_argument("--name", default=DEFAULT_OUT_NAME,
                   help=f"Base filename written under <root>/{OUT_DIR}/ "
                        f"(default: {DEFAULT_OUT_NAME}).")
    p.add_argument("--spin", choices=["both", "up", "down"], default="both",
                   help="Spin channel(s) to plot for ISPIN=2 (default: both). "
                        "Ignored for ISPIN=1 (a single channel is plotted).")
    p.add_argument("--title", default=None,
                   help='Title in TeX-ish form, e.g. "MoS_2 - G_0W_0".')
    p.add_argument("--no-title", dest="show_title", action="store_false")
    p.add_argument("--group", choices=["symmetry", "formula", "element"],
                   default=GROUP_MODE,
                   help=f"How numbered tokens (S1,S2,...) map to atoms (default "
                        f"{GROUP_MODE}).")
    p.add_argument("--symprec", type=float, default=SYMPREC,
                   help=f"spglib symmetry tolerance (A) for --group symmetry "
                        f"(default {SYMPREC}).")
    p.add_argument("--markers", type=int, default=MARKER_TARGET,
                   help="(rgb/duo/one_orbital) circles along the k-path: 0 "
                        "(default) one per k-point; positive subsamples.")
    p.add_argument("--marker-size", dest="marker_size", type=float,
                   default=MARKER_SIZE,
                   help=f"(rgb/duo/one_orbital) fixed circle area pt^2 (default "
                        f"{MARKER_SIZE}); weight shown by opacity.")
    p.add_argument("--plain-marker-size", dest="plain_marker_size", type=float,
                   default=PLAIN_MARKER_SIZE,
                   help=f"(plain) black k-point circle area pt^2 (default "
                        f"{PLAIN_MARKER_SIZE}).")
    p.add_argument("--alpha-min", dest="alpha_min", type=float, default=ALPHA_MIN,
                   help=f"(rgb/duo/one_orbital) opacity at weight 0 (default {ALPHA_MIN}).")
    p.add_argument("--alpha-max", dest="alpha_max", type=float, default=ALPHA_MAX,
                   help=f"(rgb/duo/one_orbital) opacity at weight 1 (default {ALPHA_MAX}).")
    p.add_argument("--circle-size", dest="circle_size", type=float,
                   default=STACKED_CIRCLE_SIZE,
                   help=f"(stacked) circle area scale (default {STACKED_CIRCLE_SIZE:g}).")
    p.add_argument("--emin", type=float, default=None,
                   help="Lower energy bound (eV, rel. E_F); default auto-fit. "
                        "Also bounds --auto-projections selection.")
    p.add_argument("--emax", type=float, default=None,
                   help="Upper energy bound (eV, rel. E_F); default auto-fit. "
                        "Also bounds --auto-projections selection.")
    p.add_argument("--efermi", type=float, default=None,
                   help="Fermi level in eV. Only needed for Wannier90 output, "
                        "whose energies are absolute: normally taken from "
                        "fermi_energy in the .win file, else from the VASP run "
                        "in this or the parent folder.")
    p.add_argument("--pickle", action="store_true",
                   help="Also write the figure as a .fig.pkl for later editing.")
    p.add_argument("--dpi", type=int, default=DPI)
    p.add_argument("--figw", type=float, default=FIG_W)
    p.add_argument("--figh", type=float, default=FIG_H)
    p.add_argument("--font", default=FONT_FAMILY, choices=["sans-serif", "serif"])
    p.add_argument("--formats", default=",".join(OUT_FORMATS),
                   help="Comma-separated output formats (e.g. png,pdf,svg).")
    p.set_defaults(show_title=SHOW_TITLE, smear=None)
    args = p.parse_args(argv)
    args.method = normalize_method(args.method)
    if args.method not in METHODS:
        p.error(f"--method must be one of {', '.join(METHODS)} "
                f"(got {args.method!r}).")
    return args


def main(argv=None):
    """CLI entry point: read a VASP folder and render the requested figure(s)."""
    cfg = parse_args(argv)
    cfg.verbose = True

    root = cfg.root.expanduser().resolve()
    try:
        lay = resolve_layout(cfg)
    except FileNotFoundError as exc:
        sys.exit(f"ERROR: {exc}")

    if cfg.list:
        src = lay["bands"] or lay["dos"]
        list_structure(src, group_mode=cfg.group, symprec=cfg.symprec)
        return

    try:
        bands_data, dos_data, groups, spins, show_both, gap = load_all(cfg)
    except (ValueError, FileNotFoundError, RuntimeError) as exc:
        sys.exit(f"ERROR: {exc}")

    out_dir = root / OUT_DIR
    if getattr(cfg, "subdir", None):
        out_dir = out_dir / cfg.subdir
    out_dir.mkdir(parents=True, exist_ok=True)
    name = cfg.name or DEFAULT_OUT_NAME
    formats = [f.strip().lower() for f in cfg.formats.split(",") if f.strip()]
    import matplotlib.pyplot as plt

    # --spin both renders the spin-up plot, the spin-down plot, and (unless
    # disabled) the overlaid blue/orange plain plot; ISPIN=1 / single-spin
    # selections render one figure.
    jobs = _spin_jobs(cfg, bands_data, spins, show_both)

    written = []
    for job_spins, suffix, note, overlay in jobs:
        base = f"{name}_{suffix}" if suffix else name
        what = "overlay plain" if overlay else cfg.method
        panels = (f"{len(bands_data['segments'])} k-path panel(s)"
                  if bands_data is not None else "DOS only")
        print(f"[4/4] Rendering {lay['kind']} figure (method={what}, "
              f"{0 if overlay else len(groups)} group(s), "
              f"spin={suffix or cfg.spin}, {panels}) -> {base} ...")
        fig, _axes = _render(cfg, bands_data, dos_data, groups, job_spins,
                             note, overlay, gap)
        for fmt in formats:
            path = out_dir / f"{base}.{fmt}"
            fig.savefig(path, dpi=cfg.dpi, bbox_inches="tight")
            written.append(path)
        if cfg.pickle:
            pk = out_dir / f"{base}.fig.pkl"
            with open(pk, "wb") as fh:
                pickle.dump(fig, fh)
            written.append(pk)
        plt.close(fig)

    try:
        rep = write_report(out_dir / f"{name}.analysis_report.txt", root, cfg,
                           bands_data, dos_data, groups,
                           getattr(cfg, "_efermi", float("nan")), gap)
        written.append(rep)
    except Exception as exc:                          # noqa: BLE001
        print(f"  (warning: could not write analysis report: {exc})")

    print("Done. Wrote:")
    for pth in written:
        print(f"  {pth}")
