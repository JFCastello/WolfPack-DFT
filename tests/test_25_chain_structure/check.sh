#!/usr/bin/env bash
# test_25_chain_structure -- what a CHAINED relaxation changed: the whole
# relaxation, not its last chunk.
#
# vasp-relax-loop runs each chunk in wolfpack_chain/NNN/ and never overwrites
# the folder's POSCAR; the latest CONTCAR is copied into the folder. So
# vasp-check's POSCAR -> CONTCAR is the whole relaxation, and it must not be
# the last chunk's -- whose number is SMALL, which is what "converged" looks
# like.
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

# A folder that looks like a finished CHAINED relaxation (vasp-relax-loop):
#   the input            -> POSCAR, untouched                (x = 0.25)
#   chunk 3 started from -> wolfpack_chain/003/POSCAR        (x = 0.28)
#   where it ended       -> CONTCAR, the latest chunk's      (x = 0.29)
# The whole relaxation moved the atom 0.04; the last chunk moved it 0.01.
d="$W/chained"; mkdir -p "$d/wolfpack_chain"/{001,002,003}
_poscar 0.2500000000000000 > "$d/POSCAR"
_poscar 0.2900000000000000 > "$d/CONTCAR"
_poscar 0.2800000000000000 > "$d/wolfpack_chain/003/POSCAR"
cp "$d/CONTCAR" "$d/wolfpack_chain/003/CONTCAR"
printf 'chain_kind="relax"\nchain_state="converged"\n' > "$d/wolfpack_chain/chain.env"
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

# --- 1. it says what it compared -------------------------------------------
ok_if "grep -q 'chained relaxation: POSCAR is the input, CONTCAR the latest of 3 completed chunk(s)' <<<\"\$out\"" \
      "vasp-check sees the chain and says what POSCAR and CONTCAR are"

# --- 2. THE ASSERTION: the displacement is the WHOLE relaxation's ----------
# 0.04 fractional along x in this cell is 0.04 * 5.43 * sqrt(0.5) = 0.1536 A;
# the last chunk alone would be a quarter of that, 0.0384 A. Anchored on the
# "all" row of the ATOMIC DISPLACEMENTS table (its first column is the max).
dmax=$(awk '/ATOMIC DISPLACEMENTS/{f=1; next} f && /^[[:space:]]*all[[:space:]]/{print $3; exit}' <<<"$out")
if [[ -z "$dmax" ]]; then
    fail "no displacement was reported at all"
else
    info "    reported max displacement: ${dmax} A"
    near "$dmax" 0.1536 0.02 "the displacement is the WHOLE chain's (0.04 frac), not the last chunk's (0.01)"
fi

# --- 3. an UNCHAINED relaxation reads the same way, without the note -------
d2="$W/plain"; mkdir -p "$d2"
for f in INCAR KPOINTS OSZICAR OUTCAR CONTCAR POSCAR; do cp "$d/$f" "$d2/"; done
out2=$(cd "$d2" && timeout 300 bash "$VC" 2>&1); echo "$out2" > "$d2/check.log"
ok_if "grep -q 'POSCAR -> CONTCAR' <<<\"\$out2\" && ! grep -q 'chained relaxation' <<<\"\$out2\"" \
      "an unchained relaxation: the same heading, no chain note"

# --- 4. THE CONTROL: the two answers really are distinguishable ------------
# Literally what the last chunk moved (0.28 -> 0.29). If it came out 0.1536
# too, the assertion above would be proving nothing.
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

exit $(( FAIL_N > 0 ))
