#!/usr/bin/env bash
###############################################################################
# vasp_quick_plots.sh   (invoked on PATH as: vasp-quick-plots)
#
# One fat-band/DOS figure per plotting method, in a single command, organised
# into numbered sub-folders under <root>/Plots/. For each method the most-
# important projections over the energy window are chosen automatically (by
# vasp-plot-fatbandsdos --auto-projections), so you get a quick, faithful
# overview without hand-picking orbitals:
#
#   0_Plain     no projection: pale-grey backbone + black k-point dots
#   1_ONE       one_orbital: the single most-contributing (element, dominant-l)
#   2_DUO       duo: the 2 most-contributing units
#   3_RGB       rgb: the 3 most-contributing units (red/green/blue)
#   4_CMYK      cmyk: the 4 most-contributing units (cyan/magenta/yellow/black)
#   5_Stacked   stacked: the 5 most-contributing units (sumo-style circles)
#
# SINGLE-CALCULATION FOLDERS
#   The Scf/ Bands/ Dos/ tree is not required.  Run this inside one calculation
#   and the kind is detected from the INCAR/KPOINTS (line-mode KPOINTS -> band
#   structure; regular mesh + tetrahedron/LORBIT/NEDOS -> DOS; Wannier90 output
#   -> interpolated curves).  Every method folder is then filled with only the
#   plots that folder can support, with the same automatic projections.
#
# "Most-contributing" is measured by the projected DOS integrated over the
# energy window [--emin, --emax] (a proper states integral, summed over spin).
# If the cell has fewer distinct elements than a method needs, selection falls
# back to inequivalent Wyckoff sites of the same element (Pt1-d, Pt2-d, ...),
# always in descending order of contribution.
#
# SPIN (ISPIN=2):
#   --spin both  -> EVERY folder gets separate spin-up and spin-down plots
#                   (e.g. rgb_up, rgb_down). The 0_Plain folder ALSO gets the
#                   overlaid blue/orange plain plot (rgb-blue = up, orange = down).
#   --spin up    -> every folder gets only the spin-up plot.
#   --spin down  -> every folder gets only the spin-down plot.
#   (ISPIN=1 calculations ignore --spin and write a single plot per folder.)
#
# USAGE
#   conda activate wolfpack-dft         # needs pymatgen/numpy/matplotlib/scipy
#   cd <root with Scf/ Bands/ Dos/>     # ... or into a single calculation folder
#   vasp-quick-plots                    # all methods, auto energy window
#   vasp-quick-plots --emin -6 --emax 6 --title "MoS_2"
#   vasp-quick-plots --methods plain,rgb,cmyk
#   vasp-quick-plots --root path/to/calc --stacked-n 6 --spin both
#   vasp-quick-plots --help
#
# OPTIONS
#   --root DIR        calculation root (default: .)
#   --emin/--emax EV  energy window (rel. E_F) for BOTH the view and the
#                     contribution ranking (default: auto-fit to the bands)
#   --title STR       figure title (TeX-ish, e.g. "MoS_2 - G_0W_0")
#   --methods LIST    comma list from: plain,one_orbital,duo,rgb,cmyk,stacked
#                     (default: all six)
#   --stacked-n N     how many units for the stacked plot (default: 5)
#   --spin {both,up,down}   spin channel(s) (default: both)
#   --formats LIST    output formats, e.g. png,pdf (default: png,pdf)
#   --group MODE      site grouping symmetry|formula|element (default: symmetry)
#   Any extra args after `--` are passed verbatim to vasp-plot-fatbandsdos.
###############################################################################
set -uo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,57p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
    exit 0
fi

c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
info() { printf '%s\n' "${c_bold}==>${c_rst} $*"; }
ok()   { printf '%s\n' "    ${c_grn}done${c_rst}  $*"; }
warn() { printf '%s\n' "    ${c_yel}WARN${c_rst} $*" >&2; }

# --------------------------------------------------------------------------- #
# Defaults + argument parsing
# --------------------------------------------------------------------------- #
ROOT="."
EMIN=""; EMAX=""; TITLE=""
METHODS="plain,one_orbital,duo,rgb,cmyk,stacked"
STACKED_N=5
SPIN="both"
FORMATS="png,pdf"
GROUP="symmetry"
EXTRA=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)       ROOT="${2:?}"; shift 2 ;;
        --emin)       EMIN="${2:?}"; shift 2 ;;
        --emax)       EMAX="${2:?}"; shift 2 ;;
        --title)      TITLE="${2:?}"; shift 2 ;;
        --methods)    METHODS="${2:?}"; shift 2 ;;
        --stacked-n)  STACKED_N="${2:?}"; shift 2 ;;
        --spin)       SPIN="${2:?}"; shift 2 ;;
        --formats)    FORMATS="${2:?}"; shift 2 ;;
        --group)      GROUP="${2:?}"; shift 2 ;;
        --)           shift; EXTRA=("$@"); break ;;
        *) warn "Unknown option: $1"; echo "Try: vasp-quick-plots --help" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------- #
# Locate the plotter (the master command, or the package file next to us)
# --------------------------------------------------------------------------- #
PLOT_CMD=()
for cand in "${VASP_PLOT:-}" \
            "$(command -v vasp-plot-fatbandsdos 2>/dev/null || true)" \
            "$HOME/.local/bin/vasp-plot-fatbandsdos"; do
    if [[ -n "$cand" && -x "$cand" ]]; then PLOT_CMD=("$cand"); break; fi
done
if [[ ${#PLOT_CMD[@]} -eq 0 ]]; then
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    here="$(dirname "$self")"
    if [[ -f "$here/vasp_plot_fatbandsdos.py" ]]; then
        PY="$(command -v python3 || command -v python || true)"
        [[ -n "$PY" ]] && PLOT_CMD=("$PY" "$here/vasp_plot_fatbandsdos.py")
    fi
fi
if [[ ${#PLOT_CMD[@]} -eq 0 ]]; then
    echo "ERROR: could not find vasp-plot-fatbandsdos (install the toolkit, or "  >&2
    echo "       set VASP_PLOT=/path/to/vasp_plot_fatbandsdos.py)."               >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# What is in this folder?  Either the classic Scf/ Bands/ Dos/ workflow tree
# (band structure + DOS in one figure) or a single calculation, whose kind is
# read off the INCAR/KPOINTS -- so running this inside a DOS run produces the
# DOS plots for every method, and inside a band run, the band plots.
# --------------------------------------------------------------------------- #
LAYOUT_KIND=""; LAYOUT_WHY=""
if [[ -d "$ROOT/Bands" && -d "$ROOT/Dos" ]]; then
    LAYOUT_KIND="both"; LAYOUT_WHY="workflow tree (Bands/ + Dos/ found)"
else
    self_qp="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    here_qp="$(dirname "$self_qp")"
    PY_QP="$(command -v python3 || command -v python || true)"
    if [[ -n "$PY_QP" && -f "$here_qp/wolfpack_plot/detect.py" ]]; then
        # Line 1 = "kind why"; any further lines are PHYSICS problems (wrong
        # recipe for the functional). They go on stdout, not stderr, precisely
        # because stderr is discarded here to hide import noise.
        LAYOUT_OUT="$(
            "$PY_QP" - "$here_qp" "$ROOT" <<'PYEOF' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "wp_detect", sys.argv[1] + "/wolfpack_plot/detect.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lay = m.detect_layout(sys.argv[2])
print(lay["kind"] or "none", lay["why"])
for p in lay.get("problems") or []:
    print("PROBLEM " + " ".join(p.split()))
PYEOF
        )"
        read -r LAYOUT_KIND LAYOUT_WHY <<<"$(printf '%s\n' "$LAYOUT_OUT" | head -n1)"
        LAYOUT_PROBLEMS="$(printf '%s\n' "$LAYOUT_OUT" | sed -n 's/^PROBLEM //p')"
    fi
fi
case "${LAYOUT_KIND:-}" in
    both)  ;;                                    # nothing to say: the normal case
    bands) info "single calculation: BAND STRUCTURE only (${LAYOUT_WHY})" ;;
    dos)   info "single calculation: DENSITY OF STATES only (${LAYOUT_WHY})" ;;
    wannier90) info "single calculation: WANNIER90 interpolation (${LAYOUT_WHY})" ;;
    *)     warn "no Scf/ Bands/ Dos/ tree here and this folder is not a"
           warn "recognisable VASP calculation — vasp-plot-fatbandsdos may fail." ;;
esac
# A wrong-functional recipe yields a figure that looks completely normal, so say
# it before any plotting starts rather than as a footnote afterwards.
if [[ -n ${LAYOUT_PROBLEMS:-} ]]; then
    while IFS= read -r _p; do
        [[ -z $_p ]] && continue
        warn "WRONG RECIPE: ${_p}"
    done <<<"$LAYOUT_PROBLEMS"
    warn "see https://vasp.at/wiki/index.php/Band-structure_calculation_using_meta-GGA_functionals"
fi

# Common args shared by every invocation.
COMMON=(--root "$ROOT" --spin "$SPIN" --formats "$FORMATS" --group "$GROUP")
[[ -n "$EMIN" ]] && COMMON+=(--emin "$EMIN")
[[ -n "$EMAX" ]] && COMMON+=(--emax "$EMAX")
[[ -n "$TITLE" ]] && COMMON+=(--title "$TITLE")
[[ ${#EXTRA[@]} -gt 0 ]] && COMMON+=("${EXTRA[@]}")

# method -> (units auto-picked, numbered output sub-folder). plain takes none.
declare -A NUNITS=( [plain]=0 [one_orbital]=1 [duo]=2 [rgb]=3 [cmyk]=4 [stacked]="$STACKED_N" )
declare -A SUBDIR=( [plain]=0_Plain [one_orbital]=1_ONE [duo]=2_DUO \
                    [rgb]=3_RGB [cmyk]=4_CMYK [stacked]=5_Stacked )

info "WolfPack-DFT quick plots"
echo "    root    : $ROOT"
echo "    window  : ${EMIN:-auto} .. ${EMAX:-auto} eV   (selection + view)"
echo "    methods : $METHODS"
echo "    spin    : $SPIN"
echo "    plotter : ${PLOT_CMD[*]}"
echo

# --------------------------------------------------------------------------- #
# One plot (set) per requested method, into its numbered sub-folder
# --------------------------------------------------------------------------- #
n_ok=0; n_fail=0
IFS=',' read -r -a METHOD_LIST <<< "$METHODS"
for raw in "${METHOD_LIST[@]}"; do
    m="$(echo "$raw" | tr 'A-Z -' 'a-z__' | sed 's/^ *//;s/ *$//')"
    [[ -z "$m" ]] && continue
    if [[ -z "${NUNITS[$m]+x}" ]]; then
        warn "unknown method '$raw' — skipping (valid: ${!NUNITS[*]})."
        continue
    fi
    args=("${COMMON[@]}" --method "$m" --subdir "${SUBDIR[$m]}" --name "$m")
    # --auto-projections ranks the projection groups by their weight in the
    # energy window, and it is the DOS that supplies that weight. A bands-only
    # folder has none, so passing the flag there guarantees a refusal: five of
    # the six figures were lost that way, in folders that plot perfectly well
    # without it (the plotter then uses one group per element, its documented
    # default). Say it once, not once per method.
    if [[ "${NUNITS[$m]}" -gt 0 ]]; then
        if [[ "${LAYOUT_KIND:-}" == "bands" ]]; then
            [[ -z "${_said_no_auto:-}" ]] && {
                info "no DOS here, so groups are not auto-ranked: one group per element"
                info "      (name them yourself with -- --projections \"...\")"
                _said_no_auto=1
            }
        else
            args+=(--auto-projections "${NUNITS[$m]}")
        fi
    fi
    # The overlaid blue/orange plain plot (for --spin both) belongs ONLY in
    # 0_Plain, so suppress it for every other method.
    [[ "$m" != "plain" ]] && args+=(--no-overlay-plain)

    info "[$m] -> Plots/${SUBDIR[$m]}/"
    if "${PLOT_CMD[@]}" "${args[@]}"; then
        ok "$ROOT/Plots/${SUBDIR[$m]}/"
        n_ok=$((n_ok + 1))
    else
        warn "$m plot failed (see message above) — continuing with the rest."
        n_fail=$((n_fail + 1))
    fi
    echo
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
info "Quick plots finished: ${c_grn}$n_ok ok${c_rst}, $([[ $n_fail -gt 0 ]] && echo "${c_red}$n_fail failed${c_rst}" || echo "0 failed")."
echo "    figures in: $ROOT/Plots/{0_Plain,1_ONE,2_DUO,3_RGB,4_CMYK,5_Stacked}/"
if [[ $n_fail -gt 0 ]]; then
    echo "    Tip: if everything failed with a ModuleNotFoundError, activate the env:"
    echo "         conda activate wolfpack-dft"
fi
[[ $n_ok -gt 0 ]]   # exit 0 if at least one plot succeeded
