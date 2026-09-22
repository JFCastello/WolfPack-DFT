#!/usr/bin/env bash
# vasp-quick-plots. A figure that is merely ugly is a nuisance; a figure that
# is WRONG looks exactly like a right one, so what gets checked here is the
# NUMBER the figure prints, against a published value.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/plots"; rm -rf "$W"; mkdir -p "$W"
QP="$TK_DIR/vasp_quick_plots.sh"

# --- refusals that cost nothing to check -----------------------------------
mkdir -p "$W/bare"
must_refuse "a directory with no VASP output is refused, and says what it needs" \
    "nothing to plot|no .*calculation|vasprun|not a recognis" \
    bash -c "cd '$W/bare' && '$QP' </dev/null"

have_vasp || { skip "no VASP -- the figures go unchecked"; exit $(( FAIL_N > 0 )); }
have_potcar Si || { skip "no Si POTCAR -- the figures go unchecked"; exit $(( FAIL_N > 0 )); }

# --- one run carrying BOTH halves of the figure ----------------------------
# The mesh in KPOINTS drives self-consistency and makes the DOS; the path in
# KPOINTS_OPT is diagonalised afterwards in one shot. Both land in the same
# vasprun.xml, so one job gives bands AND DOS.
d="$W/si"; mkdir -p "$d"; cd "$d" || exit 1
cp "$CASES/Si/POSCAR" POSCAR
cat "$WP_POTCAR_DIR/Si/POTCAR" > POTCAR
printf 'mesh\n0\nGamma\n9 9 9\n0 0 0\n' > KPOINTS
cat > KPOINTS_OPT <<'EOF'
path L-G-X
20
line
reciprocal
  0.50000 0.50000 0.50000   1 ! L
  0.00000 0.00000 0.00000   1 ! \Gamma

  0.00000 0.00000 0.00000   1 ! \Gamma
  0.00000 0.50000 0.50000   1 ! X
EOF
cat > INCAR <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-6
ISMEAR = 0 ; SIGMA = 0.05
LORBIT = 11
NEDOS = 1001
LWAVE = .FALSE. ; LCHARG = .FALSE.
EOF
OMP_NUM_THREADS=1 timeout 900 mpirun -np 4 "$WP_VASP" >vasp.log 2>&1
ok_if "[[ -s vasprun.xml ]]" "the reference calculation finished"
[[ -s vasprun.xml ]] || exit $(( FAIL_N > 0 ))

out=$(timeout 900 bash "$QP" 2>&1); echo "$out" > plots.log
grep -qiE "traceback \(most recent" <<<"$out" \
    && fail "the plotter left a traceback" \
    || pass "the plotter left no traceback"

n=$(find Plots -name '*.png' 2>/dev/null | wc -l)
ok_if "[[ $n -ge 1 ]]" "figures were written ($n png)"

# Every figure must be a real image, not a zero-byte file or a blank canvas.
bad=0
while read -r f; do
    sz=$(stat -c%s "$f"); [[ "$sz" -lt 5000 ]] && { info "    $f is only $sz bytes"; bad=1; }
    head -c 8 "$f" | grep -q 'PNG' || { info "    $f is not a PNG"; bad=1; }
done < <(find Plots -name '*.png' 2>/dev/null)
ok_if "[[ $bad -eq 0 ]]" "every figure is a real, non-empty PNG"

# THE check: the gap the figure prints, against the published PBE value. A
# plotter reading the wrong eigenvalues still draws a perfectly pretty figure.
g=$("$WP_PY" -c "
from pymatgen.io.vasp.outputs import BSVasprun
v = BSVasprun('vasprun.xml', parse_projected_eigen=False)
bs = v.get_band_structure(kpoints_filename='KPOINTS_OPT', line_mode=True)
print(f\"{bs.get_band_gap()['energy']:.3f}\")" 2>/dev/null)
near "${g:-}" 0.6 0.25 "the band structure the plotter reads has Si's published PBE gap"
gp=$(grep -oP 'E_?g?\s*=\s*\K[0-9.]+' plots.log | head -1)
[[ -n "$gp" ]] && near "$gp" "${g:-0}" 0.05 "the gap PRINTED by the plotter matches the data" \
    || info "    (the plotter printed no gap to cross-check)"

# --- a bands-only folder: no DOS, no OUTCAR, still plots ------------------
# Deliberately stripped down to a vasprun.xml plus the inputs: no DOSCAR, no
# OUTCAR, KPOINTS replaced by the line-mode path. Everything the plotter needs
# is in that one file, and that is the point -- it is the folder a user is left
# with after copying a band run off a cluster.
#
# The first version of this check only grepped for a traceback, and PASSED
# while the plotter produced ZERO figures of six. "It did not crash" is not
# "it worked". Both are asserted now.
d2="$W/bands_only"; mkdir -p "$d2"
cp POSCAR POTCAR INCAR vasprun.xml "$d2/" 2>/dev/null
cp KPOINTS_OPT "$d2/KPOINTS"; rm -f "$d2/DOSCAR" "$d2/OUTCAR"
out=$(cd "$d2" && timeout 600 bash "$QP" 2>&1); echo "$out" > "$d2/plots.log"

# The Fermi level has to come out of the vasprun.xml. pymatgen only fills
# Vasprun.efermi while parsing the <dos> block, so reading it with
# parse_dos=False always returned None and this folder could not be plotted at
# all -- masked everywhere else by the OUTCAR fallback.
ef_bo=$("$WP_PY" -c "
import sys, warnings; warnings.filterwarnings('ignore'); sys.path.insert(0, '$TK_DIR')
from pathlib import Path
from wolfpack_plot.vaspio import read_fermi
print(f'{read_fermi(Path(\"$d2\")):.4f}')" 2>/dev/null)
ef_si=$("$WP_PY" -c "
import sys, warnings; warnings.filterwarnings('ignore'); sys.path.insert(0, '$TK_DIR')
from pathlib import Path
from wolfpack_plot.vaspio import read_fermi
print(f'{read_fermi(Path(\"$d\")):.4f}')" 2>/dev/null)
if [[ -n "$ef_bo" ]]; then
    near "$ef_bo" "${ef_si:-0}" 0.001 "E_F is read from the vasprun.xml alone, with no OUTCAR to fall back on"
else
    fail "the Fermi level could not be read from a folder holding only vasprun.xml"
fi

grep -qiE "traceback \(most recent" <<<"$out" \
    && fail "a bands-only folder crashes the plotter" \
    || pass "a bands-only folder does not crash the plotter"

n_bo=$(find "$d2/Plots" -name '*.png' -size +1k 2>/dev/null | wc -l)
ok_if "(( $n_bo >= 3 ))" "a bands-only folder really produces figures, not just an absence of tracebacks ($n_bo png)"

# --auto-projections ranks groups by their weight in the energy window, and
# there is no DOS here to rank them by. It used to reach into dos_data["cdos"]
# regardless and die with "'NoneType' object is not subscriptable". A refusal
# that says what to do instead is the correct behaviour; a traceback is not.
out_ap=$(cd "$d2" && timeout 300 "$WP_PY" "$TK_DIR/vasp_plot_fatbandsdos.py" \
         --method rgb --auto-projections 3 2>&1)
if grep -qiE "traceback \(most recent" <<<"$out_ap"; then
    fail "--auto-projections without a DOS still dies with a traceback"
elif grep -qiE "no DOS to rank|--projections" <<<"$out_ap"; then
    pass "--auto-projections without a DOS refuses, and says what to do instead"
else
    fail "--auto-projections without a DOS neither worked nor explained itself"
fi

exit $(( FAIL_N > 0 ))
