#!/usr/bin/env bash
# test_27_magmom_flag -- build-magnetic-configs --magmom.
#
# The flag says how large a moment each species starts with. It does NOT say
# where the up and down sites go: that is the enumeration, and the enumeration
# is pymatgen's MagneticStructureEnumerator, untouched. So what is checked here
# is exactly that division of labour --
#
#   the flag changes the MAGNITUDES and nothing else;
#   the ORDERINGS are the same ones pymatgen produces without it.
#
# A flag that also changed which orderings appeared would mean this package had
# started deciding the magnetic structure, which is not its job.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/magmom"; rm -rf "$W"; mkdir -p "$W"
BMC="$TK_DIR/build_magnetic_configs.py"
CASES_DIR="$SUITE_DIR/cases"

_case(){ # _case NAME CASE -> dir with POSCAR + INCAR
    local d="$W/$1"; mkdir -p "$d"
    cp "$CASES_DIR/$2/POSCAR" "$d/POSCAR"
    cat > "$d/INCAR" <<'EOF'
PREC = Accurate
ENCUT = 500
EDIFF = 1E-6
ISMEAR = 0 ; SIGMA = 0.05
EOF
    echo "$d"
}
# Every MAGMOM value in the generated tree, sign stripped, unique and sorted.
_mags(){ grep -ho 'MAGMOM = [^#]*' "$1"/magnetic_configs/*/config_*/INCAR 2>/dev/null \
         | sed 's/MAGMOM = //' | tr ' ' '\n' | sed 's/^[0-9]*\*//' \
         | grep -E '^-?[0-9.]+$' | sed 's/^-//' | sort -u | tr '\n' ' '; }
# The sign PATTERN of each ordering, which is what the enumeration decides.
_patterns(){ grep -ho 'MAGMOM = [^#]*' "$1"/magnetic_configs/*/config_*/INCAR 2>/dev/null \
         | sed 's/MAGMOM = //' | tr ' ' '\n' | sed 's/^\([0-9]*\)\*\(-\?\)[0-9.]*$/\1\2X/' \
         | tr '\n' ' ' | sed 's/  */ /g' | sort; }

# ===========================================================================
# 1. BOTH NOTATIONS SET THE MAGNITUDE
# ===========================================================================
# "Ni:1.0" is the per-species form pymatgen takes directly.
# "4*3.0 4*0.0" is the INCAR's own MAGMOM shorthand, one entry per ion in
# POSCAR order -- the form you get by pasting out of a file you already have.
d1=$(_case species NiO)
( cd "$d1" && "$WP_PY" "$BMC" --magmom "Ni:1.0" >log.txt 2>&1 )
m1=$(_mags "$d1")
ok_if "[[ '$m1' == '0.0 1.0 ' ]]" "EL:value form -- every moment is the 1.0 asked for (got: $m1)"

d2=$(_case incarform NiO)
nsites=$(sed -n '7p' "$d2/POSCAR" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}')
nni=$(sed -n '7p' "$d2/POSCAR" | awk '{print $1}')
( cd "$d2" && "$WP_PY" "$BMC" --magmom "${nni}*3.0 $(( nsites - nni ))*0.0" >log.txt 2>&1 )
m2=$(_mags "$d2")
ok_if "[[ '$m2' == '0.0 3.0 ' ]]" "INCAR shorthand -- every moment is the 3.0 asked for (got: $m2)"

# ===========================================================================
# 2. THE FLAG DOES NOT TOUCH THE ENUMERATION
# ===========================================================================
# THE assertion of this test. Same cell, three different magnitudes: pymatgen
# must return the same set of sign patterns each time. If the patterns changed
# with the magnitude, the flag would be steering the physics.
d3=$(_case defaults NiO)
( cd "$d3" && "$WP_PY" "$BMC" >log.txt 2>&1 )
p1=$(_patterns "$d1"); p2=$(_patterns "$d2"); p3=$(_patterns "$d3")
n1=$(ls -d "$d1"/magnetic_configs/*/config_* 2>/dev/null | wc -l)
n3=$(ls -d "$d3"/magnetic_configs/*/config_* 2>/dev/null | wc -l)
ok_if "[[ '$n1' == '$n3' && '$n1' -gt 1 ]]" \
      "--magmom produces the same NUMBER of orderings as pymatgen's defaults ($n1)"
ok_if "[[ '$p1' == '$p3' ]]" "and the same sign patterns -- the magnitude changed, the orderings did not"
ok_if "[[ '$p2' == '$p3' ]]" "the INCAR shorthand agrees with them too"

# And pymatgen's own default really is a different number, or the checks above
# would pass for a flag that did nothing at all.
m3=$(_mags "$d3")
ok_if "[[ '$m3' != '$m1' ]]" "pymatgen's default magnitude differs from the flag's ($m3 vs $m1)"

# ===========================================================================
# 3. MAGMOM STILL LINES UP WITH THE POSCAR
# ===========================================================================
# The invariant test_10 guards, re-checked under the flag: a MAGMOM off by one
# site is a different magnetic structure that converges perfectly well.
bad=0; nchk=0
for f in "$d1"/magnetic_configs/*/config_*/INCAR; do
    [[ -f "$f" ]] || continue
    dir=$(dirname "$f")
    [[ -f "$dir/POSCAR" ]] || continue
    ns=$(sed -n '7p' "$dir/POSCAR" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}')
    nm=$(grep -o 'MAGMOM = [^#]*' "$f" | sed 's/MAGMOM = //' | tr ' ' '\n' \
         | awk -F'*' '/[0-9]/{ if (NF==2) s+=$1; else if ($0 != "") s+=1 } END{print s+0}')
    nchk=$((nchk+1)); (( ns == nm )) || bad=$((bad+1))
done
ok_if "[[ $nchk -gt 0 && $bad -eq 0 ]]" \
      "MAGMOM lines up with the POSCAR in all $nchk folder(s) built with --magmom"

# ===========================================================================
# 4. A CELL PYMATGEN CALLS NON-MAGNETIC
# ===========================================================================
# MgO has no element in pymatgen's default-moment table, so it is refused --
# correctly, because guessing would be inventing physics. The flag is the
# explicit statement that overrides that, which is what it is for.
d4=$(_case rescue MgO)
out_no=$( cd "$d4" && "$WP_PY" "$BMC" --dry-run 2>&1 )
grep -qiE "no magnetic elements" <<<"$out_no" \
    && pass "MgO is refused without the flag, as it was before" \
    || fail "MgO was enumerated with no moment given: $(tail -1 <<<"$out_no")"
grep -qE '\-\-magmom' <<<"$out_no" \
    && pass "and the refusal names --magmom as the way through" \
    || fail "the refusal does not mention the flag that solves it"
out_yes=$( cd "$d4" && "$WP_PY" "$BMC" --magmom "Mg:1.0" --dry-run 2>&1 )
grep -qE "would write [0-9]+ configuration" <<<"$out_yes" \
    && pass "with --magmom Mg:1.0 the same cell enumerates" \
    || fail "--magmom did not rescue a cell pymatgen calls non-magnetic"

# ===========================================================================
# 5. INEQUIVALENT SITES OF ONE SPECIES
# ===========================================================================
# What pymatgen does NOT accept is a different STARTING magnitude per
# symmetrically inequivalent site: MagneticStructureEnumerator strips per-site
# magmoms in _sanitize_input_structure and rebuilds them from a
# {species: magnitude} dict. What it DOES have is a strategy that splits sites
# by Wyckoff symbol and gives them different moments in the OUTPUT --
# ferrimagnetic_by_motif. So the check is that the strategy is reachable.
d5=$(_case motif NiO)
out5=$( cd "$d5" && "$WP_PY" "$BMC" --magmom "Ni:2.0" \
        --strategies ferromagnetic,antiferromagnetic,ferrimagnetic_by_motif \
        --dry-run 2>&1 )
if grep -qiE "traceback \(most recent" <<<"$out5"; then
    fail "ferrimagnetic_by_motif with --magmom crashes"
elif grep -qE "would write [0-9]+ configuration" <<<"$out5"; then
    pass "ferrimagnetic_by_motif -- pymatgen's per-Wyckoff strategy -- accepts the flag"
else
    fail "ferrimagnetic_by_motif produced nothing: $(tail -1 <<<"$out5")"
fi

# ===========================================================================
# 6. THE REFUSALS
# ===========================================================================
_bad(){ must_refuse "$1" "$2" bash -c "cd '$d1' && '$WP_PY' '$BMC' --magmom '$3' --dry-run"; }
_bad "an element not in the cell is refused, and the cell's elements named" "has no Fe|contains" "Fe:3.0"
_bad "a non-numeric magnitude is refused" "not a number" "Ni:abc"
_bad "the wrong number of INCAR-form values is refused, by count" "value\(s\) for" "3*1.0"
_bad "all-zero moments are refused instead of enumerating nothing" "zero" "Ni:0.0"
_bad "an empty --magmom is refused" "empty" " "

exit $(( FAIL_N > 0 ))
