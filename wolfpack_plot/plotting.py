"""
wolfpack_plot.plotting
=====================
Everything that draws: the shared pale-grey band backbone (behind EVERY
method), the per-method markers (plain / one_orbital / duo / rgb / stacked),
the VBM-CBM gap annotation, and the full figure assembly (bands + DOS).
"""
from __future__ import annotations

import numpy as np
from scipy.interpolate import interp1d

import matplotlib
matplotlib.use("Agg")
import matplotlib.colors as mcolors
import matplotlib.patheffects as pe
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import FuncFormatter, MaxNLocator

from pymatgen.electronic_structure.core import Spin

from .config import (ALPHA_MAX, ALPHA_MIN, BACKBONE_COLOR, BACKBONE_LW,
                     CMYK_CHANNELS, DEFAULT_METHOD, DOS_LW, DOS_TOTAL_LW,
                     DUO_CHANNELS, EDGE_CORE, EDGE_HALO, KPT_LABEL_SIZE,
                     MARKER_SIZE, MARKER_TARGET, ONE_ORBITAL_CHANNEL,
                     OVERLAY_BACKBONE_ALPHA, OVERLAY_BACKBONE_LS,
                     OVERLAY_BACKBONE_LW, OVERLAY_DOWN_BACKBONE,
                     OVERLAY_DOWN_COLOR, OVERLAY_UP_BACKBONE, OVERLAY_UP_COLOR,
                     PLAIN_ALPHA, PLAIN_MARKER_COLOR, PLAIN_MARKER_SIZE,
                     PROJ_CUTOFF, RGB_CHANNELS, SEG_WSPACE, STACKED_CIRCLE_SIZE,
                     STACKED_COLORS, STACKED_INTERP, STACKED_NORMALISE,
                     STACKED_PROJ_CUTOFF, WIDTH_RATIOS)
from .formatting import _auto_formula_tex, format_kpt_label, mathify_title
from .physics import _smear, band_weights, dos_projection, state_total_weight
from .vaspio import _segment_ticks


MARKER = "o"               # small circle: clearest when many bands overlap

# Wannier90 interpolated bands are continuous curves, not sampled points.
W90_BAND_COLOR = "0.20"
W90_BAND_LW = 1.1


# --------------------------------------------------------------------------- #
# Colour helpers
# --------------------------------------------------------------------------- #
def _hybrid_colors(wRGB, channels=RGB_CHANNELS):
    """Additive colour for each point from the relative group weights.

    Used by rgb (3 channels), duo (2) and one_orbital (1): the per-point colour
    is the weight-weighted average of the channel colours.
    """
    w = np.clip(np.asarray(wRGB, float), 0.0, None)            # (N,k)
    chan = np.array([mcolors.to_rgb(c) for c in channels])     # (k,3)
    s = w.sum(axis=1, keepdims=True)                          # (N,1)
    f = np.divide(w, s, out=np.zeros_like(w), where=s > 0)    # normalised mix
    return np.clip(f @ chan, 0.0, 1.0)


def _cmyk_colors(w4, channels=CMYK_CHANNELS):
    """Subtractive CMYK colour for each point from 4 relative group weights.

    The four normalised weights become the (C, M, Y, K) fractions of a CMYK
    colour, converted to RGB by R=(1-C)(1-K), G=(1-M)(1-K), B=(1-Y)(1-K).
    A point dominated by group 0->cyan, 1->magenta, 2->yellow, 3->black.
    `channels` is unused (kept for a common signature with _hybrid_colors).
    """
    w = np.clip(np.asarray(w4, float), 0.0, None)              # (N,4)
    s = w.sum(axis=1, keepdims=True)                           # (N,1)
    f = np.divide(w, s, out=np.zeros_like(w), where=s > 0)     # C,M,Y,K fractions
    C, M, Y, K = f[:, 0], f[:, 1], f[:, 2], f[:, 3]
    rgb = np.stack([(1 - C) * (1 - K), (1 - M) * (1 - K), (1 - Y) * (1 - K)],
                   axis=1)
    return np.clip(rgb, 0.0, 1.0)


def _marker_indices(dist, sl, spacing):
    """Indices within branch slice `sl`, ~evenly spaced by k-distance."""
    seg = dist[sl]
    n = len(seg)
    if n <= 3 or spacing <= 0:
        return np.arange(n)
    targets = np.arange(seg[0], seg[-1] + spacing * 0.5, spacing)
    idx = np.unique(np.clip(np.searchsorted(seg, targets), 0, n - 1))
    if idx[-1] != n - 1:
        idx = np.append(idx, n - 1)
    return idx


# --------------------------------------------------------------------------- #
# Shared backbone (background of every method)
# --------------------------------------------------------------------------- #
def _draw_backbone(ax, bands_data, sl, spins, lsty):
    """Trace every band with the shared, very thin, very pale grey line.

    Drawn first (lowest zorder) so it sits behind the markers of EVERY method,
    and is the sole line of the "plain" method.
    """
    x = bands_data["distance"][sl]
    for sp in spins:
        for band in bands_data["bands"][sp]:
            ax.plot(x, band[sl], color=BACKBONE_COLOR, lw=BACKBONE_LW,
                    ls=lsty(sp), zorder=1, solid_capstyle="round")


def _draw_overlay_backbones(ax, bands_data, sl):
    """Two per-spin backbones for the overlaid plain plot: very thin, dashed,
    highly transparent, pale blue (up) and pale orange (down)."""
    x = bands_data["distance"][sl]
    cols = {Spin.up: OVERLAY_UP_BACKBONE, Spin.down: OVERLAY_DOWN_BACKBONE}
    for sp in (Spin.up, Spin.down):
        bands = bands_data["bands"].get(sp)
        if bands is None:
            continue
        for band in bands:
            ax.plot(x, band[sl], color=cols[sp], lw=OVERLAY_BACKBONE_LW,
                    ls=OVERLAY_BACKBONE_LS, alpha=OVERLAY_BACKBONE_ALPHA,
                    zorder=1, solid_capstyle="round")


# --------------------------------------------------------------------------- #
# Method dispatch
# --------------------------------------------------------------------------- #
def _draw_segment(ax, bands_data, groups, band_w, w_tot, sl, spins, cfg, lsty,
                  spacing):
    """Dispatch one k-path sub-panel to the chosen projection method (a single
    spin channel; --spin both is handled as separate figures + the overlay)."""
    method = getattr(cfg, "method", DEFAULT_METHOD)
    if method == "plain":
        _draw_plain(ax, bands_data, sl, spins, cfg, lsty)
    elif method == "stacked":
        _draw_stacked(ax, bands_data, groups, band_w, w_tot, sl, spins, cfg, lsty)
    else:                                # rgb (3), duo (2), one_orbital (1), cmyk (4)
        if method == "one_orbital":
            channels, color_fn = ONE_ORBITAL_CHANNEL, _hybrid_colors
        elif method == "duo":
            channels, color_fn = DUO_CHANNELS, _hybrid_colors
        elif method == "cmyk":
            channels, color_fn = CMYK_CHANNELS, _cmyk_colors
        else:
            channels, color_fn = RGB_CHANNELS, _hybrid_colors
        _draw_alpha_circles(ax, bands_data, groups, band_w, w_tot, sl, spins, cfg,
                            lsty, spacing, channels, color_fn)


def _draw_plain(ax, bands_data, sl, spins, cfg, lsty):
    """plain method: shared pale backbone + a small, slightly-translucent black
    circle at every k-point where the eigenvalues were computed.

    Wannier90 output is an INTERPOLATION onto a dense path -- its points are not
    computed eigenvalues, so marking every one would be misleading (and unreadable).
    Interpolated bands are therefore drawn as continuous solid curves instead.
    """
    if bands_data.get("w90"):
        x = bands_data["distance"][sl]
        for sp in spins:
            for band in bands_data["bands"][sp]:
                ax.plot(x, band[sl], color=W90_BAND_COLOR, lw=W90_BAND_LW,
                        ls=lsty(sp), zorder=3, solid_capstyle="round")
        return
    _draw_backbone(ax, bands_data, sl, spins, lsty)
    x = bands_data["distance"][sl]
    size = float(getattr(cfg, "plain_marker_size", PLAIN_MARKER_SIZE))
    face = mcolors.to_rgba(PLAIN_MARKER_COLOR, PLAIN_ALPHA)   # intermediate alpha
    for sp in spins:
        Y = bands_data["bands"][sp][:, sl]               # (nb, nk_seg)
        X = np.tile(x, Y.shape[0])
        ax.scatter(X, Y.reshape(-1), s=size, marker=MARKER, facecolors=[face],
                   edgecolors="none", linewidths=0.0, zorder=3)


def _draw_overlay_plain(ax, bands_data, sl, cfg):
    """Overlaid plain plot (ISPIN=2, --spin both): both channels in one plain
    plot -- spin-up pure-RGB-blue, spin-down vivid-orange, slightly-translucent
    circles over two dashed, pale, per-spin backbones. No projections."""
    _draw_overlay_backbones(ax, bands_data, sl)
    x = bands_data["distance"][sl]
    size = float(getattr(cfg, "plain_marker_size", PLAIN_MARKER_SIZE))
    cols = {Spin.up: OVERLAY_UP_COLOR, Spin.down: OVERLAY_DOWN_COLOR}
    for sp in (Spin.up, Spin.down):
        bands = bands_data["bands"].get(sp)
        if bands is None:
            continue
        Y = bands[:, sl]
        X = np.tile(x, Y.shape[0])
        face = mcolors.to_rgba(cols[sp], PLAIN_ALPHA)
        ax.scatter(X, Y.reshape(-1), s=size, marker=MARKER, facecolors=[face],
                   edgecolors="none", linewidths=0.0,
                   zorder=3 if sp == Spin.up else 4)


def _draw_alpha_circles(ax, bands_data, groups, band_w, w_tot, sl, spins, cfg,
                        lsty, spacing, channels, color_fn=_hybrid_colors):
    """rgb / duo / one_orbital / cmyk: shared backbone + one fixed-size circle
    per (band, k). Colour = `color_fn` of the relative group weights (additive
    for rgb/duo/one_orbital, subtractive CMYK for cmyk); OPACITY = S = (sum of
    the selected group weights)/w_tot. Always plain circles (no spin edges)."""
    ng = len(channels)
    _draw_backbone(ax, bands_data, sl, spins, lsty)
    x = bands_data["distance"][sl]

    size = float(getattr(cfg, "marker_size", MARKER_SIZE))
    al_lo = float(getattr(cfg, "alpha_min", ALPHA_MIN))
    al_hi = float(getattr(cfg, "alpha_max", ALPHA_MAX))
    midx = _marker_indices(bands_data["distance"], sl, spacing)
    xm = x[midx]
    nb = {sp: bands_data["bands"][sp].shape[0] for sp in spins}

    for sp in spins:
        wcols = [np.zeros((nb[sp], len(midx))) for _ in range(ng)]
        for g in groups:
            w = band_w[g["plain"]]
            if w is None or sp not in w:
                continue
            wcols[g["channel"]] = np.clip(w[sp][:, sl][:, midx], 0.0, None)

        X = np.tile(xm, nb[sp])
        Y = bands_data["bands"][sp][:, sl][:, midx].reshape(-1)
        W = np.stack([wc.reshape(-1) for wc in wcols], axis=1)     # (N,ng) raw
        sgrp = W.sum(axis=1)                                       # group weight

        if w_tot is not None and sp in w_tot:                     # S = group/total
            tot = w_tot[sp][:, sl][:, midx].reshape(-1)
            S = np.divide(sgrp, tot, out=np.zeros_like(sgrp), where=tot > 0)
        else:
            S = sgrp
        S = np.clip(S, 0.0, 1.0)

        keep = sgrp > PROJ_CUTOFF
        if not np.any(keep):
            continue
        X, Y, W, S = X[keep], Y[keep], W[keep], S[keep]

        rgb = color_fn(W, channels)                  # colour from relative mix
        alpha = al_lo + (al_hi - al_lo) * S          # opacity = total weight
        rgba = np.concatenate([rgb, alpha[:, None]], axis=1)      # (M,4)

        ax.scatter(X, Y, s=size, marker=MARKER, facecolors=rgba,
                   edgecolors="none", linewidths=0.0, zorder=3)


def _draw_stacked(ax, bands_data, groups, band_w, w_tot, sl, spins, cfg, lsty):
    """sumo's "stacked" projected-band mode, faithfully reproduced: per (band, k)
    the projection weights are NORMALISED (sumo `normalise`, default "select" =
    by the sum over the selected groups), the bands + weights are spline-
    interpolated by `interpolate_factor` for smoothness, weights below
    `projection_cutoff` are zeroed, and each group is drawn as filled circles of
    AREA = circle_size * w**2 in the sumo colour cycle (edgeless, rasterised),
    later groups behind earlier ones (zorder). The shared pale backbone is kept
    behind the circles."""
    _draw_backbone(ax, bands_data, sl, spins, lsty)
    circle_size = float(getattr(cfg, "circle_size", STACKED_CIRCLE_SIZE))
    cutoff = STACKED_PROJ_CUTOFF
    colours = list(STACKED_COLORS) + list(
        plt.rcParams["axes.prop_cycle"].by_key()["color"])
    x = bands_data["distance"][sl]

    for sp in spins:
        bands = bands_data["bands"][sp][:, sl]                    # (nb, nk)
        raw = []
        for g in groups:
            w = band_w[g["plain"]]
            wg = (w[sp][:, sl] if (w is not None and sp in w)
                  else np.zeros_like(bands))
            raw.append(np.clip(wg, 0.0, None))
        raw = np.array(raw)                                       # (ng, nb, nk)

        # sumo normalisation of the per-point projection weights
        if STACKED_NORMALISE == "select":
            denom = raw.sum(axis=0)                               # sum of selected
        elif STACKED_NORMALISE == "all" and w_tot is not None and sp in w_tot:
            denom = w_tot[sp][:, sl]                              # all states
        else:
            denom = None                                         # raw magnitudes
        if denom is not None:
            weights = np.divide(raw, denom, out=np.zeros_like(raw),
                                where=denom > 0)
        else:
            weights = raw

        distances = x
        if len(distances) > 2:                       # sumo interpolate_factor
            td = np.linspace(distances[0], distances[-1],
                             len(distances) * STACKED_INTERP)
            bands = interp1d(distances, bands, axis=1, bounds_error=False,
                             fill_value="extrapolate")(td)
            weights = interp1d(distances, weights, axis=2, bounds_error=False,
                               fill_value="extrapolate")(td)
            distances = td

        weights[weights < 0] = 0
        weights[weights < cutoff] = 0

        dd = list(distances) * len(bands)
        bb = bands.flatten()
        zorders = range(-len(weights), 0)
        for w, c, z in zip(weights, colours, zorders):
            ax.scatter(dd, bb, c=c, s=circle_size * w.flatten() ** 2,
                       lw=0, edgecolors="none", zorder=z, rasterized=True)


def _abs_fmt(v, _pos):
    """Tick formatter: show absolute magnitude (picklable; used by DOS x-axis)."""
    return f"{abs(v):g}"


def _annotate_gap(band_axes, segs, dist, gap):
    """Mark VBM and CBM on the band panels and, for a direct gap, draw a
    two-headed arrow between them labelled with the gap (2 decimals)."""
    if gap.get("metal"):
        return

    def _panel(ki):                                    # which sub-panel holds k?
        for ax, sl in zip(band_axes, segs):
            idx = range(*sl.indices(len(dist)))
            if ki in idx:
                return ax
        return band_axes[0]

    vx, vy = gap["vbm_k_dist"], gap["vbm"]
    cx, cy = gap["cbm_k_dist"], gap["cbm"]
    ax_v, ax_c = _panel(gap["vbm_k_idx"]), _panel(gap["cbm_k_idx"])

    for ax, xx, yy in ((ax_v, vx, vy), (ax_c, cx, cy)):
        ax.scatter([xx], [yy], s=64, marker="o", facecolors=EDGE_HALO,
                   edgecolors="none", zorder=6)
        ax.scatter([xx], [yy], s=30, marker="o", facecolors=EDGE_CORE,
                   edgecolors="none", zorder=7)

    def _side(ax, xx):                                 # keep small labels inboard
        lo, hi = ax.get_xlim()
        left = (xx - lo) < 0.5 * (hi - lo)
        return (5 if left else -5), ("left" if left else "right")
    halo = [pe.withStroke(linewidth=2.2, foreground="white")]
    dxv, hav = _side(ax_v, vx)
    dxc, hac = _side(ax_c, cx)
    tkw = dict(textcoords="offset points", fontsize=8, color="black",
               fontweight="bold", zorder=8, path_effects=halo)
    ax_v.annotate("VBM", (vx, vy), xytext=(dxv, -11), ha=hav, **tkw)
    ax_c.annotate("CBM", (cx, cy), xytext=(dxc, 7), ha=hac, **tkw)

    if gap["direct"] and ax_v is ax_c:
        ax_v.annotate("", (vx, cy), (vx, vy),
                      arrowprops=dict(arrowstyle="<->", color="k", lw=1.4),
                      zorder=7)
    else:                                              # indirect: dashed guides
        for ax, _xx, yy in ((ax_v, vx, vy), (ax_c, cx, cy)):
            ax.axhline(yy, color="0.5", ls=":", lw=0.7, zorder=2)

    kind = "direct" if gap["direct"] else "indirect"
    label = rf"$E_\mathrm{{g}}={gap['gap']:.2f}$ eV ({kind})"
    band_axes[0].text(0.97, 0.97, label, transform=band_axes[0].transAxes,
                      ha="right", va="top", fontsize=9, zorder=8,
                      bbox=dict(boxstyle="round,pad=0.3", fc="white", ec="0.6",
                                alpha=0.9))


def _apply_rcparams(font):
    """Set the shared matplotlib rcParams (fonts, ticks, legend) for every figure."""
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "Nimbus Roman",
                       "Liberation Serif", "DejaVu Serif"],
        "mathtext.fontset": "stix",
        "font.size": 11, "axes.linewidth": 1.0, "axes.labelsize": 13,
        "xtick.direction": "in", "ytick.direction": "in",
        "xtick.major.size": 4, "ytick.major.size": 4,
        "xtick.labelsize": 12, "ytick.labelsize": 11,
        "legend.frameon": True, "legend.framealpha": 0.92, "legend.fontsize": 9,
    })


def build_figure(bands_data, dos_data, groups, cfg, spins, show_both, gap=None,
                 spin_note=None, overlay_plain=False):
    """Assemble the figure. Returns (fig, {'bands': [axes...], 'dos': axes}).

    Every normal figure now draws a SINGLE spin channel (no in-figure overlay of
    the two channels). `overlay_plain=True` is the one exception: the dedicated
    two-colour plain plot for --spin both, with spin-up bands in blue and
    spin-down in orange (plus a mirrored, blue/orange total DOS).

    `spin_note` (e.g. r"\\uparrow") is appended to the title.
    """
    method = "plain" if overlay_plain else getattr(cfg, "method", DEFAULT_METHOD)
    # show_both mirrors the DOS (up positive, down negative); it is only ever
    # True for the overlaid plain plot now.
    show_both = bool(show_both or overlay_plain)

    def sign(sp):
        return -1.0 if (show_both and sp == Spin.down) else 1.0

    def lsty(sp):
        return "solid"                               # single-spin lines are solid

    overlay_cols = {Spin.up: OVERLAY_UP_COLOR, Spin.down: OVERLAY_DOWN_COLOR}

    _apply_rcparams(cfg.font)

    dist = bands_data["distance"]
    segs = bands_data["segments"]
    n_seg = len(segs)
    seg_len = []
    for sl in segs:
        xs = dist[sl]
        seg_len.append(max(float(xs[-1] - xs[0]) if len(xs) > 1 else 0.0, 1e-6))

    fig = plt.figure(figsize=(cfg.figw, cfg.figh))
    outer = fig.add_gridspec(1, 2, width_ratios=list(WIDTH_RATIOS), wspace=0.05,
                             left=0.095, right=0.99, top=0.92, bottom=0.11)
    band_gs = outer[0].subgridspec(1, n_seg, width_ratios=seg_len,
                                   wspace=SEG_WSPACE)
    band_axes = []
    for j in range(n_seg):
        ax = fig.add_subplot(band_gs[0, j],
                             sharey=band_axes[0] if band_axes else None)
        band_axes.append(ax)
    axd = fig.add_subplot(outer[1], sharey=band_axes[0])

    band_w = {g["plain"]: band_weights(g, bands_data) for g in groups}
    w_tot = state_total_weight(bands_data)
    proj_dos = {g["plain"]: dos_projection(g, dos_data) for g in groups}
    ef_kw = dict(color="k", ls=(0, (6, 4)), lw=0.9, zorder=0)

    n_target = int(getattr(cfg, "markers", MARKER_TARGET) or 0)
    if n_target > 0:
        total_len = float(dist[-1] - dist[0]) if len(dist) > 1 else 1.0
        spacing = total_len / max(n_target, 1)
    else:
        spacing = 0.0                                 # keep every k-point

    # ---- LEFT: one sub-panel per continuous k-path segment ----
    for j, (ax, sl) in enumerate(zip(band_axes, segs)):
        if overlay_plain:
            _draw_overlay_plain(ax, bands_data, sl, cfg)
        else:
            _draw_segment(ax, bands_data, groups, band_w, w_tot, sl, spins, cfg,
                          lsty, spacing)
        ax.axhline(0.0, **ef_kw)
        xs = dist[sl]
        ax.set_xlim(xs[0], xs[-1])
        ticks = _segment_ticks(dist, bands_data["kpoint_labels"], sl)
        for d, _l in ticks:
            ax.axvline(d, color="0.5", lw=0.6, zorder=0)
        ax.set_xticks([d for d, _l in ticks])
        ax.set_xticklabels([format_kpt_label(l) for _d, l in ticks],
                           fontsize=KPT_LABEL_SIZE)
        ax.tick_params(axis="x", top=True, bottom=True)
        if j == 0:
            ax.set_ylabel(r"$E - E_\mathrm{F}$ (eV)")
            ax.tick_params(axis="y", left=True, right=False, labelleft=True)
        else:
            ax.tick_params(axis="y", left=False, right=False, labelleft=False)
    band_axes[0].set_ylim(cfg.emin, cfg.emax)

    if gap is not None:
        _annotate_gap(band_axes, segs, dist, gap)

    # ---- RIGHT: filled total DOS + selected-group curves ----
    E = dos_data["energies"]
    mask = (E >= cfg.emin - 1.0) & (E <= cfg.emax + 1.0)
    Em = E[mask]

    def prep(arr):
        return _smear(E, arr, cfg.smear)[mask]

    xmax = 0.0
    dos_spins = [Spin.up, Spin.down] if overlay_plain else spins
    for sp in dos_spins:
        tot = dos_data["total"].get(sp)
        if tot is None:
            continue
        y = sign(sp) * prep(tot)
        if overlay_plain:                            # blue (up) / orange (down)
            axd.fill_betweenx(Em, 0.0, y, color=overlay_cols[sp], alpha=0.16,
                              lw=0, zorder=1)
            axd.plot(y, Em, color=overlay_cols[sp], lw=DOS_TOTAL_LW, zorder=2)
        else:
            axd.fill_betweenx(Em, 0.0, y, color="0.86", lw=0, zorder=1)
            axd.plot(y, Em, color="0.55", lw=DOS_TOTAL_LW, zorder=2)
        xmax = max(xmax, np.abs(y).max() if y.size else 0.0)
    for g in ([] if overlay_plain else groups):       # overlay plain: no projections
        pj = proj_dos[g["plain"]]
        if pj is None:
            continue
        for sp in spins:
            dens = pj.get(sp)
            if dens is None:
                continue
            y = sign(sp) * prep(dens)
            axd.plot(y, Em, color=g["color"], lw=DOS_LW, ls=lsty(sp), zorder=3)
            xmax = max(xmax, np.abs(y).max() if y.size else 0.0)

    axd.axhline(0.0, **ef_kw)
    xmax = xmax or 1.0
    if show_both:
        axd.axvline(0.0, color="0.5", lw=0.6, zorder=0)
        axd.set_xlim(-1.06 * xmax, 1.06 * xmax)
    else:
        axd.set_xlim(0.0, 1.06 * xmax)
    axd.set_xlabel("DOS (states/eV/unit cell)")
    axd.xaxis.set_major_locator(MaxNLocator(nbins=4, prune="both",
                                            steps=[1, 2, 2.5, 5, 10]))
    axd.xaxis.set_major_formatter(FuncFormatter(_abs_fmt))
    axd.tick_params(axis="x", which="both", bottom=True, top=True,
                    direction="in", labelbottom=True)
    axd.tick_params(axis="y", left=True, right=True, labelleft=False)

    # ---- legend ----
    legend_marker = MARKER

    def group_handle(color, label):
        return Line2D([0], [0], color="none", marker=legend_marker,
                      markerfacecolor=color, markeredgecolor="none",
                      markersize=8, label=label)

    if overlay_plain:                                 # two-colour plain overlay
        handles = [
            group_handle(OVERLAY_UP_COLOR, r"spin $\uparrow$"),
            group_handle(OVERLAY_DOWN_COLOR, r"spin $\downarrow$"),
        ]
    else:
        handles = [Line2D([0], [0], color="0.55", lw=2.0, label="total")]
        if method == "plain":
            if bands_data.get("w90"):
                handles.append(Line2D([0], [0], color=W90_BAND_COLOR,
                                      lw=W90_BAND_LW, label="Wannier interp."))
            else:
                handles.append(Line2D([0], [0], color="none", marker=legend_marker,
                                      markerfacecolor=PLAIN_MARKER_COLOR,
                                      markeredgecolor="none", markersize=7,
                                      label="k-points"))
        for g in groups:                              # each group in its colour
            handles.append(group_handle(g["color"], g["label"]))
        # single-spin figure: note which channel is shown (ISPIN=2 only)
        if bands_data["is_spin"] and method != "stacked":
            arrow = r"\uparrow" if spins == [Spin.up] else r"\downarrow"
            handles.append(Line2D([0], [0], color="none",
                                  label=r"spin $%s$" % arrow))
    axd.legend(handles=handles, loc="upper right", borderaxespad=0.4,
               handlelength=1.6, labelspacing=0.3)

    if cfg.show_title:
        _st = bands_data.get("structure")
        ttl = (mathify_title(cfg.title) if cfg.title else
               (_auto_formula_tex(_st.composition.reduced_formula)
                if _st is not None else "Band structure and DOS"))
        if spin_note:
            ttl = f"{ttl}  $({spin_note})$"
        fig.suptitle(ttl, y=0.985, fontsize=14)
    elif spin_note:
        fig.suptitle(f"$({spin_note})$", y=0.985, fontsize=12)

    return fig, {"bands": band_axes, "dos": axd}


# --------------------------------------------------------------------------- #
# Standalone figures -- one calculation folder, one physical quantity
# --------------------------------------------------------------------------- #
# build_figure() above always pairs bands with a DOS side-panel, which is what a
# full Scf/Bands/Dos workflow produces.  When the plotter is pointed at a bare
# calculation folder only ONE of the two exists, so these two builders draw it
# on its own.  They reuse the same weights, colours and group machinery, so a
# standalone panel is identical to its counterpart inside the combined figure --
# except that a standalone DOS is drawn the conventional way round, with energy
# on the x-axis.
# --------------------------------------------------------------------------- #
def build_dos_figure(dos_data, groups, cfg, spins, show_both=False,
                     spin_note=None, structure=None):
    """Standalone density of states: energy on x, DOS on y.

    Returns (fig, {'dos': ax}).  `groups` may be empty (method='plain'), in
    which case only the filled total DOS is drawn.
    """
    _apply_rcparams(cfg.font)
    show_both = bool(show_both)

    def sign(sp):
        return -1.0 if (show_both and sp == Spin.down) else 1.0

    fig = plt.figure(figsize=(cfg.figw, cfg.figh))
    ax = fig.add_subplot(111)

    E = dos_data["energies"]
    mask = (E >= cfg.emin - 1.0) & (E <= cfg.emax + 1.0)
    Em = E[mask]

    def prep(arr):
        return _smear(E, arr, cfg.smear)[mask]

    proj_dos = {g["plain"]: dos_projection(g, dos_data) for g in groups}
    ymax = 0.0

    # total DOS: filled grey, mirrored when both spins are shown
    dos_spins = [Spin.up, Spin.down] if show_both else spins
    for sp in dos_spins:
        tot = dos_data["total"].get(sp)
        if tot is None:
            continue
        y = sign(sp) * prep(tot)
        col = ({Spin.up: OVERLAY_UP_COLOR, Spin.down: OVERLAY_DOWN_COLOR}[sp]
               if show_both else "0.55")
        fillc = col if show_both else "0.86"
        ax.fill_between(Em, 0.0, y, color=fillc, alpha=0.16 if show_both else 1.0,
                        lw=0, zorder=1)
        ax.plot(Em, y, color=col, lw=DOS_TOTAL_LW, zorder=2)
        ymax = max(ymax, np.abs(y).max() if y.size else 0.0)

    # projected group curves in their channel colours
    for g in groups:
        pj = proj_dos[g["plain"]]
        if pj is None:
            continue
        for sp in spins:
            dens = pj.get(sp)
            if dens is None:
                continue
            y = sign(sp) * prep(dens)
            ax.plot(Em, y, color=g["color"], lw=DOS_LW, zorder=3)
            ymax = max(ymax, np.abs(y).max() if y.size else 0.0)

    ymax = ymax or 1.0
    ax.axvline(0.0, color="k", ls=(0, (6, 4)), lw=0.9, zorder=0)   # E_F
    if show_both:
        ax.axhline(0.0, color="0.5", lw=0.6, zorder=0)
        ax.set_ylim(-1.06 * ymax, 1.06 * ymax)
    else:
        ax.set_ylim(0.0, 1.06 * ymax)
    ax.set_xlim(cfg.emin, cfg.emax)
    ax.set_xlabel(r"$E - E_\mathrm{F}$ (eV)")
    ax.set_ylabel("DOS (states/eV/unit cell)")
    ax.yaxis.set_major_formatter(FuncFormatter(_abs_fmt))
    ax.tick_params(axis="both", which="both", direction="in",
                   top=True, right=True)

    handles = [Line2D([0], [0], color="0.55", lw=2.0, label="total")]
    if show_both:
        handles = [
            Line2D([0], [0], color=OVERLAY_UP_COLOR, lw=2.0, label=r"spin $\uparrow$"),
            Line2D([0], [0], color=OVERLAY_DOWN_COLOR, lw=2.0, label=r"spin $\downarrow$"),
        ]
    for g in groups:
        handles.append(Line2D([0], [0], color=g["color"], lw=2.0, label=g["label"]))
    if handles:
        ax.legend(handles=handles, loc="upper right", borderaxespad=0.4,
                  handlelength=1.6, labelspacing=0.3)

    if cfg.show_title:
        ttl = mathify_title(cfg.title) if cfg.title else (
            _auto_formula_tex(structure.composition.reduced_formula)
            if structure is not None else "Density of states")
        if spin_note:
            ttl = f"{ttl}  $({spin_note})$"
        fig.suptitle(ttl, y=0.985, fontsize=14)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    return fig, {"dos": ax}


def build_bands_figure(bands_data, groups, cfg, spins, gap=None,
                       spin_note=None, overlay_plain=False):
    """Standalone band structure (no DOS side-panel).

    Same segment panels, markers and gap annotation as the left half of
    build_figure(), stretched across the full figure width.
    """
    method = "plain" if overlay_plain else getattr(cfg, "method", DEFAULT_METHOD)
    _apply_rcparams(cfg.font)

    def lsty(sp):
        return "solid"

    dist = bands_data["distance"]
    segs = bands_data["segments"]
    n_seg = len(segs)
    seg_len = []
    for sl in segs:
        xs = dist[sl]
        seg_len.append(max(float(xs[-1] - xs[0]) if len(xs) > 1 else 0.0, 1e-6))

    fig = plt.figure(figsize=(cfg.figw, cfg.figh))
    gs = fig.add_gridspec(1, n_seg, width_ratios=seg_len, wspace=SEG_WSPACE,
                          left=0.095, right=0.985, top=0.92, bottom=0.11)
    band_axes = []
    for j in range(n_seg):
        band_axes.append(fig.add_subplot(gs[0, j],
                                         sharey=band_axes[0] if band_axes else None))

    band_w = {g["plain"]: band_weights(g, bands_data) for g in groups}
    w_tot = state_total_weight(bands_data)
    ef_kw = dict(color="k", ls=(0, (6, 4)), lw=0.9, zorder=0)

    n_target = int(getattr(cfg, "markers", MARKER_TARGET) or 0)
    if n_target > 0:
        total_len = float(dist[-1] - dist[0]) if len(dist) > 1 else 1.0
        spacing = total_len / max(n_target, 1)
    else:
        spacing = 0.0

    for j, (ax, sl) in enumerate(zip(band_axes, segs)):
        if overlay_plain:
            _draw_overlay_plain(ax, bands_data, sl, cfg)
        else:
            _draw_segment(ax, bands_data, groups, band_w, w_tot, sl, spins, cfg,
                          lsty, spacing)
        ax.axhline(0.0, **ef_kw)
        xs = dist[sl]
        ax.set_xlim(xs[0], xs[-1])
        ticks = _segment_ticks(dist, bands_data["kpoint_labels"], sl)
        for d, _l in ticks:
            ax.axvline(d, color="0.5", lw=0.6, zorder=0)
        ax.set_xticks([d for d, _l in ticks])
        ax.set_xticklabels([format_kpt_label(l) for _d, l in ticks],
                           fontsize=KPT_LABEL_SIZE)
        ax.tick_params(axis="x", top=True, bottom=True)
        if j == 0:
            ax.set_ylabel(r"$E - E_\mathrm{F}$ (eV)")
            ax.tick_params(axis="y", left=True, right=False, labelleft=True)
        else:
            ax.tick_params(axis="y", left=False, right=False, labelleft=False)
    band_axes[0].set_ylim(cfg.emin, cfg.emax)

    if gap is not None:
        _annotate_gap(band_axes, segs, dist, gap)

    # legend on the last panel (no DOS axis to hang it on)
    handles = []
    if overlay_plain:
        handles = [
            Line2D([0], [0], color="none", marker=MARKER,
                   markerfacecolor=OVERLAY_UP_COLOR, markeredgecolor="none",
                   markersize=8, label=r"spin $\uparrow$"),
            Line2D([0], [0], color="none", marker=MARKER,
                   markerfacecolor=OVERLAY_DOWN_COLOR, markeredgecolor="none",
                   markersize=8, label=r"spin $\downarrow$"),
        ]
    else:
        if method == "plain":
            if bands_data.get("w90"):
                handles.append(Line2D([0], [0], color=W90_BAND_COLOR,
                                      lw=W90_BAND_LW, label="Wannier interp."))
            else:
                handles.append(Line2D([0], [0], color="none", marker=MARKER,
                                      markerfacecolor=PLAIN_MARKER_COLOR,
                                      markeredgecolor="none", markersize=7,
                                      label="k-points"))
        for g in groups:
            handles.append(Line2D([0], [0], color="none", marker=MARKER,
                                  markerfacecolor=g["color"],
                                  markeredgecolor="none", markersize=8,
                                  label=g["label"]))
        if bands_data["is_spin"] and method != "stacked":
            arrow = r"\uparrow" if spins == [Spin.up] else r"\downarrow"
            handles.append(Line2D([0], [0], color="none", label=r"spin $%s$" % arrow))
    if handles:
        band_axes[-1].legend(handles=handles, loc="upper right",
                             borderaxespad=0.4, handlelength=1.6,
                             labelspacing=0.3)

    if cfg.show_title:
        _st = bands_data.get("structure")
        ttl = (mathify_title(cfg.title) if cfg.title else
               (_auto_formula_tex(_st.composition.reduced_formula)
                if _st is not None else "Band structure"))
        if spin_note:
            ttl = f"{ttl}  $({spin_note})$"
        fig.suptitle(ttl, y=0.985, fontsize=14)
    elif spin_note:
        fig.suptitle(f"$({spin_note})$", y=0.985, fontsize=12)

    return fig, {"bands": band_axes}
