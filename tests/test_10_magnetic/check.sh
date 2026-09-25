#!/usr/bin/env bash
# build-magnetic-configs. The output is a tree of folders each holding a MAGMOM
# that must line up SITE FOR SITE with its own POSCAR. A MAGMOM off by one site
# is a different magnetic structure, it converges perfectly well, and nothing
# downstream can tell.
#
# --magmom says how large a moment each species starts with. It does NOT say
# where the up and down sites go: that is the enumeration, and the enumeration
# is pymatgen's MagneticStructureEnumerator, untouched. So the flag must change
# the MAGNITUDES and nothing else; a flag that also changed which orderings
# appeared would mean this package had started deciding the magnetic
# structure, which is not its job.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/magnetic"; rm -rf "$W"; mkdir -p "$W"
BM="$TK_DIR/build_magnetic_configs.py"

_case(){ local d="$W/$1"; mkdir -p "$d"; cp "$CASES/$2/POSCAR" "$d/POSCAR"
    printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$d/KPOINTS"
    printf 'SYSTEM = %s\nISPIN = 2\nENCUT = 520\nEDIFF = 1E-6\nLDAU = .TRUE.\n' "$2" > "$d/INCAR"
    echo "$d"; }
# Every MAGMOM value in the generated tree, sign stripped, unique and sorted.
_mags(){ grep -ho 'MAGMOM = [^#]*' "$1"/magnetic_configs/*/config_*/INCAR 2>/dev/null \
         | sed 's/MAGMOM = //' | tr ' ' '\n' | sed 's/^[0-9]*\*//' \
         | grep -E '^-?[0-9.]+$' | sed 's/^-//' | sort -u | tr '\n' ' '; }
# The sign PATTERN of each ordering, which is what the enumeration decides.
_patterns(){ grep -ho 'MAGMOM = [^#]*' "$1"/magnetic_configs/*/config_*/INCAR 2>/dev/null \
         | sed 's/MAGMOM = //' | tr ' ' '\n' | sed 's/^\([0-9]*\)\*\(-\?\)[0-9.]*$/\1\2X/' \
         | tr '\n' ' ' | sed 's/  */ /g' | sort; }
_norder(){ ls -d "$1"/magnetic_configs/*/config_* 2>/dev/null | wc -l; }

# ===========================================================================
# 1. A MISSING INCAR IS A HARD ERROR
# ===========================================================================
# Without it every generated folder carries a two-line INCAR -- ISPIN and
# MAGMOM and nothing else -- and runs a calculation at default cutoff with the
# wrong functional, silently.
d="$W/noincar"; mkdir -p "$d"; cp "$CASES/NiO/POSCAR" "$d/POSCAR"
must_refuse "a missing INCAR is refused, not replaced by a two-line stub" "INCAR" \
    bash -c "cd '$d' && '$WP_PY' '$BM' </dev/null"
printf 'ISPIN = 2\n' > "$d/INACAR"      # the near-miss a real user typed
out=$(cd "$d" && "$WP_PY" "$BM" 2>&1 || true)
grep -q "INACAR" <<<"$out" \
    && pass "the refusal names the near-miss file sitting next to it" \
    || skip "no near-miss suggestion (cosmetic)"
( cd "$d" && "$WP_PY" "$BM" --no-incar >nc.log 2>&1 ) \
    && pass "--no-incar is an explicit way through" \
    || fail "--no-incar does not work: $(tail -1 "$d/nc.log")"

# ===========================================================================
# 2. NiO WITH PYMATGEN'S DEFAULTS
# ===========================================================================
d=$(_case nio NiO)
echo "the user's own file" > "$d/readcheck_enum.out.mine"
if ! ( cd "$d" && timeout 600 "$WP_PY" "$BM" >build.log 2>&1 ); then
    fail "NiO: $(grep -m1 -iE 'error' "$d/build.log" || tail -1 "$d/build.log")"
else
    pass "NiO: ran clean"
    n=$(_norder "$d")
    ok_if "[[ $n -gt 1 ]]" "NiO: more than one ordering was produced ($n)"

    # enumlib drops scratch files in the CURRENT directory. They must be gone,
    # and a file of the user's with a colliding name must SURVIVE.
    deb=$(ls "$d"/readcheck_enum.out "$d"/struct_enum.* "$d"/VERSION.enum 2>/dev/null | wc -l)
    ok_if "[[ $deb -eq 0 ]]" "NiO: no enumlib debris left next to the inputs"
    ok_if "[[ -f '$d/readcheck_enum.out.mine' ]]" "NiO: the user's own file survived"

    # The orderings must not all be the same. An enumerator that returns the
    # ferromagnet N times has produced one ordering, not N.
    uniq=$(find "$d/magnetic_configs" -name INCAR -exec grep -h '^MAGMOM' {} \; | sort -u | wc -l)
    ok_if "[[ $uniq -gt 1 ]]" "NiO: the orderings actually differ from one another ($uniq distinct)"
fi
d_def="$d"

# ===========================================================================
# 3. --magmom: BOTH NOTATIONS SET THE MAGNITUDE
# ===========================================================================
# "Ni:1.0" is the per-species form pymatgen takes directly.
# "2*3.0 2*0.0" is the INCAR's own MAGMOM shorthand, one entry per ion in
# POSCAR order -- the form you get by pasting out of a file you already have.
d1=$(_case species NiO)
( cd "$d1" && "$WP_PY" "$BM" --magmom "Ni:1.0" >log.txt 2>&1 )
m1=$(_mags "$d1")
ok_if "[[ '$m1' == '0.0 1.0 ' ]]" "EL:value form -- every moment is the 1.0 asked for (got: $m1)"

d2=$(_case incarform NiO)
nsites=$(sed -n '7p' "$d2/POSCAR" | awk '{s=0; for(i=1;i<=NF;i++) s+=$i; print s}')
nni=$(sed -n '7p' "$d2/POSCAR" | awk '{print $1}')
( cd "$d2" && "$WP_PY" "$BM" --magmom "${nni}*3.0 $(( nsites - nni ))*0.0" >log.txt 2>&1 )
m2=$(_mags "$d2")
ok_if "[[ '$m2' == '0.0 3.0 ' ]]" "INCAR shorthand -- every moment is the 3.0 asked for (got: $m2)"

# ===========================================================================
# 4. THE FLAG DOES NOT TOUCH THE ENUMERATION
# ===========================================================================
# Same cell, three different magnitudes: pymatgen must return the same set of
# sign patterns each time. If the patterns changed with the magnitude, the
# flag would be steering the physics. Section 2's run is the reference.
p1=$(_patterns "$d1"); p2=$(_patterns "$d2"); p3=$(_patterns "$d_def")
n1=$(_norder "$d1"); n3=$(_norder "$d_def")
ok_if "[[ '$n1' == '$n3' && '$n1' -gt 1 ]]" \
      "--magmom produces the same NUMBER of orderings as pymatgen's defaults ($n1)"
ok_if "[[ '$p1' == '$p3' ]]" "and the same sign patterns -- the magnitude changed, the orderings did not"
ok_if "[[ '$p2' == '$p3' ]]" "the INCAR shorthand agrees with them too"

# And pymatgen's own default really is a different number, or the checks above
# would pass for a flag that did nothing at all.
m3=$(_mags "$d_def")
ok_if "[[ '$m3' != '$m1' ]]" "pymatgen's default magnitude differs from the flag's ($m3 vs $m1)"

# ===========================================================================
# 5. THE check: MAGMOM LINES UP WITH ITS OWN POSCAR, IN EVERY FOLDER
# ===========================================================================
# All three trees: pymatgen's defaults and both forms of the flag.
bad=0; checked=0
while read -r p; do
    f="$(dirname "$p")"
    [[ -f "$f/INCAR" && -f "$f/POSCAR" ]] || continue
    checked=$((checked+1))
    "$WP_PY" - "$f" <<'PY' || bad=$((bad+1))
import re, sys
from pathlib import Path
d = Path(sys.argv[1])
lines = (d / "POSCAR").read_text().splitlines()
counts = [int(x) for x in lines[6].split()] if lines[6].split()[0].isdigit() else [int(x) for x in lines[5].split()]
nsites = sum(counts)
m = re.search(r'^\s*MAGMOM\s*=\s*(.+)$', (d / "INCAR").read_text(), re.M)
if not m:
    print(f"{d.name}: no MAGMOM", file=sys.stderr); sys.exit(1)
n = 0
for tok in m.group(1).split('#')[0].split():
    if '*' in tok:
        a, b = tok.split('*'); n += int(float(a))
    else:
        n += 1
if n != nsites:
    print(f"{d.name}: MAGMOM has {n} entries, POSCAR has {nsites} sites", file=sys.stderr)
    sys.exit(1)
PY
done < <(find "$d_def/magnetic_configs" "$d1/magnetic_configs" "$d2/magnetic_configs" -name POSCAR 2>/dev/null)
ok_if "[[ $checked -gt 0 && $bad -eq 0 ]]" \
      "MAGMOM lines up with the POSCAR in all $checked folder(s), with and without --magmom"

# ===========================================================================
# 6. A CELL PYMATGEN CALLS NON-MAGNETIC
# ===========================================================================
# MgO has no element in pymatgen's default-moment table, so it is refused --
# correctly: enumerating "orderings" of a moment that does not exist produces
# folders that all converge to the same answer, and guessing one would be
# inventing physics. The flag is the explicit statement that overrides that.
d4=$(_case nonmag MgO)
out_no=$( cd "$d4" && "$WP_PY" "$BM" --dry-run 2>&1 ); rc_no=$?
(( rc_no != 0 )) && grep -qiE "no magnetic elements" <<<"$out_no" \
    && pass "MgO is refused without the flag (exit $rc_no)" \
    || fail "MgO was not refused (exit $rc_no): $(tail -1 <<<"$out_no")"
grep -qE '\-\-magmom' <<<"$out_no" \
    && pass "and the refusal names --magmom as the way through" \
    || fail "the refusal does not mention the flag that solves it"
out_yes=$( cd "$d4" && "$WP_PY" "$BM" --magmom "Mg:1.0" --dry-run 2>&1 )
grep -qE "would write [0-9]+ configuration" <<<"$out_yes" \
    && pass "with --magmom Mg:1.0 the same cell enumerates" \
    || fail "--magmom did not rescue a cell pymatgen calls non-magnetic"

# ===========================================================================
# 7. INEQUIVALENT SITES OF ONE SPECIES
# ===========================================================================
# What pymatgen does NOT accept is a different STARTING magnitude per
# symmetrically inequivalent site: MagneticStructureEnumerator strips per-site
# magmoms in _sanitize_input_structure and rebuilds them from a
# {species: magnitude} dict. What it DOES have is a strategy that splits sites
# by Wyckoff symbol and gives them different moments in the OUTPUT --
# ferrimagnetic_by_motif. So the check is that the strategy is reachable.
d5=$(_case motif NiO)
out5=$( cd "$d5" && "$WP_PY" "$BM" --magmom "Ni:2.0" \
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
# 8. --magmom's REFUSALS
# ===========================================================================
_bad(){ must_refuse "$1" "$2" bash -c "cd '$d1' && '$WP_PY' '$BM' --magmom '$3' --dry-run"; }
_bad "an element not in the cell is refused, and the cell's elements named" "has no Fe|contains" "Fe:3.0"
_bad "a non-numeric magnitude is refused" "not a number" "Ni:abc"
_bad "the wrong number of INCAR-form values is refused, by count" "value\(s\) for" "3*1.0"
_bad "all-zero moments are refused instead of enumerating nothing" "zero" "Ni:0.0"
_bad "an empty --magmom is refused" "empty" " "

exit $(( FAIL_N > 0 ))
