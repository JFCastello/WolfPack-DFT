#!/usr/bin/env bash
# test_25_chain_structure -- what a CHUNKED relaxation changed, not what its
# last chunk changed.
#
# vasp-relax-loop restarts each chunk from its own CONTCAR: at every boundary
# the chain does `cp CONTCAR POSCAR`. After five chunks the POSCAR in the
# folder is the geometry chunk five began with, and diffing it against the
# final CONTCAR reports the last chunk's movement under a heading that claims
# to describe the whole relaxation.
#
# That failure is quiet in the worst way: the number it prints is SMALL, and
# small is what "converged" looks like. It is smallest exactly when the
# relaxation has wandered furthest, because a long run means more chunks and a
# more recent POSCAR.
#
# The displacements here are INJECTED, so the right answer is known in closed
# form rather than taken from a previous run of the same code.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/chainstruct"; rm -rf "$W"; mkdir -p "$W"
VC="$TK_DIR/vasp_check.sh"

# Si, 2 atoms. a = 5.43 A, so a fractional 0.04 along x is 0.04 * 5.43/2 in
# Cartesian for this cell -- the test asserts on the fractional displacement
# the structure report prints, which is what the tool compares.
_poscar(){ # _poscar DX -> a POSCAR with atom 2 displaced by DX in fractional x
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

# A folder that looks like a finished CHUNKED relaxation:
#   the original geometry   -> wolfpack_chain/chunk-001/POSCAR.in.gz   (x = 0.25)
#   what chunk 3 started on -> POSCAR                                  (x = 0.28)
#   where it ended          -> CONTCAR                                 (x = 0.29)
# The whole relaxation moved the atom 0.04; the last chunk moved it 0.01.
d="$W/chained"; mkdir -p "$d/wolfpack_chain/chunk-001" "$d/wolfpack_chain/chunk-002" \
                          "$d/wolfpack_chain/chunk-003"
_poscar 0.2500000000000000 > "$d/wolfpack_chain/chunk-001/POSCAR.in"
gzip -f "$d/wolfpack_chain/chunk-001/POSCAR.in"
_poscar 0.2800000000000000 > "$d/POSCAR"
_poscar 0.2900000000000000 > "$d/CONTCAR"
cat > "$d/INCAR" <<'EOF'
PREC = Accurate
ENCUT = 400
EDIFF = 1E-6
IBRION = 2
NSW = 20
ISIF = 2
EDIFFG = -0.01
ISMEAR = 0 ; SIGMA = 0.05
EOF
printf 'Auto\n0\nGamma\n4 4 4\n0 0 0\n' > "$d/KPOINTS"
cat > "$d/OSZICAR" <<'EOF'
       N       E                     dE             d eps       ncg     rms          rms(c)
DAV:   1    -0.107E+02   -0.10E+02   -0.29E+02   112   0.451E+01
   1 F= -.10820773E+02 E0= -.10820773E+02  d E =-.108208E+02
EOF
cat > "$d/OUTCAR" <<'EOF'
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

out=$(cd "$d" && timeout 300 bash "$VC" 2>&1); echo "$out" > "$d/check.log"

# --- 1. it noticed the chain at all ---------------------------------------
grep -qiE "chunk|whole chain" <<<"$out" \
    && pass "vasp-check sees this is a chunked run and says which 'before' it used" \
    || fail "vasp-check gave no sign it compared against anything but ./POSCAR"

# --- 2. THE ASSERTION: the displacement is the WHOLE relaxation's ----------
# The structure report prints a max displacement. 0.04 fractional along x in
# this cell is 0.04 * 5.43 * sqrt(0.5) = 0.1536 A; the last chunk alone would
# be a quarter of that, 0.0384 A. The two are far enough apart that no
# tolerance can confuse them.
# Anchored on the "all" row of the ATOMIC DISPLACEMENTS table (its first
# column is the max), not on the first number in the report -- the cell table
# prints several, and reading one of those instead is the mistake this suite
# has made twice before.
dmax=$(awk '/ATOMIC DISPLACEMENTS/{f=1; next} f && /^[[:space:]]*all[[:space:]]/{print $3; exit}' <<<"$out")
if [[ -z "$dmax" ]]; then
    fail "no displacement was reported at all -- cannot tell which 'before' was used"
else
    info "    reported max displacement: ${dmax} A"
    near "$dmax" 0.1536 0.02 "the displacement is the WHOLE chain's (0.04 frac), not the last chunk's (0.01)"
fi

# The "before" column is named after the chunk it came from -- not after the
# temporary file the archive is unpacked into.
ok_if "grep -qE '^  CELL +chunk-001 +CONTCAR' <<<\"\$out\" && ! grep -q 'wpcheck_poscar' <<<\"\$out\"" \
      "the table's 'before' column reads chunk-001, not a temporary file name"

# --- 3. an UNCHAINED relaxation is untouched ------------------------------
# The mirror image. A folder with no wolfpack_chain/ must still diff its own
# POSCAR, and the fix must not quietly change what it reports there.
d2="$W/plain"; mkdir -p "$d2"
for f in INCAR KPOINTS OSZICAR OUTCAR CONTCAR; do cp "$d/$f" "$d2/"; done
_poscar 0.2500000000000000 > "$d2/POSCAR"
out2=$(cd "$d2" && timeout 300 bash "$VC" 2>&1); echo "$out2" > "$d2/check.log"
grep -qE "POSCAR -> CONTCAR" <<<"$out2" \
    && pass "an unchained relaxation still diffs its own POSCAR, with the usual heading" \
    || fail "the unchained path changed heading or stopped reporting"
d2max=$(awk '/ATOMIC DISPLACEMENTS/{f=1; next} f && /^[[:space:]]*all[[:space:]]/{print $3; exit}' <<<"$out2")
[[ -n "$d2max" ]] && near "$d2max" 0.1536 0.02 \
    "and it reports the same 0.04 when its POSCAR really is the original" \
    || info "    (no displacement line to cross-check on the unchained path)"

# --- 4. a chain whose archive is missing does not break -------------------
# Half a chain directory is what a killed run leaves. It must fall back to
# ./POSCAR and still produce a report, not a broken one.
d3="$W/halfchain"; mkdir -p "$d3/wolfpack_chain/chunk-001"
for f in INCAR KPOINTS OSZICAR OUTCAR CONTCAR POSCAR; do cp "$d/$f" "$d3/"; done
out3=$(cd "$d3" && timeout 300 bash "$VC" 2>&1)
if grep -qiE "traceback \(most recent" <<<"$out3"; then
    fail "a chunk directory with no archived POSCAR crashes vasp-check"
elif grep -qE "What the relaxation changed" <<<"$out3"; then
    pass "a chunk directory with nothing archived falls back to ./POSCAR and still reports"
else
    fail "a chunk directory with nothing archived produced no structure section"
fi

# --- 4b. THE CONTROL: the two answers really are distinguishable ----------
# Everything above would also pass if the displacement happened to be the same
# either way. Same POSCAR (0.28) and CONTCAR (0.29) as the chained folder, but
# no chain -- so this is literally "what the last chunk moved", measured. If it
# came out 0.1536 too, the assertion above would be proving nothing.
d4="$W/lastchunk"; mkdir -p "$d4"
for f in INCAR KPOINTS OSZICAR OUTCAR CONTCAR; do cp "$d/$f" "$d4/"; done
_poscar 0.2800000000000000 > "$d4/POSCAR"
out4=$(cd "$d4" && timeout 300 bash "$VC" 2>&1)
d4max=$(awk '/ATOMIC DISPLACEMENTS/{f=1; next} f && /^[[:space:]]*all[[:space:]]/{print $3; exit}' <<<"$out4")
if [[ -z "$d4max" ]]; then
    fail "the control folder reported no displacement"
else
    info "    last chunk alone would report: ${d4max} A"
    near "$d4max" 0.0384 0.005 "the last-chunk answer is a different number (0.01 frac), so the check above discriminates"
fi

# --- 5. no temporary file is left behind ----------------------------------
ok_if "[[ -z \"\$(ls /tmp/wpcheck_poscar0.* 2>/dev/null)\" ]]" \
      "the decompressed original is cleaned up, not left in /tmp"

exit $(( FAIL_N > 0 ))
