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
got=$(grep -oP 'max \|strain\| \(%\)\s+\K[0-9.]+' <<<"$out" | head -1)
# 0.002, not 0.02: the engineering answer (1.000 %) must fall OUTSIDE the band,
# and 1.005 +/- 0.02 would have let it in.
near "${got:-}" "$want" 0.002 "a 1% uniform stretch is reported as Green-Lagrange strain"

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
got=$(grep -oP 'max \|strain\| \(%\)\s+\K[0-9.]+' <<<"$out" | head -1)
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

# --- 3b. data only, side by side ------------------------------------------
# The report states numbers; what they mean is the reader's call. It used to
# add verdicts ("<-- contracted", "symmetry FELL", notes on tolerances and on
# ISYM) that read as findings about the calculation.
ok_if "! grep -qiE 'contract|expand|fell|rose|note|warning|<--|approximately|probably' <<<\"\$out\"" \
      "the comparison is data only: no verdicts or interpretation in it"
ok_if "grep -qE '^  CELL +POSCAR +CONTCAR_disp +change +%\$' <<<\"\$out\" && [[ \$(grep -c 'a (A)' <<<\"\$out\") == 1 ]]" \
      "one side-by-side table (before, after, change, %), each quantity once"
out=$("$WP_PY" "$S" POSCAR CONTCAR_disp --labels=start,end 2>&1)
ok_if "grep -qE '^  CELL +start +end +change' <<<\"\$out\"" "--labels names the two columns"

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

# --- 5. vasp-check on a CHAINED relaxation: the whole one ------------------
# vasp-relax-loop runs each chunk in wolfpack_chain/NNN/ and never overwrites
# the folder's POSCAR; the latest CONTCAR is copied into the folder. So
# vasp-check's POSCAR -> CONTCAR is the whole relaxation, and it must not be
# the last chunk's -- whose number is SMALL, which is what "converged" looks
# like. The displacements are injected again.
VC="$TK_DIR/vasp_check.sh"
_si(){ # _si X -> a Si POSCAR with atom 2 at fractional x = X
    cat <<EOF
Si
   5.43000000000000
     0.0000000000000000    0.5000000000000000    0.5000000000000000
     0.5000000000000000    0.0000000000000000    0.5000000000000000
     0.5000000000000000    0.5000000000000000    0.0000000000000000
   Si
     2
Direct
  0.0000000000000000  0.0000000000000000  0.0000000000000000
  $1  0.2500000000000000  0.2500000000000000
EOF
}
# A folder that looks like a finished vasp-relax-loop chain:
#   the input            -> POSCAR, untouched                (x = 0.25)
#   chunk 3 started from -> wolfpack_chain/003/POSCAR        (x = 0.28)
#   where it ended       -> CONTCAR, the latest chunk's      (x = 0.29)
# The whole relaxation moved the atom 0.04; the last chunk moved it 0.01.
c="$W/chained"; mkdir -p "$c/wolfpack_chain"/{001,002,003}
_si 0.2500000000000000 > "$c/POSCAR"
_si 0.2900000000000000 > "$c/CONTCAR"
_si 0.2800000000000000 > "$c/wolfpack_chain/003/POSCAR"
cp "$c/CONTCAR" "$c/wolfpack_chain/003/CONTCAR"
printf 'chain_kind="relax"\nchain_state="converged"\n' > "$c/wolfpack_chain/chain.env"
cat > "$c/INCAR" <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-6
IBRION = 2
NSW = 20
ISIF = 2
EDIFFG = -0.01
ISMEAR = 0 ; SIGMA = 0.05
EOF
printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$c/KPOINTS"
cat > "$c/OSZICAR" <<'EOF'
       N       E                     dE             d eps       ncg     rms          rms(c)
DAV:   1    -0.107E+02   -0.10E+02   -0.29E+02   112   0.451E+01
   1 F= -.10820773E+02 E0= -.10820773E+02  d E =-.108208E+02
EOF
cat > "$c/OUTCAR" <<'EOF'
 vasp.6.5.1 08Feb24 (build Mar 01 2024 12:00:00) complex
   NSW    =     20    number of steps for IOM
   IBRION =      2    ionic relax: 0-MD 1-quasi-New 2-CG
   ISIF   =      2    stress and relaxation
   EDIFF  = 0.1E-05   stopping-criterion for ELM
   k-points           NKPTS =      8   k-points in BZ     NKDIM =      8   number of bands    NBANDS=      8
   number of dos      NEDOS =    301   number of ions     NIONS =      2

  POSITION                                       TOTAL-FORCE (eV/Angst)
 -----------------------------------------------------------------------------------
      0.00000      0.00000      0.00000         0.001000      0.000000      0.000000
      1.35750      1.35750      1.35750        -0.001000      0.000000      0.000000
 -----------------------------------------------------------------------------------
    total drift:                                0.000000      0.000000      0.000000

 reached required accuracy - stopping structural energy minimisation
                 Voluntary context switches:
 General timing and accounting informations for this job:
                  Total CPU time used (sec):       12.345
EOF
_dmax(){ awk '/ATOMIC DISPLACEMENTS/{f=1; next} f && /^[[:space:]]*all[[:space:]]/{print $3; exit}' <<<"$1"; }

out=$(cd "$c" && timeout 300 bash "$VC" 2>&1); echo "$out" > "$c/check.log"
ok_if "grep -q 'chained relaxation: POSCAR is the input, CONTCAR the latest of 3 completed chunk(s)' <<<\"\$out\"" \
      "vasp-check on a chain says what POSCAR and CONTCAR are"
# 0.04 fractional along x in this cell is 0.04 * 5.43 * sqrt(0.5) = 0.1536 A;
# the last chunk alone would be a quarter of that. The "all" row's first
# column is the max.
dmax=$(_dmax "$out")
if [[ -z "$dmax" ]]; then
    fail "vasp-check reported no displacement for the chain"
else
    near "$dmax" 0.1536 0.02 "vasp-check reports the WHOLE chain's displacement (0.04 frac), not the last chunk's (0.01)"
fi

# The same folder without the chain: the same heading, no note.
c2="$W/plain"; mkdir -p "$c2"
for f in INCAR KPOINTS OSZICAR OUTCAR CONTCAR POSCAR; do cp "$c/$f" "$c2/"; done
out2=$(cd "$c2" && timeout 300 bash "$VC" 2>&1)
ok_if "grep -q 'POSCAR -> CONTCAR' <<<\"\$out2\" && ! grep -q 'chained relaxation' <<<\"\$out2\"" \
      "an unchained relaxation: the same heading, no chain note"

# The control: literally what the last chunk moved (0.28 -> 0.29). If it came
# out 0.1536 too, the assertion above would be proving nothing.
c4="$W/lastchunk"; mkdir -p "$c4"
for f in INCAR KPOINTS OSZICAR OUTCAR CONTCAR; do cp "$c/$f" "$c4/"; done
_si 0.2800000000000000 > "$c4/POSCAR"
d4max=$(_dmax "$(cd "$c4" && timeout 300 bash "$VC" 2>&1)")
if [[ -z "$d4max" ]]; then
    fail "the control folder reported no displacement"
else
    near "$d4max" 0.0384 0.005 "the last chunk alone is a different number (0.01 frac), so the check above discriminates"
fi
exit $(( FAIL_N > 0 ))
