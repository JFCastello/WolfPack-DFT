#!/usr/bin/env bash
# The chunking, checked the only way that settles it: run the SAME calculation
# twice -- once straight through, once cut into chunks -- and compare the
# answers. Chunking is a claim about physics ("this changes nothing"), and the
# claim is either true to the last decimal or it is not a feature.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
have_vasp || { skip "no VASP at $WP_VASP"; exit 0; }
have_potcar Si || { skip "no Si POTCAR"; exit 0; }
W="$WORK/chain_live"; rm -rf "$W"; mkdir -p "$W"

# A cell that has somewhere to relax TO: Si with one atom pushed off its site.
# A structure already at its minimum would agree trivially.
"$WP_PY" - "$CASES/Si/POSCAR" "$W/POSCAR" <<'PY'
import sys
from pymatgen.core import Structure
from pymatgen.io.vasp import Poscar
s = Structure.from_file(sys.argv[1])
s.translate_sites([1], [0.02, 0.01, 0.0], frac_coords=True)
Poscar(s).write_file(sys.argv[2])
PY

_setup(){ local d="$1" nsw="$2"; mkdir -p "$d"
    cp "$W/POSCAR" "$d/POSCAR"
    cat "$WP_POTCAR_DIR/Si/POTCAR" > "$d/POTCAR"
    printf 'Auto\n0\nGamma\n6 6 6\n0 0 0\n' > "$d/KPOINTS"
    cat > "$d/INCAR" <<EOF
PREC   = Accurate
ENCUT  = 400
EDIFF  = 1E-6
EDIFFG = -0.01
ISMEAR = 0 ; SIGMA = 0.05
IBRION = 2
ISIF   = 2
NSW    = $nsw
NELM   = 60
LWAVE  = .TRUE. ; LCHARG = .TRUE.
EOF
}

_run(){ ( cd "$1" && OMP_NUM_THREADS=1 timeout 900 mpirun -np 4 "$WP_VASP" >>vasp.log 2>&1 ); }

# --- the reference: one run, straight through ------------------------------
_setup "$W/direct" 12
_run "$W/direct"
e_direct=$(grep -oP 'F= *\K-?[0-9.E+]+' "$W/direct/OSZICAR" | tail -1)
ok_if "[[ -n '$e_direct' ]]" "the reference relaxation finished (E = ${e_direct:-?} eV)"
[[ -z "$e_direct" ]] && exit 1

# --- the same relaxation, cut in two ---------------------------------------
# Chunk 1 stops after 6 ionic steps; chunk 2 restarts from its CONTCAR and
# WAVECAR and finishes. This is what vasp-relax-loop does at each boundary,
# done by hand so the comparison isolates the RESTART from the scheduler.
_setup "$W/chunked" 6
_run "$W/chunked"
n1=$(grep -c 'F=' "$W/chunked/OSZICAR")
cp "$W/chunked/CONTCAR" "$W/chunked/POSCAR"
sed -i 's/^NSW .*/NSW    = 12/' "$W/chunked/INCAR"
printf 'ISTART = 1\nICHARG = 1\n' >> "$W/chunked/INCAR"
mv "$W/chunked/OSZICAR" "$W/chunked/OSZICAR.1"
_run "$W/chunked"
n2=$(grep -c 'F=' "$W/chunked/OSZICAR")
e_chunk=$(grep -oP 'F= *\K-?[0-9.E+]+' "$W/chunked/OSZICAR" | tail -1)
ok_if "[[ $n1 -gt 0 && $n2 -gt 0 ]]" "the relaxation really was split ($n1 then $n2 ionic steps)"

# --- the two answers must agree --------------------------------------------
de=$(awk -v a="$e_direct" -v b="$e_chunk" 'BEGIN{d=a-b; printf "%.2e", (d<0?-d:d)}')
awk -v d="$de" 'BEGIN{exit !(d < 1e-3)}' \
    && pass "chunked and direct relaxation agree in energy (|dE| = $de eV)" \
    || fail "chunked and direct relaxation DISAGREE: |dE| = $de eV"

dr=$("$WP_PY" - "$W/direct/CONTCAR" "$W/chunked/CONTCAR" <<'PY'
import sys
import numpy as np
from pymatgen.core import Structure
a = Structure.from_file(sys.argv[1]); b = Structure.from_file(sys.argv[2])
d = np.abs(a.cart_coords - b.cart_coords).max()
print(f"{d:.2e}")
PY
)
awk -v d="$dr" 'BEGIN{exit !(d < 5e-3)}' \
    && pass "chunked and direct relaxation agree in structure (max |dr| = $dr A)" \
    || fail "chunked and direct relaxation give DIFFERENT structures: max |dr| = $dr A"

# --- the same question for a static SCF ------------------------------------
# A static run chunks NELM instead of NSW; the restart object is the WAVECAR.
_setup "$W/scf_direct" 0; sed -i 's/^NELM .*/NELM   = 40/' "$W/scf_direct/INCAR"
_run "$W/scf_direct"
e_sd=$(grep -oP 'F= *\K-?[0-9.E+]+' "$W/scf_direct/OSZICAR" | tail -1)
_setup "$W/scf_chunk" 0; sed -i 's/^NELM .*/NELM   = 8/' "$W/scf_chunk/INCAR"
_run "$W/scf_chunk"
sed -i -e 's/^NELM .*/NELM   = 40/' "$W/scf_chunk/INCAR"
printf 'ISTART = 1\nICHARG = 1\nNELMDL = 0\n' >> "$W/scf_chunk/INCAR"
_run "$W/scf_chunk"
e_sc=$(grep -oP 'F= *\K-?[0-9.E+]+' "$W/scf_chunk/OSZICAR" | tail -1)
if [[ -n "$e_sd" && -n "$e_sc" ]]; then
    d=$(awk -v a="$e_sd" -v b="$e_sc" 'BEGIN{x=a-b; printf "%.2e", (x<0?-x:x)}')
    awk -v d="$d" 'BEGIN{exit !(d < 1e-4)}' \
        && pass "chunked and direct SCF agree in energy (|dE| = $d eV)" \
        || fail "chunked and direct SCF DISAGREE: |dE| = $d eV"
else
    fail "one of the SCF runs produced no energy"
fi
exit $(( FAIL_N > 0 ))
