#!/usr/bin/env bash
# vasp-calculate-u: the linear-response Hubbard U of Cococcioni & de Gironcoli,
#
#     U = chi_0^-1 - chi^-1        PRB 71, 035105 (2005), Eq. 11
#
# Two slopes and a subtraction, which means the answer can be checked EXACTLY
# from synthetic data whose slopes we chose.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/uchain"; rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 1
CU="$TK_DIR/vasp_calculate_u.py"

# THE NUMBERS ARE VASP'S OWN. From the tutorial "Calculate U for LSDA+U",
# NiO 2x2x2 AFM-II, perturbing the d shell of atom 1 with LDAUU = LDAUJ = 0.1:
#
#   ground state   d occupancy  8.439
#   non-self-cons. d occupancy  8.488   ->  chi_0 = 0.050/0.1 = 0.50 (eV)^-1
#   self-consistent d occupancy 8.452   ->  chi   = 0.012/0.1 = 0.12 (eV)^-1
#   U = chi^-1 - chi_0^-1 = 1/0.12 - 1/0.5 = 6.33 eV
#
# Note the SIGN: a positive alpha makes the occupancy RISE, so both slopes are
# POSITIVE. Assuming the opposite -- that alpha repels electrons -- and
# "correcting" the formula from that assumption is how this test was first
# written, and it condemned correct code. The tutorial settles it.
TUT_CHI0=0.50
TUT_CHI=0.12
TUT_U=6.33

_mk(){ # _mk CHI0 CHI -- a table whose fitted slopes are exactly these
    : > U_data.dat
    for a in -0.20 -0.10 0.00 0.10 0.20; do
        printf '%s %s %s %s %s\n' "$a" 0 0 \
            "$(awk -v a="$a" -v c="$1" 'BEGIN{printf "%.6f", c*a}')" \
            "$(awk -v a="$a" -v c="$2" 'BEGIN{printf "%.6f", c*a}')" >> U_data.dat
    done
}

_mk "$TUT_CHI0" "$TUT_CHI"
out=$("$WP_PY" "$CU" 2>&1)
u=$(grep -oP '^U\s*=\s*\K-?[0-9.]+' <<<"$out" | head -1)
info "    VASP tutorial: chi_0 = $TUT_CHI0, chi = $TUT_CHI  ->  U = $TUT_U eV"
if [[ -z "$u" ]]; then
    fail "no U was printed: $(tail -1 <<<"$out")"
else
    near "$u" "$TUT_U" 0.02 "U reproduces the VASP tutorial's own worked example"
    awk -v x="$u" 'BEGIN{exit !(x>0)}' \
        && pass "U is positive, as the tutorial's arithmetic gives" \
        || fail "U came out negative ($u eV): the two terms are the wrong way round"
fi

# The two response slopes must be REPORTED, not just folded into U. They are
# what a user checks when a U comes out implausible.
c0=$(grep -oP 'chi_0\s*=\s*\K[-0-9.]+' <<<"$out" | head -1)
c1=$(grep -oP '^chi\s*=\s*\K[-0-9.]+' <<<"$out" | head -1)
near "${c0:-}" "$TUT_CHI0" 0.005 "the non-self-consistent response is reported"
near "${c1:-}" "$TUT_CHI" 0.005 "the self-consistent response is reported"

# --- the adversarial half ---------------------------------------------------
rm -f U_data.dat
must_refuse "a missing U_data.dat is refused with a message, not a traceback" \
    "U_data|not found|collect-u-data" \
    "$WP_PY" "$CU"

# A single alpha cannot define a slope. Fitting a line through one point is
# either a crash or, worse, a number.
printf '0.0 0 0 0.0 0.0\n' > U_data.dat
must_refuse "a single data point cannot give a slope, and is refused" "." \
    "$WP_PY" "$CU"

# A flat response means chi = 0 and 1/chi is infinite. Printing "inf eV" as a
# Hubbard U is worse than refusing.
_mk -0.35 0.0
out=$("$WP_PY" "$CU" 2>&1)
# Match a PRINTED VALUE, not the substring "inf" -- a refusal that explains
# itself is allowed to contain the word "infinite".
if grep -qiE '^\s*U\s*=\s*[-+]?(inf|nan)' <<<"$out"; then
    fail "a zero response prints '$(grep -oiE 'U *= *\S+' <<<"$out" | head -1)' instead of refusing"
elif grep -qiE "traceback" <<<"$out"; then
    fail "a zero response crashes with a traceback"
else
    pass "a zero response does not print an infinite U"
fi

# Garbage in the file must not be read as physics.
printf 'this is not data\n' > U_data.dat
must_refuse "a malformed U_data.dat is refused" "." "$WP_PY" "$CU"

# --- collect-u-data: the step that WRITES that file ------------------------
CD="$TK_DIR/collect_u_data.sh"
mkdir -p "$W/bare" && cd "$W/bare"
must_refuse "collect-u-data refuses where there is nothing to collect" "." \
    bash "$CD"
exit $(( FAIL_N > 0 ))
