#!/usr/bin/env bash
# build-supercell: pure arithmetic, so it can be checked exactly rather than
# approximately. Every expectation below is derived, not copied from a run.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/supercell"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

_probe(){ # _probe CASE "args..."  -> prints "nsites volume a b c"
    cp "$CASES/$1/POSCAR" POSCAR
    "$WP_PY" "$TK_DIR/build_supercell.py" POSCAR $2 -o SPOSCAR >build.log 2>&1 || { echo FAIL; return; }
    "$WP_PY" -c "
from pymatgen.core import Structure
s=Structure.from_file('SPOSCAR'); l=s.lattice
print(len(s), f'{l.volume:.4f}', f'{l.a:.4f}', f'{l.b:.4f}', f'{l.c:.4f}')"
}

# --- a diagonal supercell multiplies sites and volume exactly ---------------
read -r n v a b c <<<"$(_probe Si '-s 2 2 2')"
ok_if "[[ '$n' == '16' ]]" "Si 2x2x2: 2 sites -> 16 (x8)"
ref=$("$WP_PY" -c "
from pymatgen.core import Structure
s=Structure.from_file('$CASES/Si/POSCAR'); print(f'{s.lattice.volume*8:.4f}')")
ok_if "[[ '$v' == '$ref' ]]" "Si 2x2x2: volume is exactly 8x the primitive ($v)"

# --- an ANISOTROPIC cell must not be applied isotropically ------------------
# 1x1x3 on a cubic-ish cell: only c grows. A tool that quietly symmetrises the
# request would give 27x the volume instead of 3x.
read -r n v a b c <<<"$(_probe MgO '-s 1 1 3')"
ok_if "[[ '$n' == '6' ]]" "MgO 1x1x3: 2 sites -> 6 (x3, not x27)"
ref=$("$WP_PY" -c "
from pymatgen.core import Structure
s=Structure.from_file('$CASES/MgO/POSCAR'); print(f'{s.lattice.volume*3:.4f}')")
ok_if "[[ '$v' == '$ref' ]]" "MgO 1x1x3: volume is exactly 3x ($v)"

# --- 1x1x1 is the identity -------------------------------------------------
read -r n v a b c <<<"$(_probe Fe '-s 1 1 1')"
ok_if "[[ '$n' == '1' ]]" "Fe 1x1x1: the identity leaves 1 site"

# --- the adversarial half: inputs that must be REFUSED ----------------------
cp "$CASES/Si/POSCAR" POSCAR
must_refuse "a zero multiplier is refused" "positive|greater|invalid|must be" \
    "$WP_PY" "$TK_DIR/build_supercell.py" POSCAR -s 2 0 2 -o Z
must_refuse "a negative multiplier is refused" "positive|greater|invalid|must be" \
    "$WP_PY" "$TK_DIR/build_supercell.py" POSCAR -s 2 -1 2 -o N
must_refuse "a missing POSCAR is refused, by name" "no such file|not found|POSCAR|cannot" \
    "$WP_PY" "$TK_DIR/build_supercell.py" NOPE -s 2 2 2 -o M
printf 'not a poscar at all\n' > JUNK
must_refuse "a file that is not a POSCAR is refused" "." \
    "$WP_PY" "$TK_DIR/build_supercell.py" JUNK -s 2 2 2 -o J
exit $(( FAIL_N > 0 ))
