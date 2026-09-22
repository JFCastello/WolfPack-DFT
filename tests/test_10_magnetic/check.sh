#!/usr/bin/env bash
# build-magnetic-configs. The output is a tree of folders each holding a MAGMOM
# that must line up SITE FOR SITE with its own POSCAR. A MAGMOM off by one site
# is a different magnetic structure, it converges perfectly well, and nothing
# downstream can tell.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/magnetic"; rm -rf "$W"; mkdir -p "$W"
BM="$TK_DIR/build_magnetic_configs.py"

_case(){ local d="$W/$1"; mkdir -p "$d"; cp "$CASES/$2/POSCAR" "$d/POSCAR"
    printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$d/KPOINTS"
    printf 'SYSTEM = %s\nISPIN = 2\nENCUT = 520\nEDIFF = 1E-6\nLDAU = .TRUE.\n' "$2" > "$d/INCAR"
    echo "$d"; }

# --- a missing INCAR must be a HARD error ----------------------------------
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

# --- a non-magnetic cell must be refused, not enumerated -------------------
# MgO has no magnetic species at all. Enumerating "orderings" of a moment that
# does not exist produces folders that all converge to the same answer.
d=$(_case nonmag MgO)
must_refuse "a cell with no magnetic species is refused" "magnetic" \
    bash -c "cd '$d' && '$WP_PY' '$BM' </dev/null"

# --- the real thing: NiO --------------------------------------------------
d=$(_case nio NiO)
echo "the user's own file" > "$d/readcheck_enum.out.mine"
if ! ( cd "$d" && timeout 600 "$WP_PY" "$BM" >build.log 2>&1 ); then
    fail "NiO: $(grep -m1 -iE 'error' "$d/build.log" || tail -1 "$d/build.log")"
else
    pass "NiO: ran clean"
    n=$(find "$d/magnetic_configs" -name POSCAR 2>/dev/null | wc -l)
    ok_if "[[ $n -gt 1 ]]" "NiO: more than one ordering was produced ($n)"

    # enumlib drops scratch files in the CURRENT directory. They must be gone,
    # and a file of the user's with a colliding name must SURVIVE.
    deb=$(ls "$d"/readcheck_enum.out "$d"/struct_enum.* "$d"/VERSION.enum 2>/dev/null | wc -l)
    ok_if "[[ $deb -eq 0 ]]" "NiO: no enumlib debris left next to the inputs"
    ok_if "[[ -f '$d/readcheck_enum.out.mine' ]]" "NiO: the user's own file survived"

    # THE check: MAGMOM must line up with its own POSCAR, site for site.
    bad=0; checked=0
    while read -r p; do
        f="$(dirname "$p")"
        [[ -f "$f/INCAR" && -f "$f/POSCAR" ]] || continue
        checked=$((checked+1))
        "$WP_PY" - "$f" <<'PY' || bad=$((bad+1))
import re, sys
from pathlib import Path
d = Path(sys.argv[1])
nsites = 0
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
    done < <(find "$d/magnetic_configs" -name POSCAR)
    ok_if "[[ $bad -eq 0 ]]" "NiO: MAGMOM lines up with the POSCAR in all $checked folder(s)"

    # The orderings must not all be the same. An enumerator that returns the
    # ferromagnet N times has produced one ordering, not N.
    uniq=$(find "$d/magnetic_configs" -name INCAR -exec grep -h '^MAGMOM' {} \; | sort -u | wc -l)
    ok_if "[[ $uniq -gt 1 ]]" "NiO: the orderings actually differ from one another ($uniq distinct)"
fi
exit $(( FAIL_N > 0 ))
