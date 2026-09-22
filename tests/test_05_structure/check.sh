#!/usr/bin/env bash
# wolfpack-structure: what a relaxation did to the cell. Every expectation here
# is a deformation we INJECTED, so the right answer is known exactly rather
# than read off a previous run of the same code.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/structure"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1

S="$TK_DIR/wolfpack_structure.py"

# --- 1. a known uniform strain ---------------------------------------------
# Scale every lattice vector by 1.01. The Green-Lagrange strain of a uniform
# stretch by f is (f^2-1)/2 = 1.005% for f=1.01 -- NOT 1.000%. Quoting the
# engineering strain here would be a silent 0.5% error, so the expected value
# is computed, not typed.
cp "$CASES/Si/POSCAR" POSCAR
"$WP_PY" - "$PWD" <<'PY'
from pymatgen.core import Structure
from pymatgen.io.vasp import Poscar
import sys, os
os.chdir(sys.argv[1])
s = Structure.from_file("POSCAR")
t = s.copy(); t.scale_lattice(s.lattice.volume * 1.01**3)
Poscar(t).write_file("CONTCAR")
PY
want=$("$WP_PY" -c "print(f'{((1.01**2-1)/2)*100:.3f}')")
out=$("$WP_PY" "$S" POSCAR CONTCAR 2>&1)
# Anchor on the strain line. A bare "first percentage in the output" picks up
# the lattice-parameter change (+1.000 %), which for a uniform stretch is a
# DIFFERENT number from the Green-Lagrange strain (1.005 %) -- close enough to
# look right and wrong enough to hide a broken strain tensor.
got=$(grep -oP 'max \|strain\|\s*:\s*\K[0-9.]+' <<<"$out" | head -1)
near "${got:-}" "$want" 0.02 "a 1% uniform stretch is reported as Green-Lagrange strain"

# --- 2. a pure ROTATION is not a strain ------------------------------------
# The single most common way a strain measure is wrong: it picks up rigid
# rotations. Rotate the cell by 30 degrees about z and change nothing else.
# Any measure worth printing returns zero.
"$WP_PY" - "$PWD" <<'PY'
import sys, os
os.chdir(sys.argv[1])
from pymatgen.core import Structure, Lattice
from pymatgen.io.vasp import Poscar
import numpy as np
s = Structure.from_file("POSCAR")
th = np.radians(30.0)
R = np.array([[np.cos(th), -np.sin(th), 0], [np.sin(th), np.cos(th), 0], [0, 0, 1]])
rot = Structure(Lattice(s.lattice.matrix @ R.T), s.species, s.frac_coords)
Poscar(rot).write_file("CONTCAR_rot")
PY
out=$("$WP_PY" "$S" POSCAR CONTCAR_rot 2>&1)
got=$(grep -oP 'max \|strain\|\s*:\s*\K[0-9.]+' <<<"$out" | head -1)
near "${got:-0}" 0.0 0.01 "a pure 30-degree rotation registers as ZERO strain"

# --- 3. a displaced atom is seen -------------------------------------------
"$WP_PY" - "$PWD" <<'PY'
import sys, os
os.chdir(sys.argv[1])
from pymatgen.core import Structure
from pymatgen.io.vasp import Poscar
s = Structure.from_file("POSCAR")
s.translate_sites([1], [0.02, 0.0, 0.0], frac_coords=True)
Poscar(s).write_file("CONTCAR_disp")
PY
out=$("$WP_PY" "$S" POSCAR CONTCAR_disp 2>&1)
grep -qiE "displac" <<<"$out" \
    && pass "a displaced atom is reported" \
    || fail "a 0.02-fractional displacement went unreported"

# --- 4. the adversarial half ------------------------------------------------
must_refuse "a missing file is refused, not assumed empty" "no such|not found|cannot|missing" \
    "$WP_PY" "$S" POSCAR NOPE_CONTCAR
printf 'this is not a structure\n' > JUNK
must_refuse "a file that is not a structure is refused" "." \
    "$WP_PY" "$S" JUNK
# Two structures with DIFFERENT atom counts cannot be compared site by site.
# Reporting a displacement between them would be meaningless.
"$WP_PY" - "$PWD" <<'PY'
import sys, os
os.chdir(sys.argv[1])
from pymatgen.core import Structure
from pymatgen.io.vasp import Poscar
s = Structure.from_file("POSCAR"); s.make_supercell([2,1,1])
Poscar(s).write_file("CONTCAR_big")
PY
# It does not have to EXIT non-zero -- describing both cells is still useful --
# but it must not invent a site-by-site comparison between cells that have
# different numbers of sites.
out=$("$WP_PY" "$S" POSCAR CONTCAR_big 2>&1)
if grep -qiE "cannot compare|different|mismatch" <<<"$out"; then
    grep -qiE "displacement" <<<"$out" \
        && fail "it says it cannot compare, then reports displacements anyway" \
        || pass "cells with different site counts: says so, reports no displacements"
else
    fail "2 sites vs 4 were compared site-by-site without a word"
fi
exit $(( FAIL_N > 0 ))
