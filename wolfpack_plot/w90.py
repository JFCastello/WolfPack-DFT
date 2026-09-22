"""
wolfpack_plot.w90
=================
Read Wannier90 interpolated band structures and densities of states, and shape
them exactly like the VASP data dicts so the SAME figure builders draw them --
no extra flags, no separate look.

HOW VASP AND WANNIER90 FIT TOGETHER
-----------------------------------
1. VASP runs with ``LWANNIER90 = .TRUE.``.  It writes/completes ``wannier90.win``
   (adding ``num_wann``, ``unit_cell_cart``, ``atoms_cart``, ``mp_grid`` and the
   ``kpoints`` block) and emits the overlap/projection/eigenvalue files
   ``wannier90.mmn``, ``.amn``, ``.eig``.
2. ``wannier90.x`` localises the Wannier functions and, with ``bands_plot=.true.``
   plus a ``begin kpoint_path`` block, writes the interpolated band structure.
3. ``postw90.x`` with ``dos = true`` writes the interpolated density of states.

FILE FORMATS (taken from the Wannier90 Fortran sources, not guessed)
--------------------------------------------------------------------
``seedname_band.dat``   -- ``plot_interpolate_bands``::

        do i = 1, num_wann            ! BAND is the OUTER loop
          do nkp = 1, total_pts
            write (bndunit,'(2E16.8)') xval(nkp), eig_int(i,nkp)
          enddo
          write (bndunit,*) ' '       ! blank line BETWEEN bands
        enddo

    so: column 1 = cumulative k-distance, column 2 = energy in **absolute eV**
    (never Fermi-referenced), one blank-line-separated block per band.  With
    ``num_bands_project > 0`` a third column carries a projection weight.

``seedname_band.kpt``   -- ``write(bndunit,'(3f12.6,3x,a)')`` after a first line
    holding the number of points: the path in fractional reciprocal coordinates.

``seedname_band.gnu``   -- carries the high-symmetry ticks as a gnuplot
    ``set xtics ("G" 0.00000, "X" 0.51234, ...)`` line: the cleanest source of
    both the labels and their positions along the path.

``seedname-dos.dat``    -- ``dos_main``::

        open (dos_unit, FILE=trim(seedname)//'-dos.dat', ...)
        write (dos_unit,'(4E16.8)') omega, dos_all(ifreq,:)

    column 1 = energy in **absolute eV**, column 2 = total DOS, and with
    ``spin_decomp`` columns 3 and 4 = the spin-up and spin-down parts.

Because both energy axes are absolute, the Fermi level must be supplied: it is
taken from ``fermi_energy`` in the ``.win`` file, else from a VASP run in the
same folder or its parent (that is the DFT step the Wannierisation came from).
"""
from __future__ import annotations

import re
import warnings
from pathlib import Path

import numpy as np

try:                                                # optional at import time
    from pymatgen.electronic_structure.core import Spin
except Exception:                                   # pragma: no cover
    Spin = None


# --------------------------------------------------------------------------- #
# The .win input file
# --------------------------------------------------------------------------- #
def parse_win(path):
    """Parse a Wannier90 ``.win`` file.

    Returns dict(tags={key: value}, blocks={name: [lines]}).  Keys are lowercased;
    Wannier90 treats '_' and '-' alike and ignores case, so we normalise both.
    """
    tags, blocks = {}, {}
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return dict(tags=tags, blocks=blocks)

    cur, buf = None, []
    for raw in text.splitlines():
        line = raw.split("!", 1)[0].split("#", 1)[0].strip()
        if not line:
            continue
        low = line.lower()
        if low.startswith("begin"):
            cur = low.split(None, 1)[1].strip().replace("-", "_") if " " in low else None
            buf = []
            continue
        if low.startswith("end"):
            if cur:
                blocks[cur] = buf
            cur, buf = None, []
            continue
        if cur is not None:
            buf.append(line)
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_\-]*)\s*[=:]?\s*(.*)$", line)
        if m:
            tags[m.group(1).lower().replace("-", "_")] = m.group(2).strip()
    return dict(tags=tags, blocks=blocks)


def _win_float(tags, key):
    try:
        return float(str(tags.get(key, "")).split()[0])
    except (ValueError, IndexError):
        return None


def kpath_labels_from_win(blocks):
    """High-symmetry labels, in path order, from the ``kpoint_path`` block.

    Each line is ``LABEL_A ax ay az   LABEL_B bx by bz`` (one segment).  The
    returned list is the label sequence a reader would see along the path, with
    a discontinuity marked by 'A|B' when one segment does not start where the
    previous one ended.
    """
    lines = blocks.get("kpoint_path") or []
    labs, prev_end, prev_coord = [], None, None
    for ln in lines:
        parts = ln.split()
        if len(parts) < 8:
            continue
        a, acoord = parts[0], tuple(float(x) for x in parts[1:4])
        b, bcoord = parts[4], tuple(float(x) for x in parts[5:8])
        if prev_end is None:
            labs.append(a)
        elif prev_coord is not None and not np.allclose(prev_coord, acoord, atol=1e-6):
            labs[-1] = f"{prev_end}|{a}"            # path jumps here
        elif prev_end != a:
            labs[-1] = f"{prev_end}|{a}"
        labs.append(b)
        prev_end, prev_coord = b, bcoord
    return labs


# --------------------------------------------------------------------------- #
# Ticks from the gnuplot script (labels AND their x positions)
# --------------------------------------------------------------------------- #
def ticks_from_gnu(path):
    """[(x, label), ...] parsed from the ``set xtics (...)`` line of a _band.gnu.

    This is the most reliable source: Wannier90 writes the label together with
    its exact position along the interpolated path.
    """
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return []
    m = re.search(r"set\s+xtics\s*\((.*?)\)", text, re.S | re.I)
    if not m:
        return []
    out = []
    for lab, pos in re.findall(r'"([^"]*)"\s+([-\d.EedD+]+)', m.group(1)):
        try:
            out.append((float(pos.replace("d", "e").replace("D", "E")), lab))
        except ValueError:
            continue
    return out


# --------------------------------------------------------------------------- #
# The Fermi level
# --------------------------------------------------------------------------- #
def resolve_w90_fermi(folder, win, explicit=None):
    """Fermi energy (eV) for Wannier90 output, which is written in ABSOLUTE eV.

    Order: an explicit value > ``fermi_energy`` in the .win > a VASP run in this
    folder > a VASP run in the parent folder (the DFT step Wannier90 came from).
    """
    if explicit is not None:
        return float(explicit), "given on the command line"
    ef = _win_float(win.get("tags", {}), "fermi_energy")
    if ef is not None:
        return ef, "fermi_energy in the .win file"

    folder = Path(folder)
    for cand in (folder, folder.parent):
        vx = cand / "vasprun.xml"
        if vx.is_file():
            try:
                from pymatgen.io.vasp.outputs import Vasprun
                # parse_dos stays on: pymatgen only sets Vasprun.efermi
                # while parsing the <dos> block (see wolfpack_plot/vaspio.py).
                v = Vasprun(str(vx), parse_eigen=False,
                            parse_projected_eigen=False, parse_potcar_file=False)
                if v.efermi is not None:
                    return float(v.efermi), f"VASP {vx}"
            except Exception:                       # noqa: BLE001
                pass
        oc = cand / "OUTCAR"
        if oc.is_file():
            try:
                from pymatgen.io.vasp.outputs import Outcar
                ef = Outcar(str(oc)).efermi
                if ef is not None:
                    return float(ef), f"VASP {oc}"
            except Exception:                       # noqa: BLE001
                pass

    warnings.warn("No Fermi level found for the Wannier90 data (no fermi_energy "
                  "in the .win and no VASP run alongside): energies are left "
                  "absolute. Pass --efermi to set it.")
    return 0.0, "not found (energies left absolute)"


def _structure_near(folder):
    """A pymatgen Structure from POSCAR/CONTCAR/vasprun next to the w90 output.

    Only used to title the figure; None is perfectly fine.
    """
    folder = Path(folder)
    for cand in (folder, folder.parent):
        for name in ("vasprun.xml", "POSCAR", "CONTCAR"):
            p = cand / name
            if not p.is_file():
                continue
            try:
                if name == "vasprun.xml":
                    from pymatgen.io.vasp.outputs import Vasprun
                    return Vasprun(str(p), parse_dos=False, parse_eigen=False,
                                   parse_projected_eigen=False,
                                   parse_potcar_file=False).final_structure
                from pymatgen.core import Structure
                return Structure.from_file(str(p))
            except Exception:                       # noqa: BLE001
                continue
    return None


# --------------------------------------------------------------------------- #
# Band structure
# --------------------------------------------------------------------------- #
def read_w90_bands(folder, w90, efermi=None):
    """Read ``seedname_band.dat`` into the same dict shape as ``read_bands``.

    Bands are stored band-outer, blank-line separated; every band shares the
    same k-distance grid, so the file is parsed into blocks and stacked.
    """
    dat = w90.get("band_dat")
    if dat is None:
        raise FileNotFoundError("no Wannier90 band file (*_band.dat) in this folder")
    win = parse_win(w90["win"]) if w90.get("win") else dict(tags={}, blocks={})
    ef, ef_src = resolve_w90_fermi(folder, win, efermi)

    # --- parse the blank-line-separated per-band blocks ---------------------
    blocks, cur = [], []
    for raw in Path(dat).read_text(errors="replace").splitlines():
        s = raw.strip()
        if not s:
            if cur:
                blocks.append(cur)
                cur = []
            continue
        parts = s.split()
        try:
            cur.append([float(parts[0]), float(parts[1])])
        except (ValueError, IndexError):
            continue
    if cur:
        blocks.append(cur)
    if not blocks:
        raise ValueError(f"{dat} contains no numeric band data")

    nk = len(blocks[0])
    blocks = [b for b in blocks if len(b) == nk]     # drop any truncated tail
    arr = np.array(blocks, dtype=float)              # (n_band, nk, 2)
    distance = arr[0, :, 0]
    bands = arr[:, :, 1] - ef                        # -> Fermi-referenced

    # --- high-symmetry ticks: prefer the .gnu (labels + exact positions) -----
    ticks = ticks_from_gnu(w90["band_gnu"]) if w90.get("band_gnu") else []
    if not ticks:
        labs = kpath_labels_from_win(win.get("blocks", {}))
        if labs:                                     # spread evenly as a fallback
            xs = np.linspace(distance[0], distance[-1], len(labs))
            ticks = list(zip(xs, labs))

    # Map ticks onto per-k-point labels, the way the VASP reader does.
    kpoint_labels = [None] * nk
    for x, lab in ticks:
        idx = int(np.argmin(np.abs(distance - x)))
        kpoint_labels[idx] = (f"{kpoint_labels[idx]}|{lab}"
                              if kpoint_labels[idx] and lab not in
                              kpoint_labels[idx].split("|") else lab)

    # A repeated tick position means the path jumps: split there so the panels
    # are drawn separately, exactly like a VASP line-mode path.
    segments = [slice(0, nk)]

    kpts_frac = np.zeros((nk, 3))
    if w90.get("band_kpt"):
        try:
            rows = Path(w90["band_kpt"]).read_text(errors="replace").splitlines()[1:]
            vals = [[float(x) for x in r.split()[:3]] for r in rows if len(r.split()) >= 3]
            if len(vals) == nk:
                kpts_frac = np.array(vals, dtype=float)
        except (ValueError, OSError):
            pass

    spin_key = Spin.up if Spin is not None else 1
    return dict(distance=distance,
                bands={spin_key: bands},
                projections={},
                kpoint_labels=kpoint_labels,
                segments=segments,
                kpoints_frac=kpts_frac,
                structure=_structure_near(folder),
                is_spin=False, soc=False, n_orb=0, ispin=1,
                efermi=ef, efermi_source=ef_src,
                w90=True)


# --------------------------------------------------------------------------- #
# Density of states
# --------------------------------------------------------------------------- #
def read_w90_dos(folder, w90, efermi=None):
    """Read ``seedname-dos.dat`` into the same dict shape as ``read_dos``.

    Column 1 is energy (absolute eV), column 2 the total DOS; with
    ``spin_decomp`` columns 3 and 4 hold the spin-up and spin-down parts, which
    are mapped onto the two Spin channels so the spin plots work unchanged.
    """
    dat = w90.get("dos_dat")
    if dat is None:
        raise FileNotFoundError("no Wannier90 DOS file (*-dos.dat) in this folder")
    win = parse_win(w90["win"]) if w90.get("win") else dict(tags={}, blocks={})
    ef, ef_src = resolve_w90_fermi(folder, win, efermi)

    rows = []
    for raw in Path(dat).read_text(errors="replace").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        try:
            rows.append([float(x) for x in s.split()])
        except ValueError:
            continue
    if not rows:
        raise ValueError(f"{dat} contains no numeric DOS data")
    ncol = min(len(r) for r in rows)
    arr = np.array([r[:ncol] for r in rows], dtype=float)

    energies = arr[:, 0] - ef
    spin_up = Spin.up if Spin is not None else 1
    spin_dn = Spin.down if Spin is not None else -1
    if ncol >= 4 and np.any(arr[:, 2] != 0) and np.any(arr[:, 3] != 0):
        total = {spin_up: arr[:, 2], spin_dn: arr[:, 3]}   # spin_decomp = true
    else:
        total = {spin_up: arr[:, 1]}
    return dict(cdos=None, energies=energies, total=total,
                structure=_structure_near(folder), n_orb=0,
                efermi=ef, efermi_source=ef_src, w90=True)


def describe(folder, w90):
    """One-line summary of the Wannier90 artefacts found (for the log)."""
    bits = []
    if w90.get("band_dat"):
        bits.append(f"bands={Path(w90['band_dat']).name}")
    if w90.get("dos_dat"):
        bits.append(f"dos={Path(w90['dos_dat']).name}")
    if w90.get("win"):
        bits.append(f"win={Path(w90['win']).name}")
    return ", ".join(bits) if bits else "no Wannier90 files"
