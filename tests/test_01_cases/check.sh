#!/usr/bin/env bash
# The benchmark structures themselves. If these are wrong every check that
# quotes a number is wrong with them, so they are verified FIRST -- against
# crystallography (space group, site count) and, where VASP is available,
# against the published PBE value by actually running it.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

"$WP_PY" "$CASES/make_cases.py" "$CASES" >"$WORK/cases.log" 2>&1 \
    || { fail "the cases do not build"; exit 1; }

# --- crystallography: what each cell MUST be -------------------------------
# site counts are not cosmetic. NiO AFM-II does not exist in a 2-atom cell:
# if the primitive cell came back with 2 sites the magnetic check below would
# be silently testing a different ordering than the one it names.
while read -r name sites sg; do
    got_s=$("$WP_PY" -c "
import json,sys
m=json.load(open('$CASES/manifest.json'))['$name']; print(m['sites'], m['spacegroup'])")
    read -r g_sites g_sg <<<"$got_s"
    [[ "$g_sites" == "$sites" && "$g_sg" == "$sg" ]] \
        && pass "$name: $sites sites, $sg" \
        || fail "$name: got $g_sites sites / $g_sg, expected $sites / $sg"
done <<'EOF'
Si 2 Fd-3m
Al 1 Fm-3m
MgO 2 Fm-3m
Fe 1 Im-3m
NiO 4 Fm-3m
EOF

# --- the physics, run for real ---------------------------------------------
have_vasp || { skip "no VASP at $WP_VASP -- the published values go unchecked"; exit 0; }

_run(){ # _run CASE NCORES <<INCAR ; echo KPOINTS-mesh
    local case="$1" np="$2" mesh="$3" pot="$4"
    local d="$WORK/cases/$case"; rm -rf "$d"; mkdir -p "$d"
    cp "$CASES/$case/POSCAR" "$d/"
    : > "$d/POTCAR"
    for e in $pot; do
        have_potcar "$e" || { echo "NOPOT:$e"; return 1; }
        cat "$WP_POTCAR_DIR/$e/POTCAR" >> "$d/POTCAR"
    done
    cat > "$d/INCAR"
    printf 'Auto\n0\nGamma\n%s\n0 0 0\n' "$mesh" > "$d/KPOINTS"
    ( cd "$d" && OMP_NUM_THREADS=1 timeout 600 mpirun -np "$np" "$WP_VASP" >vasp.log 2>&1 )
    echo "$d"
}

# Fe: the case that catches a lost ISPIN/MAGMOM. PBE gives 2.2 muB; a run that
# dropped spin polarisation gives 0.0 and looks perfectly healthy otherwise.
d=$(_run Fe 4 "15 15 15" "Fe" <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-6
ISMEAR = 1 ; SIGMA = 0.1
ISPIN = 2
MAGMOM = 1*3.0
LWAVE = .FALSE. ; LCHARG = .FALSE.
EOF
)
if [[ "$d" == NOPOT:* ]]; then
    skip "Fe: no ${d#NOPOT:} POTCAR"
else
    # ANCHOR THE LINE. An OUTCAR carries two "magnetization" columns:
    #     number of electron  7.9999991 magnetization  2.2410229   <- the cell
    #     augmentation part   4.1558809 magnetization  1.8498624   <- PAW on-site only
    # A bare grep with tail -1 takes the second, which is a PARTIAL quantity,
    # and reports 1.85 for a moment that is 2.24. This check was written that
    # way first and failed a perfectly good run.
    m=$(grep -oP 'number of electron\s+[-0-9.]+\s+magnetization\s+\K[-0-9.]+' \
        "$d/OUTCAR" | tail -1)
    near "${m:-}" 2.2 0.35 "Fe: bcc moment matches the published PBE value"
fi

# Si: the gap. An insulator whose gap comes out 0 means the eigenvalues were
# read from the wrong place or the smearing washed it out.
d=$(_run Si 4 "11 11 11" "Si" <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-6
ISMEAR = 0 ; SIGMA = 0.05
LORBIT = 11
LWAVE = .FALSE. ; LCHARG = .FALSE.
EOF
)
if [[ "$d" == NOPOT:* ]]; then
    skip "Si: no ${d#NOPOT:} POTCAR"
else
    g=$("$WP_PY" -c "
from pymatgen.io.vasp.outputs import Vasprun
v=Vasprun('$d/vasprun.xml', parse_potcar_file=False)
print(f\"{v.get_band_structure().get_band_gap()['energy']:.3f}\")" 2>/dev/null)
    near "${g:-}" 0.6 0.25 "Si: indirect gap matches the published PBE value"
fi

# Al: a metal. The same pipeline must NOT invent a gap here.
d=$(_run Al 4 "15 15 15" "Al" <<'EOF'
PREC = Accurate
ENCUT = 300
EDIFF = 1E-6
ISMEAR = 1 ; SIGMA = 0.2
LWAVE = .FALSE. ; LCHARG = .FALSE.
EOF
)
if [[ "$d" == NOPOT:* ]]; then
    skip "Al: no ${d#NOPOT:} POTCAR"
else
    g=$("$WP_PY" -c "
from pymatgen.io.vasp.outputs import Vasprun
v=Vasprun('$d/vasprun.xml', parse_potcar_file=False)
print(f\"{v.get_band_structure().get_band_gap()['energy']:.3f}\")" 2>/dev/null)
    near "${g:-}" 0.0 0.05 "Al: no gap, as a free-electron metal must have"
fi
exit $(( FAIL_N > 0 ))
