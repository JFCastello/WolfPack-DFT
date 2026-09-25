#!/usr/bin/env bash
# vasp-scf-loop's restart, checked the only way that settles it: run the SAME
# SCF twice -- once straight through, once cut in two with the restart the
# chain writes at a boundary -- and compare the energies. Chunking is a claim
# about physics ("this changes nothing"), and the claim is either true to the
# last decimal or it is not a feature.
#
# The relaxation's counterpart is test_33, which runs vasp-relax-loop itself
# against a direct relaxation.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
have_vasp || { skip "no VASP at $WP_VASP"; exit 0; }
have_potcar Si || { skip "no Si POTCAR"; exit 0; }
W="$WORK/chain_live"; rm -rf "$W"; mkdir -p "$W"

_setup(){ local d="$1" nelm="$2"; mkdir -p "$d"
    cp "$CASES/Si/POSCAR" "$d/POSCAR"
    cat "$WP_POTCAR_DIR/Si/POTCAR" > "$d/POTCAR"
    printf 'Auto\n0\nGamma\n6 6 6\n0 0 0\n' > "$d/KPOINTS"
    cat > "$d/INCAR" <<EOF
PREC   = Accurate
ENCUT  = 400
EDIFF  = 1E-6
ISMEAR = 0 ; SIGMA = 0.05
NSW    = 0
NELM   = $nelm
LWAVE  = .TRUE. ; LCHARG = .TRUE.
EOF
}

_run(){ ( cd "$1" && OMP_NUM_THREADS=1 timeout 900 mpirun -np 4 "$WP_VASP" >>vasp.log 2>&1 ); }
_energy(){ grep -oP 'F= *\K-?[0-9.E+]+' "$1/OSZICAR" 2>/dev/null | tail -1; }

# --- the reference: one run, straight through ------------------------------
_setup "$W/scf_direct" 40
_run "$W/scf_direct"
e_sd=$(_energy "$W/scf_direct")

# --- the same SCF, cut after 8 electronic steps ----------------------------
# The second half restarts with exactly the tags vasp-scf-loop writes at a
# warm boundary (vasp_chain.sh): ISTART = 1 (read the WAVECAR), ICHARG = 0
# (the density from those wavefunctions), NELMDL = 0 (no delay on a restart).
_setup "$W/scf_chunk" 8
_run "$W/scf_chunk"
n1=$(grep -cE '^(DAV|RMM):' "$W/scf_chunk/OSZICAR" 2>/dev/null)
sed -i -e 's/^NELM .*/NELM   = 40/' "$W/scf_chunk/INCAR"
printf 'ISTART = 1\nICHARG = 0\nNELMDL = 0\n' >> "$W/scf_chunk/INCAR"
mv "$W/scf_chunk/OSZICAR" "$W/scf_chunk/OSZICAR.1"
_run "$W/scf_chunk"
n2=$(grep -cE '^(DAV|RMM):' "$W/scf_chunk/OSZICAR" 2>/dev/null)
e_sc=$(_energy "$W/scf_chunk")
ok_if "[[ '${n1:-0}' -eq 8 && '${n2:-0}' -gt 0 ]]" "the SCF really was split (${n1:-0} then ${n2:-0} electronic steps)"

# --- the two answers must agree --------------------------------------------
if [[ -n "$e_sd" && -n "$e_sc" ]]; then
    d=$(awk -v a="$e_sd" -v b="$e_sc" 'BEGIN{x=a-b; printf "%.2e", (x<0?-x:x)}')
    awk -v d="$d" 'BEGIN{exit !(d < 1e-4)}' \
        && pass "chunked and direct SCF agree in energy (|dE| = $d eV)" \
        || fail "chunked and direct SCF DISAGREE: |dE| = $d eV"
    # A restart that silently started from scratch still converges to the same
    # energy, only in more steps. The control is the SAME restart, same tags,
    # with no WAVECAR to read -- not the direct run, whose 5 non-self-consistent
    # NELMDL steps a restart with NELMDL = 0 does not pay.
    mkdir -p "$W/scf_cold"
    cp "$W/scf_chunk"/{INCAR,KPOINTS,POSCAR,POTCAR} "$W/scf_cold/"
    _run "$W/scf_cold"
    nc=$(grep -cE '^(DAV|RMM):' "$W/scf_cold/OSZICAR" 2>/dev/null)
    ok_if "[[ '${nc:-0}' -gt 0 && $n2 -lt ${nc:-0} ]]" \
          "the restart used the WAVECAR: $n2 steps to converge, against ${nc:-?} for the same tags with no WAVECAR"
else
    fail "one of the SCF runs produced no energy (direct: ${e_sd:-none}, chunked: ${e_sc:-none})"
fi
exit $(( FAIL_N > 0 ))
