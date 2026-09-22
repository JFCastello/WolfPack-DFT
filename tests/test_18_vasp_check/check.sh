#!/usr/bin/env bash
# vasp-check: the post-mortem. It reads a finished run and says what it was and
# whether it converged.
#
# The point of testing it is that it makes CLAIMS about a calculation, and a
# post-mortem that mislabels a metal as an insulator -- or calls an unconverged
# run converged -- is worse than no post-mortem, because it is believed.
#
# Every case below is a real VASP run of a cell whose answer is known from
# ../test_01_cases (which checks those answers against published values).
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
VC="$TK_DIR/vasp_check.sh"
W="$WORK/vasp_check"; rm -rf "$W"; mkdir -p "$W"

# --- refusals ---------------------------------------------------------------
mkdir -p "$W/empty"
out=$(cd "$W/empty" && timeout 120 bash "$VC" 2>&1) || true
grep -qiE "traceback|syntax error" <<<"$out" \
    && fail "an empty directory crashes vasp-check" \
    || pass "an empty directory does not crash vasp-check"
grep -qiE "no |not found|missing|OUTCAR" <<<"$out" \
    && pass "an empty directory is reported as having nothing to check" \
    || fail "an empty directory produced a report anyway"

have_vasp || { skip "no VASP -- the post-mortem goes unchecked against real runs"; exit $(( FAIL_N > 0 )); }

_run(){ # _run NAME CASE POTS MESH <<INCAR
    local d="$W/$1"; mkdir -p "$d"
    cp "$CASES/$2/POSCAR" "$d/POSCAR"
    : > "$d/POTCAR"
    for e in $3; do
        have_potcar "$e" || { echo "NOPOT"; return; }
        cat "$WP_POTCAR_DIR/$e/POTCAR" >> "$d/POTCAR"
    done
    cat > "$d/INCAR"
    printf 'Auto\n0\nGamma\n%s\n0 0 0\n' "$4" > "$d/KPOINTS"
    ( cd "$d" && OMP_NUM_THREADS=1 timeout 900 mpirun -np 4 "$WP_VASP" >vasp.log 2>&1 )
    echo "$d"
}

# --- 1. an INSULATOR must be called an insulator ---------------------------
d=$(_run si Si "Si" "11 11 11" <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-6
ISMEAR = 0 ; SIGMA = 0.05
LORBIT = 11
EOF
)
if [[ "$d" == NOPOT ]]; then skip "no Si POTCAR"; else
    out=$(cd "$d" && timeout 300 bash "$VC" 2>&1); echo "$out" > "$d/check.log"
    grep -qiE "insulator|semiconductor" <<<"$out" \
        && pass "Si: reported as a semiconductor/insulator" \
        || fail "Si: not identified as gapped -- $(grep -iE 'metal|gap' <<<"$out" | head -1)"
    # The gap it prints must be the gap the run has: ~0.6 eV for Si in PBE.
    g=$(grep -oiP 'gap[^0-9]{0,24}\K[0-9]+\.[0-9]+' <<<"$out" | head -1)
    near "${g:-}" 0.6 0.25 "Si: the gap vasp-check prints matches the published PBE value"
    grep -qiE "converged|reached required accuracy|OK" <<<"$out" \
        && pass "Si: a converged run is reported as converged" \
        || fail "Si: a converged run was not reported as converged"
fi

# --- 2. a METAL must NOT be called an insulator ----------------------------
# The discriminating case. A post-mortem that finds a gap everywhere passes
# test 1 and fails here.
d=$(_run al Al "Al" "15 15 15" <<'EOF'
PREC = Accurate
ENCUT = 300
EDIFF = 1E-6
ISMEAR = 1 ; SIGMA = 0.2
LORBIT = 11
EOF
)
if [[ "$d" == NOPOT ]]; then skip "no Al POTCAR"; else
    out=$(cd "$d" && timeout 300 bash "$VC" 2>&1); echo "$out" > "$d/check.log"
    # It must SAY the system is metallic. The word "insulator" also appears in
    # an unrelated tip about ISMEAR ("for an insulator/DOS use ISMEAR=-5"), so
    # a bare grep for it fails a correct report -- this test did exactly that
    # at first.
    grep -qiE "metallic|partially-occupied" <<<"$out" \
        && pass "Al: the report says the system is metallic" \
        || fail "Al: a free-electron metal was not identified as one"

    # THE assertion. vasp-check reports a "fundamental gap" of about 0.03 eV
    # for aluminium -- which is the k-mesh, not a gap; pymatgen reads the same
    # run as 0.000 eV. The number is not wrong to print, but a reader who sees
    # only that line is misled, so the gap must not be reported WITHOUT the
    # metallic warning alongside it.
    gap_al=$(grep -oP 'fundamental gap \(VASP\):\s*\K[0-9.]+' <<<"$out" | head -1)
    if [[ -n "$gap_al" ]]; then
        info "    Al: vasp-check prints a gap of ${gap_al} eV (pymatgen reads 0.000)"
        awk -v g="$gap_al" 'BEGIN{exit !(g < 0.2)}' \
            && pass "Al: any gap it prints is below the smearing width, not a real gap" \
            || fail "Al: a gap of ${gap_al} eV was reported for a free-electron metal"
        grep -qiE "metallic|partially-occupied|fuzzy" <<<"$out" \
            && pass "Al: the metallic warning accompanies the gap number" \
            || fail "Al: a gap was reported for a metal with nothing saying it is metallic"
    else
        pass "Al: no fundamental gap is reported at all"
    fi
fi

# --- 3. a MAGNET must be seen as magnetic ----------------------------------
d=$(_run fe Fe "Fe" "15 15 15" <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-6
ISMEAR = 1 ; SIGMA = 0.1
ISPIN = 2
MAGMOM = 1*3.0
LORBIT = 11
EOF
)
if [[ "$d" == NOPOT ]]; then skip "no Fe POTCAR"; else
    out=$(cd "$d" && timeout 300 bash "$VC" 2>&1); echo "$out" > "$d/check.log"
    # "Magnetization" does not contain the string "magnetic". A grep for
    # "magnetic" failed a report that says `== Magnetization ==` and
    # `Net cell moment (uB)  2.2410` two lines later.
    grep -qiE "magneti[sz]ation|net cell moment|ferromagnet" <<<"$out" \
        && pass "Fe: the report has a magnetization section" \
        || fail "Fe: a ferromagnet produced no magnetization report"
    m=$(grep -oP 'Net cell moment \(uB\)\s*\K-?[0-9.]+' <<<"$out" | head -1)
    near "${m:-}" 2.2 0.4 "Fe: the moment vasp-check prints matches the published 2.2 muB"
fi

# --- 4. an UNCONVERGED run must not be called converged --------------------
# NELM = 2 cannot converge Si to EDIFF = 1E-8. The run completes, writes a
# perfectly normal OUTCAR, and is wrong. This is the case a post-mortem exists
# for, so it is the one it must not miss.
d=$(_run bad Si "Si" "11 11 11" <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-8
NELM = 2
ISMEAR = 0 ; SIGMA = 0.05
EOF
)
if [[ "$d" == NOPOT ]]; then skip "no Si POTCAR"; else
    out=$(cd "$d" && timeout 300 bash "$VC" 2>&1); echo "$out" > "$d/check.log"
    grep -qiE "NELM|not converge|unconverged|did not reach|exhaust" <<<"$out" \
        && pass "an SCF that ran out of NELM is reported as unconverged" \
        || fail "an SCF that hit NELM=2 was not flagged: this is what vasp-check is for"
fi
exit $(( FAIL_N > 0 ))
