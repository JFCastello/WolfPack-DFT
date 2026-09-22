"""
wolfpack_plot.vaspio
===================
All reading of VASP output: line-mode KPOINTS (high-symmetry labels, path
segments), the Fermi level, band structure + projections, DOS, INCAR tags, the
DOS-smearing decision and the automatic energy window.
"""
from __future__ import annotations

import re
import warnings
from pathlib import Path

import numpy as np
from pymatgen.io.vasp.outputs import BSVasprun, Outcar, Vasprun

from .config import DEFAULT_SMEAR, EMAX, EMIN


# --------------------------------------------------------------------------- #
# KPOINTS parsing & high-symmetry labels
# --------------------------------------------------------------------------- #
def _clean_kpt_comment(comment: str):
    """Extract the high-symmetry label from a KPOINTS '!' comment."""
    if not comment:
        return None
    cand = []
    for tok in comment.replace(",", " ").split():
        try:
            float(tok)                # drop pure numbers (indices, weights)
            continue
        except ValueError:
            pass
        m = re.match(r"^\d+(?=[^\d])(.*)$", tok)   # strip a glued leading index
        if m and m.group(1):
            tok = m.group(1)
        cand.append(tok)
    return cand[-1] if cand else None


def _parse_kpoints_labels(path: Path):
    """Read a line-mode KPOINTS file.

    Returns (points, reciprocal) where points is a list of
    (frac_coords ndarray, label or None) for each listed endpoint.
    """
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return [], True
    if len(lines) < 4 or not lines[2].strip().lower().startswith("l"):
        return [], True
    reciprocal = not lines[3].strip().lower().startswith("c")
    pts = []
    for ln in lines[4:]:
        s = ln.strip()
        if not s:
            continue
        label = None
        if "!" in s:
            body, comment = s.split("!", 1)
            label = _clean_kpt_comment(comment)
        else:
            body = s
        nums = body.replace(",", " ").split()
        if len(nums) < 3:
            continue
        try:
            coords = np.array([float(nums[0]), float(nums[1]), float(nums[2])])
        except ValueError:
            continue
        pts.append((coords, label))
    return pts, reciprocal


def _assign_labels(bs, kpoints_path: Path):
    """Per-k-point high-symmetry labels from the KPOINTS file (matched on
    fractional coordinates modulo a reciprocal lattice vector), else pymatgen."""
    pts, reciprocal = _parse_kpoints_labels(kpoints_path)
    label_map = [(c, l) for (c, l) in pts if l] if reciprocal else []

    def match(frac):
        for c, l in label_map:
            diff = np.asarray(frac) - c
            diff = diff - np.round(diff)             # wrap to nearest cell
            if np.all(np.abs(diff) < 2e-3):
                return l
        return None

    labels = []
    for k in bs.kpoints:
        lab = match(k.frac_coords) if label_map else None
        if not lab and k.label:
            lab = _clean_kpt_comment(k.label) or k.label
        labels.append(lab if lab else None)
    return labels


def _build_segments(distance, kpoints):
    """Index slices to plot as continuous runs, split at path discontinuities."""
    breaks = []
    for i in range(len(distance) - 1):
        if abs(distance[i + 1] - distance[i]) < 1e-8 and not np.allclose(
                kpoints[i].frac_coords, kpoints[i + 1].frac_coords, atol=1e-5):
            breaks.append(i + 1)
    bounds = [0, *breaks, len(distance)]
    return [slice(a, b) for a, b in zip(bounds[:-1], bounds[1:]) if b - a >= 1]


def _segment_ticks(distance, labels, sl):
    """High-symmetry (distance, label) pairs inside one segment slice."""
    start = sl.start or 0
    stop = sl.stop if sl.stop is not None else len(distance)
    out = []
    for i in range(start, stop):
        lab = labels[i]
        if not lab:
            continue
        d = float(distance[i])
        if out and abs(d - out[-1][0]) < 1e-8:
            prev_d, prev_l = out[-1]
            if lab not in prev_l.split("|"):
                out[-1] = (prev_d, prev_l + "|" + lab)
        else:
            out.append((d, lab))
    return out


# --------------------------------------------------------------------------- #
# Parsing VASP output
# --------------------------------------------------------------------------- #
def read_fermi(scf_dir: Path, fallback_dir=None) -> float:
    """Read the Fermi energy from the SCF run (vasprun.xml), with a fallback dir."""
    vxml = scf_dir / "vasprun.xml"
    if vxml.is_file():
        try:
            # parse_dos MUST stay on. pymatgen assigns Vasprun.efermi in ONE
            # place -- `self.efermi = self.tdos.efermi`, inside the
            # `elif parse_dos and tag == "dos"` branch of Vasprun._parse -- so
            # with parse_dos=False this attribute is always None and this whole
            # branch is dead. It went unnoticed because the OUTCAR fallback
            # below answers whenever an OUTCAR is present; a folder that has a
            # vasprun.xml and no OUTCAR could not be plotted at all.
            ef = Vasprun(str(vxml), parse_eigen=False,
                         parse_projected_eigen=False, parse_potcar_file=False).efermi
            if ef is not None:
                return float(ef)
        except Exception as exc:                     # noqa: BLE001
            warnings.warn(f"Could not read E_F from {vxml}: {exc}")
    out = scf_dir / "OUTCAR"
    if out.is_file():
        try:
            ef = Outcar(str(out)).efermi
            if ef is not None:
                return float(ef)
        except Exception:                            # noqa: BLE001
            pass
    if fallback_dir is not None:
        v2 = fallback_dir / "vasprun.xml"
        if v2.is_file():
            warnings.warn(f"Falling back to E_F from {v2} (no usable SCF E_F).")
            ef = Vasprun(str(v2), parse_potcar_file=False).efermi   # see above: efermi needs the DOS block
            if ef is not None:
                return float(ef)
    raise RuntimeError(f"Unable to determine the Fermi level from {scf_dir}.")


def read_bands(bands_dir: Path, efermi: float):
    """Read the band structure + projections from Bands/ into a dict."""
    vxml = bands_dir / "vasprun.xml"
    if not vxml.is_file():
        raise FileNotFoundError(f"Missing {vxml}")

    # WHICH file holds the k-PATH?
    #
    # Ordinary GGA band run : KPOINTS is line-mode and IS the path.
    # meta-GGA / hybrid     : KPOINTS is a regular MESH (it drives the
    #                         self-consistent part, needed because tau and the
    #                         Fock term cannot be reconstructed from the CHGCAR)
    #                         and the path lives in KPOINTS_OPT.
    #
    # pymatgen already reads the EIGENVALUES from the KPOINTS_OPT block of
    # vasprun.xml on its own (get_band_structure(..., ignore_kpoints_opt=False),
    # the default). What it cannot guess is which file to take the high-symmetry
    # LABELS from -- and passing the mesh KPOINTS here would silently label a
    # meta-GGA band structure with the mesh, producing a figure with no ticks.
    kopt = bands_dir / "KPOINTS_OPT"
    kmesh = bands_dir / "KPOINTS"
    kpts = kopt if kopt.is_file() and kopt.stat().st_size > 0 else kmesh
    if not kpts.is_file():
        raise FileNotFoundError(
            f"Missing {kmesh}: a band run needs either a line-mode KPOINTS or, "
            "for meta-GGA/hybrid, a regular-mesh KPOINTS plus KPOINTS_OPT.")

    vr = BSVasprun(str(vxml), parse_projected_eigen=True)
    soc = bool(vr.parameters.get("LSORBIT", False))
    try:
        ispin = int(vr.parameters.get("ISPIN", 1) or 1)
    except (TypeError, ValueError):
        ispin = 1
    try:
        bs = vr.get_band_structure(kpoints_filename=str(kpts),
                                   line_mode=True, efermi=efermi)
    except Exception as exc:                         # noqa: BLE001
        raise RuntimeError(
            "Failed to build the band structure — check that Bands/KPOINTS is "
            f"line-mode and matches Bands/vasprun.xml.\nOriginal error: {exc}"
        ) from exc

    distance = np.asarray(bs.distance, dtype=float)
    bands = {sp: np.asarray(a, dtype=float) - efermi for sp, a in bs.bands.items()}
    projections = {sp: np.asarray(a, dtype=float) for sp, a in bs.projections.items()}
    n_orb = next(iter(projections.values())).shape[2] if projections else 0
    if not projections:
        warnings.warn("No orbital projections in Bands/vasprun.xml (set "
                      "LORBIT=11); fat bands will not be drawn.")

    kpoint_labels = _assign_labels(bs, kpts)
    segments = _build_segments(distance, bs.kpoints)
    kpoints_frac = np.array([k.frac_coords for k in bs.kpoints], dtype=float)

    return dict(distance=distance, bands=bands, projections=projections,
                kpoint_labels=kpoint_labels, segments=segments,
                kpoints_frac=kpoints_frac,
                structure=bs.structure, is_spin=bs.is_spin_polarized,
                soc=soc, n_orb=n_orb, ispin=ispin)


def read_dos(dos_dir: Path, efermi: float):
    """Read the total + projected DOS from Dos/ into a dict."""
    vxml = dos_dir / "vasprun.xml"
    if not vxml.is_file():
        raise FileNotFoundError(f"Missing {vxml}")
    vr = Vasprun(str(vxml), parse_potcar_file=False)
    cdos = vr.complete_dos
    energies = np.asarray(cdos.energies, dtype=float) - efermi
    total = {sp: np.asarray(d, dtype=float) for sp, d in cdos.densities.items()}
    # structure + orbital count are normally taken from the band data; carry them
    # here too so a DOS-only folder (no band run alongside) can still resolve
    # projection groups and title the figure.
    structure = getattr(cdos, "structure", None)
    n_orb = 0
    try:
        pdos = getattr(cdos, "pdos", None) or {}
        if pdos:
            n_orb = len(next(iter(pdos.values())))
    except (StopIteration, TypeError):
        n_orb = 0
    return dict(cdos=cdos, energies=energies, total=total,
                structure=structure, n_orb=n_orb)


def auto_energy_window_dos(dos_data, pad_frac=0.02, step=0.5):
    """Energy window for a DOS-only figure: the range where the DOS is non-zero.

    Mirrors auto_energy_window() for bands. Falls back to the full grid when the
    density never rises above the noise floor.
    """
    E = np.asarray(dos_data["energies"], dtype=float)
    if E.size == 0:
        return (EMIN if EMIN is not None else -4.0,
                EMAX if EMAX is not None else 4.0)
    tot = None
    for arr in dos_data["total"].values():
        a = np.abs(np.asarray(arr, dtype=float))
        tot = a if tot is None else tot + a
    if tot is None or not np.any(tot > 0):
        return float(E.min()), float(E.max())
    thresh = float(tot.max()) * 1e-3
    nz = np.nonzero(tot > thresh)[0]
    lo, hi = float(E[nz[0]]), float(E[nz[-1]])
    if hi <= lo:
        return float(E.min()), float(E.max())
    pad = max((hi - lo) * pad_frac, 0.1)
    return float(_nice(lo - pad, step, up=False)), float(_nice(hi + pad, step, up=True))


# --------------------------------------------------------------------------- #
# INCAR parsing & automatic ranges
# --------------------------------------------------------------------------- #
def _parse_incar_tag(path: Path, tag: str):
    """Return the value string of an INCAR `tag` (case-insensitive), or None."""
    try:
        text = Path(path).read_text()
    except OSError:
        return None
    value = None
    for raw in text.splitlines():
        for chunk in raw.split(";"):
            chunk = chunk.split("#", 1)[0].split("!", 1)[0]
            m = re.match(r"\s*([A-Za-z_]+)\s*=\s*(.+?)\s*$", chunk)
            if m and m.group(1).upper() == tag.upper():
                value = m.group(2).strip() or None     # full value (keep spaces)
    return value


def resolve_dos_smearing(dirs, default=DEFAULT_SMEAR):
    """Decide the Gaussian broadening (eV) to apply to the plotted DOS.

    Returns (sigma, ismear, nedos, source_path_or_None).
    """
    for d in dirs:
        inc = Path(d) / "INCAR"
        if not inc.is_file():
            continue
        ismear_raw = _parse_incar_tag(inc, "ISMEAR")
        nedos_raw = _parse_incar_tag(inc, "NEDOS")
        sigma_raw = _parse_incar_tag(inc, "SIGMA")
        ismear = nedos = None
        try:
            ismear = int(float(ismear_raw)) if ismear_raw is not None else None
        except ValueError:
            ismear = None
        try:
            nedos = int(float(nedos_raw)) if nedos_raw is not None else None
        except ValueError:
            nedos = None
        if ismear is None and sigma_raw is None:
            continue                                   # this INCAR says nothing
        return 0.0, ismear, nedos, inc                 # already integrated grid
    return default, None, None, None


def _nice(x, step, up):
    """Round x outward to a multiple of step (up=True -> ceil, else floor)."""
    return (np.ceil(x / step) if up else np.floor(x / step)) * step


def auto_energy_window(bands_data, pad_frac=0.04, step=0.5):
    """Energy window (emin, emax) framing all plotted bands, E_F-referenced."""
    segs = bands_data["segments"]
    lo, hi = np.inf, -np.inf
    for arr in bands_data["bands"].values():
        for sl in segs:
            block = arr[:, sl]
            if block.size:
                lo = min(lo, float(block.min()))
                hi = max(hi, float(block.max()))
    if not np.isfinite(lo) or not np.isfinite(hi) or hi <= lo:
        return EMIN if EMIN is not None else -4.0, EMAX if EMAX is not None else 4.0
    pad = max((hi - lo) * pad_frac, 0.1)
    return float(_nice(lo - pad, step, up=False)), float(_nice(hi + pad, step, up=True))
