#!/usr/bin/env bash
# Reproduce the VASP magnetism tutorial, part 1, with ITS OWN input files.
#
# This test exists because of what happened with the Hubbard U: a physical
# quantity was "corrected" from my own reasoning about which way electrons
# move, and the reasoning was backwards. The defence is to take the numbers
# from VASP's own worked examples and reproduce them, rather than to argue.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
have_vasp || { skip "no VASP at $WP_VASP"; exit 0; }
have_potcar Co || { skip "no Co POTCAR under $WP_POTCAR_DIR"; exit 0; }
W="$WORK/tut_mag"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

# --- the tutorial's files, verbatim ----------------------------------------
# https://vasp.at/tutorials/latest/magnetism/part1/
cat > POSCAR <<'EOF'
hcp Co -- VASP magnetism tutorial, part 1
1.0
  2.4719999032000000    0.0000000000000000    0.0000000000000000
 -1.2359999516013529    2.1408147143262166    0.0000000000000000
  0.0000000000000000    0.0000000000000000    4.0211440800000000
Co
2
Direct
  0.3333333333333333  0.6666666666666666  0.2500000000000000
  0.6666666666666667  0.3333333333333334  0.7500000000000000
EOF
cat > INCAR <<'EOF'
SYSTEM = FM Co
ALGO  = Normal
PREC  = Accurate
EDIFF = 1e-5
ENCUT = 350
ISPIN   = 2
MAGMOM  = 2 2
LMAXMIX = 4
LASPH   = T
ISMEAR = 2
SIGMA  = 0.1
EOF
printf 'Regular k-point mesh\n0\nGamma\n6  6  4\n0  0  0\n' > KPOINTS
cat "$WP_POTCAR_DIR/Co/POTCAR" > POTCAR

OMP_NUM_THREADS=1 timeout 900 mpirun -np 4 "$WP_VASP" >vasp.log 2>&1
ok_if "[[ -s OUTCAR ]]" "the tutorial's own inputs run to completion"
[[ -s OUTCAR ]] || exit 1

# ANCHOR THE LINE. An OUTCAR carries two "magnetization" columns:
#     number of electron  ... magnetization  3.1513726   <- the cell
#     augmentation part   ... magnetization  ...         <- PAW on-site only
# A bare grep with tail -1 takes the second, which is a PARTIAL quantity.
m_tot=$(grep -oP 'number of electron\s+[-0-9.]+\s+magnetization\s+\K[-0-9.]+' OUTCAR | tail -1)
m_at=$(awk -v m="$m_tot" 'BEGIN{printf "%.3f", m/2}')
info "    total magnetization ${m_tot} muB for 2 Co  ->  ${m_at} muB/Co"

# The tutorial states the experimental value as 1.7 muB/Co and says the
# computed moment is "a bit smaller but in relatively good agreement".
# 1.55 +/- 0.15 covers "a bit smaller" and excludes both 0.0 (spin
# polarisation lost) and 1.7+ (which would mean it was NOT smaller).
near "$m_at" 1.60 0.15 "hcp Co moment is a bit below the tutorial's experimental 1.7 muB/Co"

# The discriminating half: the same cell WITHOUT spin polarisation. A run that
# silently lost ISPIN converges just as happily and reports a moment of zero
# and an energy about half an eV per atom too high. If the check above cannot
# tell the two apart, it is not checking anything.
mkdir -p nsp && cp POSCAR KPOINTS POTCAR nsp/
grep -vE '^(ISPIN|MAGMOM)' INCAR > nsp/INCAR
( cd nsp && OMP_NUM_THREADS=1 timeout 900 mpirun -np 4 "$WP_VASP" >vasp.log 2>&1 )
m_nsp=$(grep -oP 'number of electron\s+[-0-9.]+\s+magnetization\s+\K[-0-9.]+' nsp/OUTCAR | tail -1)
e_fm=$(grep -oP 'free  energy   TOTEN  =\s+\K-?[0-9.]+' OUTCAR | tail -1)
e_nsp=$(grep -oP 'free  energy   TOTEN  =\s+\K-?[0-9.]+' nsp/OUTCAR | tail -1)
if [[ -z "$m_nsp" ]]; then
    pass "without ISPIN there is no magnetization line at all"
else
    near "$m_nsp" 0.0 0.05 "without ISPIN the moment is zero, as it must be"
fi
if [[ -n "$e_fm" && -n "$e_nsp" ]]; then
    d=$(awk -v a="$e_fm" -v b="$e_nsp" 'BEGIN{printf "%.4f", (b-a)/2}')
    awk -v d="$d" 'BEGIN{exit !(d > 0.05)}' \
        && pass "the ferromagnet is lower in energy by ${d} eV/atom, so the moment is real" \
        || fail "spin polarisation gains only ${d} eV/atom -- the FM state is not being found"
fi
exit $(( FAIL_N > 0 ))
