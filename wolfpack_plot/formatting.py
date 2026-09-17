"""
wolfpack_plot.formatting
========================
The "vocabulary" layer: orbital bookkeeping (which pymatgen ``Orbital`` columns
a token like ``d`` or ``px`` maps to, plus validation), and all TeX/mathtext
formatting for orbital labels, high-symmetry k-point labels and figure titles.

Pure string/orbital logic -- no numpy, no plotting.
"""
from __future__ import annotations

import re

from pymatgen.electronic_structure.core import Orbital, OrbitalType


# --------------------------------------------------------------------------- #
# Orbital bookkeeping
# --------------------------------------------------------------------------- #
_ORBITAL_GROUPS = {
    "s": [Orbital.s],
    "p": [Orbital.px, Orbital.py, Orbital.pz],
    "d": [Orbital.dxy, Orbital.dyz, Orbital.dz2, Orbital.dxz, Orbital.dx2],
    "f": [Orbital.f_3, Orbital.f_2, Orbital.f_1, Orbital.f0,
          Orbital.f1, Orbital.f2, Orbital.f3],
}
_GROUP_TYPE = {"s": OrbitalType.s, "p": OrbitalType.p,
               "d": OrbitalType.d, "f": OrbitalType.f}
_REDUCED_COL = {"s": 0, "p": 1, "d": 2, "f": 3}      # for lm-summed LORBIT=10
_GROUP_TOKENS = set(_ORBITAL_GROUPS)
_ORBITAL_NAMES = {o.name for o in Orbital}

# Pretty TeX for orbital tokens (used in legend labels).
_ORB_TEX = {
    "s": "s", "p": "p", "d": "d", "f": "f",
    "px": "p_x", "py": "p_y", "pz": "p_z",
    "dxy": "d_{xy}", "dyz": "d_{yz}", "dxz": "d_{xz}",
    "dz2": "d_{z^2}", "dx2": "d_{x^2-y^2}",
}

# Greek high-symmetry aliases -> TeX command. NB: bare "S" is the S point, not
# Sigma; only the spelled-out forms map to Greek.
_GREEK = {
    "GAMMA": r"\Gamma", "GAMA": r"\Gamma", "GAM": r"\Gamma",
    "GA": r"\Gamma", "GM": r"\Gamma", "G": r"\Gamma", "G0": r"\Gamma",
    "SIGMA": r"\Sigma", "SIG": r"\Sigma",
    "DELTA": r"\Delta", "DEL": r"\Delta",
    "LAMBDA": r"\Lambda", "LAM": r"\Lambda", "LMD": r"\Lambda",
    "PI": r"\Pi", "PHI": r"\Phi", "PSI": r"\Psi",
    "THETA": r"\Theta", "OMEGA": r"\Omega", "XI": r"\Xi",
}

# Literal unicode Greek letters that may appear directly in KPOINTS comments.
_GREEK_UNICODE = {
    "Γ": r"\Gamma", "Δ": r"\Delta", "Θ": r"\Theta",
    "Λ": r"\Lambda", "Ξ": r"\Xi", "Π": r"\Pi",
    "Σ": r"\Sigma", "Φ": r"\Phi", "Ψ": r"\Psi",
    "Ω": r"\Omega",
    "γ": r"\gamma", "δ": r"\delta", "λ": r"\lambda",
    "π": r"\pi", "σ": r"\sigma",
}


def _orb_tex(tok: str) -> str:
    """TeX label for an orbital token (e.g. 'dz2' -> d_{z^2})."""
    return _ORB_TEX.get(tok, r"\mathrm{%s}" % tok)


# --------------------------------------------------------------------------- #
# Orbital -> column resolution & availability
# --------------------------------------------------------------------------- #
def _resolve_band_columns(tokens, n_orb):
    """Orbital tokens -> projection-array column indices."""
    lm = n_orb >= 9
    cols = []
    for tok in tokens:
        if tok in _GROUP_TOKENS:
            if lm:
                cols += [o.value for o in _ORBITAL_GROUPS[tok] if o.value < n_orb]
            elif _REDUCED_COL[tok] < n_orb:
                cols.append(_REDUCED_COL[tok])
        else:
            cols.append(Orbital[tok].value)
    return sorted(set(cols))


def _validate_orbital(tok, n_orb, el):
    """Raise a clear error if orbital token `tok` is unusable for element `el`."""
    if n_orb == 0:
        raise ValueError("This calculation stores no orbital projections "
                         "(rerun the Bands/DOS steps with LORBIT=11).")
    if tok not in _GROUP_TOKENS and tok not in _ORBITAL_NAMES:
        raise ValueError(
            f'Unknown orbital "{tok}". Use s, p, d, f or a specific lm orbital '
            f'(px, py, pz, dxy, dyz, dz2, dxz, dx2, ...).')
    lm = n_orb >= 9
    if tok in _GROUP_TOKENS:
        if tok == "f":
            has_f = (n_orb >= 16) if lm else (n_orb >= 4)
            if not has_f:
                raise ValueError(
                    f'The "f" orbital is not available in this calculation '
                    f'(projections contain only s, p, d) — requested for {el}.')
        return
    if not lm:
        raise ValueError(
            f'Orbital "{tok}" needs lm-resolved projections (LORBIT=11); this '
            f'run only stores s/p/d sums. Use s, p, or d for {el} instead.')
    if Orbital[tok].value >= n_orb:
        raise ValueError(
            f'Orbital "{tok}" (f-type) is not available: this calculation stores '
            f'{n_orb} orbital columns — requested for {el}.')


# --------------------------------------------------------------------------- #
# TeX / label formatting
# --------------------------------------------------------------------------- #
def _fmt_kpt_token(tok: str) -> str:
    """Format a single high-symmetry token -> mathtext fragment (no $...$)."""
    tok = (tok or "").strip().strip("$").strip()
    if not tok:
        return ""
    # Drop a leading segment-index glued to the label, e.g. "1Gamma" -> "Gamma".
    m = re.match(r"^\d+(?=[^\d])(.*)$", tok)
    if m and m.group(1):
        tok = m.group(1).strip()
    sub = ""
    if "_" in tok:
        tok, sub = tok.split("_", 1)
        tok, sub = tok.strip(), sub.strip()
    if tok in _GREEK_UNICODE:                 # literal Γ, Σ, ... in the file
        main = _GREEK_UNICODE[tok]
    else:
        key = tok.lstrip("\\").upper()
        if key in _GREEK:
            main = _GREEK[key]
        elif tok.startswith("\\"):
            main = tok                        # already a TeX command
        else:
            main = r"\mathrm{%s}" % tok       # upright Roman point label
    if sub:
        main += r"_{\mathrm{%s}}" % sub
    return main


def format_kpt_label(label) -> str:
    """Render a (possibly merged 'A|B') high-symmetry label as mathtext."""
    if not label:
        return ""
    parts = [p for p in re.split(r"[|｜/]", str(label)) if p.strip()]
    frags = [f for f in (_fmt_kpt_token(p) for p in parts) if f]
    if not frags:
        return ""
    return "$" + r"\,|\,".join(frags) + "$"


def mathify_title(raw: str) -> str:
    r"""Render a light TeX-ish title in journal style (e.g. "MoS_2 - G_0W_0")."""
    if not raw:
        return ""
    if "$" in raw:
        return raw
    out, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c == "\\":                                  # TeX command
            j = i + 1
            while j < n and raw[j].isalpha():
                j += 1
            out.append(raw[i:j]); i = j
        elif c in "_^":                                # sub/superscript
            op, i = c, i + 1
            if i < n and raw[i] == "{":
                k = raw.find("}", i); k = n if k < 0 else k
                content, i = raw[i + 1:k], k + 1
            else:                                      # brace-less: one token
                content, i = (raw[i], i + 1) if i < n else ("", i)
            out.append(r"%s{\mathrm{%s}}" % (op, content))
        elif c.isalnum():                              # upright run
            k = i
            while k < n and raw[k].isalnum():
                k += 1
            out.append(r"\mathrm{%s}" % raw[i:k]); i = k
        elif c == " ":
            out.append(r"\ "); i += 1
        else:
            out.append("\\" + c if c in "#%&{}" else c)
            i += 1
    return "$" + "".join(out) + "$"


def _auto_formula_tex(formula: str) -> str:
    """Subscript digit groups in a plain formula, then render. MoS2 -> MoS₂."""
    return mathify_title(re.sub(r"(\d+)", r"_{\1}", formula))


def _plain_klabel(tex):
    """Turn a TeX k-label (e.g. '$\\Gamma$') into plain text for the .txt report."""
    if not tex:
        return None
    s = tex.replace("$", "").replace(r"\mathrm", "").replace("{", "").replace("}", "")
    greek = {r"\Gamma": "Γ", r"\Sigma": "Σ", r"\Delta": "Δ", r"\Lambda": "Λ",
             r"\Pi": "Π", r"\Phi": "Φ", r"\Omega": "Ω"}
    for k, v in greek.items():
        s = s.replace(k, v)
    return s.strip().lstrip("\\") or None
