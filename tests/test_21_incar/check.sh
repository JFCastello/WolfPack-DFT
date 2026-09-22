#!/usr/bin/env bash
# test_21_incar -- the INCAR editor: the user's layout survives every edit.
#
# Five places in the toolkit used to edit an INCAR, each with its own regex.
# They now share one implementation -- twice: once in awk for the job scripts
# that run without python, once in python for the tools that have it. So there
# are two things to check: that the rules hold, and that the two copies have
# not drifted apart.
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/t21"; rm -rf "$W"; mkdir -p "$W"

LIB="$TK_DIR/wolfpack_incar.sh"
# shellcheck disable=SC1090
source "$LIB"

# A file laid out the way the toolkit's own template lays one out: a header is
# '!' followed IMMEDIATELY by dashes -- both implementations read
# ^[ \t]*[!#]-{3,}, so '! ----' with a space is a comment, not a header.
_fresh(){ cat > "$W/INCAR" <<'EOF'
!--------------------------------------------- Startup job description
  SYSTEM = NiO AFM-II
  ISPIN  = 2            ! my own note, keep it
!--------------------------------------------- Electronic Relaxation
  PREC   = Accurate
  ENCUT  = 520
  NELM   = 60
!--------------------------------------------- DOS related values
  ISMEAR = 0
  SIGMA  = 0.05
EOF
}

# --- rule 1: an active tag is replaced WHERE IT SITS ------------------------
_fresh
wp_incar_set "$W/INCAR" ENCUT 400
line=$(grep -n '^\s*ENCUT' "$W/INCAR" | cut -d: -f1)
ok_if "[[ '$line' == 6 ]]" "an existing tag is replaced on its own line, not appended (line $line)"
ok_if "grep -qE '^\s*ENCUT\s*=\s*400' '$W/INCAR'" "the new value is there"
ok_if "[[ \$(grep -c 'ENCUT' '$W/INCAR') == 1 ]]" "the old value is gone, not shadowed by a duplicate below"

# The user's own trailing comment is theirs. An editor that drops it has
# deleted something the user wrote, to change something else.
wp_incar_set "$W/INCAR" ISPIN 1
ok_if "grep -qE 'ISPIN\s*=\s*1\s*!\s*my own note' '$W/INCAR'" \
      "a tag's own trailing comment survives a value change"

# ... unless a new note is given, which is the one way to replace it.
wp_incar_set "$W/INCAR" ISPIN 2 "restored"
ok_if "grep -qE 'ISPIN\s*=\s*2\s*!\s*restored' '$W/INCAR'" \
      "an explicit new note replaces the old one"

# --- rule 2: an absent tag joins ITS section --------------------------------
_fresh
wp_incar_set "$W/INCAR" EDIFF "1E-6"
ln_ediff=$(grep -n '^\s*EDIFF' "$W/INCAR" | cut -d: -f1)
ln_nelm=$(grep -n '^\s*NELM'  "$W/INCAR" | cut -d: -f1)
ln_dos=$(grep -n 'DOS related'  "$W/INCAR" | cut -d: -f1)
ok_if "[[ $ln_ediff -gt $ln_nelm && $ln_ediff -lt $ln_dos ]]" \
      "a new tag lands in ITS OWN section, not at the bottom of the file (EDIFF at $ln_ediff, between $ln_nelm and $ln_dos)"

# --- rule 3: a missing section is created in canonical order ----------------
# Parallelization is last in the canonical order and absent from the file.
wp_incar_set "$W/INCAR" KPAR 4
ok_if "grep -q 'Parallelization' '$W/INCAR'" "a missing section is created, with its header"
ln_kpar=$(grep -n '^\s*KPAR' "$W/INCAR" | cut -d: -f1)
ln_sig=$(grep -n '^\s*SIGMA' "$W/INCAR" | cut -d: -f1)
ok_if "[[ $ln_kpar -gt $ln_sig ]]" "the created section goes in canonical order (after DOS, which precedes it)"

# A file with NO headers must not sprout them: the layout is the user's.
printf 'SYSTEM = plain\nENCUT = 300\n' > "$W/flat"
wp_incar_set "$W/flat" KPAR 2
ok_if "! grep -q '!' '$W/flat'" "a file with no section headers does not get any"
ok_if "grep -qE '^\s*KPAR\s*=\s*2' '$W/flat'" "the tag is still set in a headerless file"

# --- rule 4: commenting out never deletes -----------------------------------
_fresh
wp_incar_comment "$W/INCAR" NELM "chunked by the chain"
ok_if "grep -qE '^\s*#.*NELM' '$W/INCAR'" "a commented-out tag is prefixed, not deleted"
ok_if "grep -qE 'NELM\s*=\s*60' '$W/INCAR'" "its old value is still readable in the comment"
ok_if "[[ \$(wp_incar_get '$W/INCAR' NELM) == '' ]]" "a commented-out tag reads back as unset"

# --- read-back --------------------------------------------------------------
ok_if "[[ \$(wp_incar_get '$W/INCAR' ENCUT) == 520 ]]" "wp_incar_get reads back an active value"

# --- THE DRIFT GATE ---------------------------------------------------------
# Two implementations of one rule set is two chances to be wrong differently.
# wolfpack_incar.py compares its own table against the shell one and exits
# non-zero if they disagree; publish_public.sh runs it as a release gate, so
# this test runs the same gate.
out=$("$WP_PY" "$TK_DIR/wolfpack_incar.py" "$LIB" 2>&1); rc=$?
if (( rc == 0 )); then
    pass "the awk and python section tables agree (the release gate the publisher runs)"
else
    fail "the two INCAR layout tables have DRIFTED apart: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# A gate that cannot fail is not a gate. Feed it a deliberately altered copy
# and check it NOTICES -- otherwise a green gate proves nothing.
sed 's/^Parallelization|NCORE/Parallelization|NOTACORE/' "$LIB" > "$W/drifted.sh"
if "$WP_PY" "$TK_DIR/wolfpack_incar.py" "$W/drifted.sh" >/dev/null 2>&1; then
    fail "the drift gate passed a table that WAS drifted -- it cannot detect anything"
else
    pass "the drift gate detects a table that was altered on purpose"
fi

exit $(( FAIL_N > 0 ))
