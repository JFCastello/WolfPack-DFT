"""
wolfpack_plot.physics
====================
Derived physical quantities:

  * projected band weights and projected DOS for the drawing layer;
  * the **window-contribution ranking** used by ``--auto-projections`` to pick
    the most-important (element, orbital) units over an energy window, with a
    robust element -> inequivalent-Wyckoff-site -> per-atom fallback;
  * band-gap / VBM-CBM analysis, magnetism, and the text analysis report.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from pymatgen.electronic_structure.core import Orbital
from pymatgen.io.vasp.outputs import Outcar, Vasprun

from .config import BANDS_DIR, DOS_DIR, SCF_DIR
from .formatting import (_GROUP_TOKENS, _GROUP_TYPE, _plain_klabel,
                         _resolve_band_columns, format_kpt_label)
from .structure import _site_grouping, _species_counts, _species_sites
from .vaspio import _parse_incar_tag, resolve_dos_smearing


# --------------------------------------------------------------------------- #
# Weights & projected DOS (band markers)
# --------------------------------------------------------------------------- #
def _group_raw_weight(group, bands_data):
    """Total raw projected weight of a group over all bands/k-points (0 if none)."""
    proj = bands_data["projections"]
    if not proj:
        return None
    cols = _resolve_band_columns(group["orbitals"], bands_data["n_orb"])
    if not cols or not group["sites"]:
        return 0.0
    tot = 0.0
    for arr in proj.values():
        tot += float(arr[:, :, cols, :][:, :, :, group["sites"]].sum())
    return tot


def band_weights(group, bands_data):
    """weight[spin] : (nbands, nk) = RAW projected magnitude of this group."""
    proj = bands_data["projections"]
    if not proj:
        return None
    cols = _resolve_band_columns(group["orbitals"], bands_data["n_orb"])
    sites = group["sites"]
    if not cols or not sites:
        return None
    return {sp: arr[:, :, cols, :][:, :, :, sites].sum(axis=(2, 3))
            for sp, arr in proj.items()}


def state_total_weight(bands_data):
    """total[spin] : (nbands, nk) = projection summed over ALL orbitals & atoms."""
    proj = bands_data["projections"]
    if not proj:
        return None
    return {sp: arr.sum(axis=(2, 3)) for sp, arr in proj.items()}


def dos_projection(group, dos_data):
    """Projected DOS for a group: {spin: density over the energy grid} or None."""
    cdos = dos_data["cdos"]
    structure = cdos.structure
    tokens = group["orbitals"]
    nE = len(dos_data["energies"])
    acc = {}

    def _add(spin_dict):
        for sp, dens in spin_dict.items():
            d = np.asarray(dens, dtype=float)
            if d.shape[0] == nE:
                acc[sp] = acc.get(sp, np.zeros(nE)) + d

    for i in group["sites"]:
        site = structure[i]
        spd = None
        for tok in tokens:
            try:
                if tok in _GROUP_TOKENS:
                    if spd is None:
                        spd = cdos.get_site_spd_dos(site)
                    dos = spd.get(_GROUP_TYPE[tok])
                    if dos is not None:
                        _add(dos.densities)
                else:
                    _add(cdos.get_site_orbital_dos(site, Orbital[tok]).densities)
            except (KeyError, ValueError):
                continue
    return acc or None


def _smear(energies, dens, sigma):
    """Apply an extra Gaussian broadening (sigma eV) to a DOS array."""
    if not sigma or sigma <= 0:
        return dens
    de = float(np.mean(np.diff(energies)))
    if de <= 0:
        return dens
    n = max(1, int(round(6 * sigma / de)))
    x = np.arange(-n, n + 1) * de
    k = np.exp(-0.5 * (x / sigma) ** 2)
    k /= k.sum()
    return np.convolve(dens, k, mode="same")


# --------------------------------------------------------------------------- #
# Window-contribution ranking (auto projection selection)
# --------------------------------------------------------------------------- #
# These functions answer: "over the energy window [emin, emax], which
# (element, l) characters carry the most weight?"  The measure is the projected
# DOS integrated over the window (a proper density-of-states integral, summed
# over spin channels) -- far more representative of the whole Brillouin zone
# than band-path projections, and therefore the number you can trust for ranking.

_L_TOKENS = ("s", "p", "d", "f")

# Trapezoidal integrator that works on both NumPy 2.x (np.trapezoid) and the
# older np.trapz (removed in NumPy 2.0).
try:                                       # numpy >= 2.0
    _trapz = np.trapezoid                  # type: ignore[attr-defined]
except AttributeError:                     # numpy < 2.0
    _trapz = np.trapz                      # type: ignore[attr-defined]


def _window_mask(cdos, efermi, emin, emax):
    """Boolean mask of DOS grid points inside [emin, emax] (E_F-referenced)."""
    E = np.asarray(cdos.energies, dtype=float) - float(efermi)
    lo, hi = (emin, emax) if emin <= emax else (emax, emin)
    return E, (E >= lo) & (E <= hi)


def _integrate_window(densities_by_spin, E, mask):
    """Trapezoidal integral of a {Spin: density} dict over the window, summed
    over spins. Returns a non-negative float (states-of-this-character)."""
    if not mask.any():
        return 0.0
    tot = 0.0
    for dens in densities_by_spin.values():
        d = np.asarray(dens, dtype=float)
        if d.shape[0] != E.shape[0]:
            continue
        tot += float(_trapz(np.clip(d[mask], 0.0, None), E[mask]))
    return tot


def _sites_l_contributions(cdos, site_indices, E, mask):
    """{l_token -> integrated weight} summed over the given site indices.

    Uses the same per-site spd DOS that the band markers project, so the ranking
    is consistent with what ends up being drawn. Sites/orbitals that the run did
    not store are silently skipped (robust to LORBIT=10 and missing f).
    """
    structure = cdos.structure
    out = {l: 0.0 for l in _L_TOKENS}
    for i in site_indices:
        try:
            spd = cdos.get_site_spd_dos(structure[i])    # {OrbitalType: Dos}
        except (KeyError, ValueError, AttributeError):
            continue
        for otype, dos in spd.items():
            ltok = getattr(otype, "name", str(otype)).lower()
            if ltok not in out:
                continue
            out[ltok] += _integrate_window(dos.densities, E, mask)
    return out


def _unit_from_contrib(token_base, l_contrib, element, level):
    """Build one ranked-unit dict from an {l: weight} contribution map."""
    total = float(sum(l_contrib.values()))
    if total <= 0.0:
        return None
    dom_l = max(_L_TOKENS, key=lambda l: l_contrib.get(l, 0.0))
    return dict(token=f"{token_base}-{dom_l}", base=token_base, dom_l=dom_l,
                weight=total, element=element, level=level,
                l_contrib=dict(l_contrib))


def rank_elements(cdos, efermi, emin, emax, structure):
    """Rank elements by total window weight; each carries its dominant l."""
    E, mask = _window_mask(cdos, efermi, emin, emax)
    units = []
    for el, idxs in _species_sites(structure).items():
        u = _unit_from_contrib(el, _sites_l_contributions(cdos, idxs, E, mask),
                               el, "element")
        if u is not None:
            units.append(u)
    units.sort(key=lambda u: -u["weight"])
    return units


def rank_sites(cdos, efermi, emin, emax, structure, grouping):
    """Rank inequivalent sites (grouping tokens El1, El2, ...) by window weight."""
    E, mask = _window_mask(cdos, efermi, emin, emax)
    units = []
    for tok, idxs in grouping["order"].items():
        if not idxs:
            continue
        el = structure[idxs[0]].specie.symbol
        u = _unit_from_contrib(tok, _sites_l_contributions(cdos, idxs, E, mask),
                               el, "site")
        if u is not None:
            units.append(u)
    units.sort(key=lambda u: -u["weight"])
    return units


def auto_select_units(cdos, efermi, emin, emax, structure, grouping, n_needed,
                      symprec=None):
    """Pick the ``n_needed`` most-contributing (element|site, dominant-l) units
    over the energy window.

    Strategy (matching the requested behaviour):
      1. rank ELEMENTS by window weight; if there are >= n_needed distinct
         elements, take the top n_needed (e.g. Cu-d, S-p, ...);
      2. otherwise switch to inequivalent WYCKOFF SITES of the active grouping
         (e.g. Pt1-d, Pt2-d), ranked by window weight, and take the top n_needed;
      3. if even that is not enough, fall back to per-atom units.
    The chosen order always respects the descending window contribution.

    Returns (chosen_units, level_used, full_ranking_used).  Raises ValueError if
    no projected weight is found at all (e.g. LORBIT unset).
    """
    if n_needed <= 0:
        return [], "none", []

    el_rank = rank_elements(cdos, efermi, emin, emax, structure)
    if not el_rank and not grouping["order"]:
        raise ValueError(
            "no projected DOS weight found in the energy window — was LORBIT "
            "set (>=10) for the DOS run, and is [emin, emax] non-empty?")
    if len(el_rank) >= n_needed:
        return el_rank[:n_needed], "element", el_rank

    # --- fallback 1: inequivalent Wyckoff sites of the active grouping ---
    site_rank = rank_sites(cdos, efermi, emin, emax, structure, grouping)
    if len(site_rank) >= n_needed:
        return site_rank[:n_needed], "site", site_rank

    # --- fallback 2: per-atom units (element grouping) ---
    atom_grouping = _site_grouping(structure, "element")
    atom_rank = rank_sites(cdos, efermi, emin, emax, structure, atom_grouping)
    if atom_rank:
        level = "atom" if len(atom_rank) >= len(site_rank) else "site"
        best = atom_rank if len(atom_rank) >= len(site_rank) else site_rank
        return best[:n_needed], level, best

    # nothing better than the element ranking we have
    return el_rank[:n_needed], "element", el_rank


def units_to_projection_string(units):
    """['Cu-d', ...] unit dicts -> '(Cu-d),(S-p)' for --projections."""
    return ",".join(f"({u['token']})" for u in units)


def contribution_table(ranking, top=8, total_norm=True):
    """Compact human-readable lines describing a window-contribution ranking."""
    if not ranking:
        return ["  (no projected weight found in the window)"]
    tot = sum(u["weight"] for u in ranking) or 1.0
    lines = []
    for u in ranking[:top]:
        frac = 100.0 * u["weight"] / tot if total_norm else u["weight"]
        per_l = " ".join(f"{l}:{u['l_contrib'].get(l, 0.0):.3g}" for l in _L_TOKENS
                         if u["l_contrib"].get(l, 0.0) > 0)
        lines.append(f"  {u['token']:<10} {frac:5.1f}%  ({u['level']}; {per_l})")
    return lines


# --------------------------------------------------------------------------- #
# Band gap / VBM-CBM
# --------------------------------------------------------------------------- #
def analyze_band_gap(bands_data, tol=1e-4):
    """Find the fundamental gap from the E_F-referenced band eigenvalues."""
    dist = bands_data["distance"]
    labels = bands_data["kpoint_labels"]
    vbm_e, vbm_k, vbm_sp = -np.inf, None, None
    cbm_e, cbm_k, cbm_sp = np.inf, None, None
    crosses_ef = False
    for sp, arr in bands_data["bands"].items():        # arr: (nbands, nk)
        for band in arr:
            if band.min() < -tol and band.max() > tol:
                crosses_ef = True                       # a band crosses E_F -> metal
        occ_mask = arr <= tol
        if occ_mask.any():
            flat = np.where(occ_mask, arr, -np.inf)
            bi, ki = np.unravel_index(np.argmax(flat), flat.shape)
            if flat[bi, ki] > vbm_e:
                vbm_e, vbm_k, vbm_sp = float(flat[bi, ki]), int(ki), sp
        uno_mask = arr > tol
        if uno_mask.any():
            flat = np.where(uno_mask, arr, np.inf)
            bi, ki = np.unravel_index(np.argmin(flat), flat.shape)
            if flat[bi, ki] < cbm_e:
                cbm_e, cbm_k, cbm_sp = float(flat[bi, ki]), int(ki), sp

    if crosses_ef or vbm_k is None or cbm_k is None or (cbm_e - vbm_e) <= tol:
        return {"metal": True}

    def _klabel(ki):
        lab = labels[ki] if 0 <= ki < len(labels) else None
        return format_kpt_label(lab) if lab else None

    kfrac = bands_data.get("kpoints_frac")

    def _kcoord(ki):
        if kfrac is None or not (0 <= ki < len(kfrac)):
            return None
        return tuple(float(x) for x in kfrac[ki])

    return {
        "metal": False,
        "gap": cbm_e - vbm_e,
        "vbm": vbm_e, "cbm": cbm_e,
        "vbm_k_dist": float(dist[vbm_k]), "cbm_k_dist": float(dist[cbm_k]),
        "vbm_k_idx": vbm_k, "cbm_k_idx": cbm_k,
        "vbm_klabel": _klabel(vbm_k), "cbm_klabel": _klabel(cbm_k),
        "vbm_kpt": _kcoord(vbm_k), "cbm_kpt": _kcoord(cbm_k),
        "vbm_spin": vbm_sp, "cbm_spin": cbm_sp,
        "direct": vbm_k == cbm_k,
    }


def classify_material(gap):
    """Crude label from the fundamental gap (eV)."""
    if gap.get("metal"):
        return "metal"
    eg = gap["gap"]
    if eg < 0.05:
        return "semimetal / zero-gap"
    return "semiconductor" if eg < 3.0 else "insulator"


def analyze_magnetism(scf_dir, dos_dir):
    """Total magnetic moment (mu_B) from OUTCAR/vasprun, if spin-polarised."""
    for d in (scf_dir, dos_dir):
        vxml = Path(d) / "vasprun.xml"
        if not vxml.is_file():
            continue
        try:
            vr = Vasprun(str(vxml), parse_dos=False, parse_eigen=False,
                         parse_projected_eigen=False, parse_potcar_file=False)
        except Exception:                              # noqa: BLE001
            continue
        if int(vr.parameters.get("ISPIN", 1)) != 2:
            return {"is_spin": False}
        mag = None
        try:                                           # per-atom moments -> sum
            outcar = Path(d) / "OUTCAR"
            if outcar.is_file():
                oc = Outcar(str(outcar))
                if oc.magnetization:
                    mag = sum(a.get("tot", 0.0) for a in oc.magnetization)
        except Exception:                              # noqa: BLE001
            mag = None
        return {"is_spin": True, "total_moment": mag}
    return {"is_spin": False}


# --------------------------------------------------------------------------- #
# Text report
# --------------------------------------------------------------------------- #
def _fmt(x, unit="", nd=4):
    return "n/a" if x is None else f"{x:.{nd}f}{unit}"


def _section(title):
    bar = "=" * 78
    return f"\n{bar}\n  {title}\n{bar}\n"


def collect_report(root, cfg, bands_data, dos_data, groups, efermi, gap):
    """Gather physical quantities from the calculation as a single text string."""
    root = Path(root)
    scf_dir, bands_dir, dos_dir = root / SCF_DIR, root / BANDS_DIR, root / DOS_DIR
    # A single-calculation folder has no Scf/Bands/Dos sub-tree, and a DOS-only
    # folder has no band data: fall back to the folder itself / the DOS structure.
    if not scf_dir.is_dir():
        scf_dir = root
    if not dos_dir.is_dir():
        dos_dir = root
    st = (bands_data["structure"] if bands_data is not None
          else dos_data.get("structure"))
    if st is None:
        # Wannier90 output with no POSCAR/vasprun nearby: skip the structural
        # section entirely rather than fail the whole report.
        import datetime as _dt0
        return ("VASP fat-band / DOS analysis report\n"
                f"generated  : {_dt0.datetime.now():%Y-%m-%d %H:%M:%S}\n"
                f"root        : {root}\n\n"
                "(no structure available -- Wannier90 output without a VASP "
                "run alongside; nothing further to report)\n")
    lat = st.lattice
    import datetime as _dt
    L = []
    L.append("VASP fat-band / DOS analysis report")
    L.append(f"generated  : {_dt.datetime.now():%Y-%m-%d %H:%M:%S}")
    L.append(f"root        : {root}")

    # --- structure ---
    L.append(_section("STRUCTURE"))
    comp = st.composition
    L.append(f"formula (reduced)  : {comp.reduced_formula}")
    L.append(f"formula (full cell): {comp.formula}")
    L.append(f"atoms in cell      : {len(st)}")
    L.append(f"density            : {_fmt(st.density, ' g/cm^3', 3)}")
    L.append(f"cell volume        : {_fmt(lat.volume, ' A^3', 3)}")
    L.append(f"lattice a, b, c    : {lat.a:.4f}, {lat.b:.4f}, {lat.c:.4f}  A")
    L.append(f"angles alpha,beta,gamma: {lat.alpha:.3f}, {lat.beta:.3f}, "
             f"{lat.gamma:.3f}  deg")
    try:
        from pymatgen.symmetry.analyzer import SpacegroupAnalyzer
        sga = SpacegroupAnalyzer(st, symprec=cfg.symprec)
        L.append(f"space group        : {sga.get_space_group_symbol()} "
                 f"(#{sga.get_space_group_number()})")
        L.append(f"crystal system     : {sga.get_crystal_system()}")
        L.append(f"point group        : {sga.get_point_group_symbol()}")
    except Exception:                                  # noqa: BLE001
        L.append("space group        : (symmetry analysis failed)")
    counts = _species_counts(st)
    L.append("species counts     : "
             + ", ".join(f"{el}:{n}" for el, n in counts.items()))

    # --- electronic structure ---
    L.append(_section("ELECTRONIC STRUCTURE"))
    L.append(f"Fermi level E_F    : {_fmt(efermi, ' eV')}  (eigenvalues below "
             f"are referenced so E_F = 0)")
    if bands_data is None:
        # DOS-only folder: no eigenvalues along a path, so no band-edge analysis.
        L.append("band structure     : not in this folder (DOS-only calculation)")
        L.append("band gap           : not determined -- run the band-structure "
                 "step for VBM/CBM")
    else:
        nb = sum(v.shape[0] for v in bands_data["bands"].values())
        L.append(f"spin polarised     : {'yes' if bands_data['is_spin'] else 'no'}")
        L.append(f"spin-orbit coupling: {'yes' if bands_data['soc'] else 'no'}")
        L.append(f"bands x k-points   : {nb} x {len(bands_data['distance'])}")
    if bands_data is not None and gap is not None:
        L.append(f"material class     : {classify_material(gap).upper()}")
    if bands_data is not None and gap is not None and gap.get("metal"):
        L.append("band gap           : none (bands cross E_F -> metallic)")
    elif bands_data is not None and gap is not None:
        kind = "direct" if gap["direct"] else "indirect"
        L.append(f"fundamental gap    : {gap['gap']:.4f} eV  ({kind})")
        vk = _plain_klabel(gap["vbm_klabel"]) or f"{gap['vbm_k_dist']:.3f}"
        ck = _plain_klabel(gap["cbm_klabel"]) or f"{gap['cbm_k_dist']:.3f}"

        def _kfmt(kpt):
            return ("(%+.4f, %+.4f, %+.4f)" % kpt) if kpt else "n/a"
        L.append(f"  VBM              : {gap['vbm']:+.4f} eV  at k = {vk}")
        L.append(f"    k (frac. recip.): {_kfmt(gap.get('vbm_kpt'))}")
        L.append(f"  CBM              : {gap['cbm']:+.4f} eV  at k = {ck}")
        L.append(f"    k (frac. recip.): {_kfmt(gap.get('cbm_kpt'))}")
        if bands_data["is_spin"] and gap.get("vbm_spin") != gap.get("cbm_spin"):
            L.append("  note             : VBM and CBM are in different spin "
                     "channels (half-metal-like).")

    # --- magnetism ---
    mag = analyze_magnetism(scf_dir, dos_dir)
    if mag["is_spin"]:
        L.append(_section("MAGNETISM"))
        L.append(f"total magnetic moment: {_fmt(mag.get('total_moment'), ' mu_B', 3)}"
                 "  (sum of atom-projected moments)")

    # --- projections / fat-band setup ---
    L.append(_section("PROJECTION SETUP (fat bands)"))
    L.append(f"method             : {cfg.method}")
    if cfg.method == "plain":
        L.append("plain mode: no projections; pale-grey backbone + black "
                 "k-point markers only.")
    for g in groups:
        el, orb = g["plain"].split("-")[0], g["plain"].split("-", 1)[-1]
        chan = g.get("channel_name", f"#{g.get('channel', 0) + 1}")
        L.append(f"  {chan:5s} : {g['plain']:8s} ({el} {orb})  colour {g['color']}")
    if cfg.method == "rgb":
        L.append("colour = additive RGB f_c = w_c/(w_R+w_G+w_B); "
                 "opacity = S = (w_R+w_G+w_B)/w_tot; marker size fixed")
    elif cfg.method == "duo":
        L.append("colour = 2-colour gradient f = w_A/(w_A+w_B); "
                 "opacity = S = (w_A+w_B)/w_tot; marker size fixed")
    elif cfg.method == "one_orbital":
        L.append("colour = pure blue; opacity = S = w_group/w_tot; "
                 "marker size fixed")
    elif cfg.method == "stacked":
        L.append("sumo 'stacked': one circle per group, area = circle_size * "
                 f"w^2, w = group weight / w_tot (circle_size={cfg.circle_size:g})")

    # --- DOS grid / smearing ---
    L.append(_section("DOS / SMEARING"))
    sigma, ismear, nedos, src = resolve_dos_smearing([dos_dir, scf_dir, bands_dir])
    L.append(f"ISMEAR             : {ismear if ismear is not None else 'n/a'}"
             + ("  (tetrahedron)" if (ismear is not None and ismear <= -4) else ""))
    L.append(f"NEDOS (grid points): {nedos if nedos else 'n/a'}")
    L.append(f"applied DOS smearing: {_fmt(cfg.smear, ' eV', 3)}"
             + ("  (none; DOS already integrated)" if not cfg.smear else ""))
    L.append(f"energy window shown: [{cfg.emin:g}, {cfg.emax:g}] eV")

    # --- key INCAR tags per sub-folder ---
    L.append(_section("KEY INCAR TAGS"))
    keys = ["ENCUT", "PREC", "EDIFF", "ISMEAR", "SIGMA", "ISPIN", "GGA",
            "LDAU", "LDAUU", "LHFCALC", "NBANDS", "KPAR", "NCORE", "LORBIT"]
    for name, d in (("Scf", scf_dir), ("Bands", bands_dir), ("Dos", dos_dir)):
        inc = Path(d) / "INCAR"
        if not inc.is_file():
            L.append(f"[{name}] (no INCAR)")
            continue
        found = [(k, _parse_incar_tag(inc, k)) for k in keys]
        found = [f"{k}={v}" for k, v in found if v is not None]
        L.append(f"[{name}] " + ("; ".join(found) if found else "(none of the "
                 "tracked tags set)"))

    L.append("\n" + "=" * 78)
    L.append("Notes: gap from band eigenvalues (occupied = E<=E_F). The "
             "semiconductor/insulator split at 3 eV is conventional. Moments are "
             "atom-projected sums and depend on the PAW sphere radii.")
    return "\n".join(L) + "\n"


def write_report(path, *args, **kwargs):
    """Write the collected report (see collect_report) to `path`."""
    text = collect_report(*args, **kwargs)
    Path(path).write_text(text)
    return path
