#!/usr/bin/env bash
#==============================================================================
# vasp_check.sh  —  PHYSICS-coherence analysis of a VASP run (finished or killed).
#
#   It interprets whatever data the run produced: convergence, magnetic order,
#   metal/insulator/half-metal, direct/indirect band gap with VBM/CBM k-points,
#   GW quasiparticle shifts. It does NOT diagnose why a job died or whether the
#   data survived -- that lives in `vasp-diagnose` (OOM/walltime/crash + the
#   PLOTTABLE / PARTIAL / NOT-USABLE data-salvage verdict). Run vasp-diagnose on a
#   crashed folder; run vasp-check for the physics on whatever data is present.
#
# Recognises the calculation TYPE from INCAR (with OUTCAR fallback):
#     * static SCF                (NSW=0 / IBRION=-1)
#     * non-self-consistent       (ICHARG=11 -> band-structure or DOS)
#     * ionic / cell relaxation   (NSW>0, IBRION 1/2/3; ISIF decides ions/cell)
#     * AIMD                      (IBRION=0)
#     * DFPT / linear response    (IBRION 5/6/7/8, LEPSILON, LCALCEPS)
#     * G0W0 / GW0 / EVGW0 / QPGW / scGW  (single-shot vs eigenvalue/QP scGW)
#     * RPA / ACFDT, BSE          (light handling)
#   plus the XC layer: GGA, GGA+U, HSE/PBE0 hybrid.
#
# It does THREE jobs:
#   (1) computational / convergence audit (SCF, forces, stress, GW knobs)
#   (2) physics / interpretation (metal/insulator/half-metal, magnetic order, gap +
#       VBM/CBM with full k-coords, moments, QP renormalisation, Z factors)
#   (3) flags common pitfalls per calculation type.
#   (Why-it-died + data-salvage classification -> see `vasp-diagnose`.)
#
# Usage:   vasp_check.sh [DIR]            (default DIR = .)
#          vasp_check.sh -h | --help
#
# Exit:    0 = PASS / PASS-with-warnings, 1 = at least one FAIL, 2 = usage error
#==============================================================================
set -uo pipefail

#------------------------------- presentation --------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; MAG=$'\e[35m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""; MAG=""
fi

FAILS=0; WARNS=0
hdr(){  printf '\n%s== %s ==%s\n' "$B$CYN" "$1" "$R"; }
kv(){   printf '  %-30s %s\n' "$1" "$2"; }
ok(){   printf '  %s[ OK ]%s %s\n'   "$GRN" "$R" "$1"; }
warn(){ printf '  %s[WARN]%s %s\n'   "$YEL" "$R" "$1"; WARNS=$((WARNS+1)); }
fail(){ printf '  %s[FAIL]%s %s\n'   "$RED" "$R" "$1"; FAILS=$((FAILS+1)); }
note(){ printf '  %s%s%s\n' "$DIM" "$1" "$R"; }
tip(){  printf '  %s>> %s%s\n' "$MAG" "$1" "$R"; }

usage(){
  cat <<'EOF'
vasp_check.sh [DIR]   Post-mortem sanity + physics analysis of a VASP run.
                      DIR defaults to the current directory.
  -h, --help          Show this help.

WHAT IT CHECKS (physics coherence)
  1. File inventory      -- which VASP files are present and their sizes
  2. Run metadata        -- detected calc type (static SCF / ionic relax / AIMD /
                           DFPT / GW / RPA / BSE), XC (GGA / GGA+U / hybrid),
                           key INCAR tags (KPAR, NCORE, NBANDS, ENCUT, LORBIT...)
  3. Electronic (SCF)    -- convergence (NELM hits), entropy/atom, non-self-consistent
  4. Ionic convergence   -- EDIFFG criterion, max|F|, energy monotonicity (relaxations)
  5. Cell / stress       -- volume, lattice vectors, residual pressure (Pulay)
  6. Magnetization       -- net moment, per-atom moments, FM/AFM/ferri/nonmagnetic order
  7. Eigenvalues & gap   -- metal/insulator/half-metal, direct/indirect gap with the
                           VBM/CBM k-points, occupied bands, GW quasiparticle table
  8. Pitfalls            -- smearing choice, KPAR divisibility, NBANDS headroom,
                           GW knobs (NCORE=1, ENCUTGW default warning), LDA+U geometry
  Verdict               -- TOTEN, energy/atom, overall PASS / PASS-with-warnings / FAIL
  (Why a run died + data salvage -> vasp-diagnose)

READS (when present)
  OUTCAR  OSZICAR  INCAR  KPOINTS  POSCAR  CONTCAR  vasprun.xml
  EIGENVAL  DOSCAR  PROCAR  and any slurm-*.out / *.o<jobid>
  The INCAR echoed inside OUTCAR is the primary source of VASP parameters.

EXIT CODES
  0  PASS (clean or with warnings only)
  1  at least one FAIL flag raised
  2  usage error (bad option, DIR not found, no readable OUTCAR)
EOF
  exit "${1:-0}"
}

#------------------------------- arguments -----------------------------------
DIR="."
case "${1:-}" in
  -h|--help) usage 0 ;;
  "") : ;;
  -*) echo "error: unknown option '$1'" >&2; usage 2 ;;
  *) DIR="$1" ;;
esac
[[ -d "$DIR" ]] || { echo "error: '$DIR' is not a directory" >&2; exit 2; }
cd "$DIR" || { echo "error: cannot cd into '$DIR'" >&2; exit 2; }

OUT=OUTCAR; OSZ=OSZICAR; INC=INCAR
[[ -s $OUT ]] || { echo "error: no readable OUTCAR in $(pwd)" >&2; exit 2; }

printf '%s%s VASP run analysis: %s %s\n' "$B" "$CYN" "$(pwd)" "$R"

#--------------------------- parameter helpers -------------------------------
# getp TAG : first numeric value of "TAG = <num>" echoed in OUTCAR (defaults
#            already applied), falling back to INCAR.
getp(){
  local v
  v=$(awk -v t="$1" '
    match($0, t"[[:space:]]*=[[:space:]]*[-+0-9.][-+0-9.EeDd]*"){
      s=substr($0,RSTART,RLENGTH); sub(/.*=[[:space:]]*/,"",s);
      gsub(/[Dd]/,"E",s); print s; exit }' "$OUT")
  if [[ -z $v && -s $INC ]]; then
    v=$(awk -v t="$1" '
      /^[[:space:]]*[#!]/ {next}
      match($0, t"[[:space:]]*=[[:space:]]*[-+0-9.][-+0-9.EeDd]*"){
        s=substr($0,RSTART,RLENGTH); sub(/.*=[[:space:]]*/,"",s);
        gsub(/[Dd]/,"E",s); print s; exit }' "$INC")
  fi
  printf '%s' "$v"
}

# gettag TAG FILE : first RHS *string* token of "TAG = value", comments stripped,
#                   case-insensitive on the tag, anchored so LDAU != LDAUL etc.
gettag(){
  local t="$1" f="$2"
  [[ -s $f ]] || return 0
  awk -v t="$t" '
    { line=$0; sub(/[#!].*/,"",line); U=toupper(line); T=toupper(t);
      if (match(U, "(^|[ \t;])" T "[ \t]*=[ \t]*[^ \t;]+")) {
        s=substr(line,RSTART,RLENGTH);
        sub(/^[ \t;]+/,"",s); sub(/.*=[ \t]*/,"",s);
        print s; exit } }' "$f"
}
# value preferring INCAR (user intent) then OUTCAR (effective)
INCVAL(){ local v; v=$(gettag "$1" "$INC"); [[ -z $v ]] && v=$(gettag "$1" "$OUT"); printf '%s' "$v"; }

# getlog TAG : T/F for a logical, OUTCAR then INCAR
getlog(){
  local v
  v=$(grep -m1 -iE "(^|[[:space:];])$1[[:space:]]*=" "$OUT" 2>/dev/null)
  [[ -z $v && -s $INC ]] && v=$(grep -m1 -iE "(^|[[:space:];])$1[[:space:]]*=" "$INC" 2>/dev/null)
  if printf '%s' "$v" | grep -qiE '=[[:space:]]*\.?[Tt]'; then echo T; else echo F; fi
}
has(){ grep -qi -- "$1" "$OUT"; }
ucase(){ printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

#============================ 1. FILE INVENTORY ==============================
hdr "File inventory"
for f in OUTCAR OSZICAR INCAR KPOINTS POSCAR CONTCAR vasprun.xml EIGENVAL DOSCAR PROCAR WAVECAR CHGCAR; do
  # Three distinct states -- an empty file is NOT the same as a missing one:
  # VASP writes a 0-byte CONTCAR for a static run (NSW=0) and 0-byte CHG/CHGCAR
  # when LCHARG=.FALSE., so "(absent)" there would be plainly wrong.
  if   [[ -s $f ]]; then printf '  %-12s %s%10s B%s\n' "$f" "$DIM" "$(wc -c <"$f")" "$R"
  elif [[ -e $f ]]; then printf '  %-12s %s(empty -- 0 B)%s\n' "$f" "$DIM" "$R"
  else                   printf '  %-12s %s(absent)%s\n' "$f" "$DIM" "$R"; fi
done
note "For scheduler logs + WHY a run died (and whether the data is salvageable), use 'vasp-diagnose'."

#============================ 2. PARAMETERS + TYPE ===========================
NIONS=$(getp NIONS);   NIONS=${NIONS:-0}
NBANDS=$(getp NBANDS); ISPIN=$(getp ISPIN); NKPTS=$(getp NKPTS)
NELM=$(getp NELM);     NELMIN=$(getp NELMIN)
EDIFF=$(getp EDIFF);   EDIFFG=$(getp EDIFFG)
IBRION=$(getp IBRION); NSW=$(getp NSW); ISIF=$(getp ISIF); ICHARG=$(getp ICHARG)
ISMEAR=$(getp ISMEAR); SIGMA=$(getp SIGMA)
ENCUT=$(getp ENCUT);   LORBIT=$(getp LORBIT)
KPAR=$(getp KPAR);     NCORE=$(getp NCORE);  NPAR=$(getp NPAR)
NOMEGA=$(getp NOMEGA); ENCUTGW=$(getp ENCUTGW); NBANDSGW=$(getp NBANDSGW)
NTAUPAR=$(getp NTAUPAR); NOMEGAPAR=$(getp NOMEGAPAR)
HFSCREEN=$(getp HFSCREEN); AEXX=$(getp AEXX)
LSORBIT=$(getlog LSORBIT)
LHF=$(getlog LHFCALC)
# LDA+U: master switch OR any of the per-shell tags / banner
if [[ $(getlog LDAU) == T ]] || grep -qiE 'LDA\+U is selected|LDAUTYPE|LDAUL[[:space:]]*=' "$OUT" 2>/dev/null; then LDAU=T; else LDAU=F; fi
ALGO=$(INCVAL ALGO); ALGO_UC=$(ucase "$ALGO")
VASPVER=$(grep -m1 -E 'vasp\.[0-9]' "$OUT" | awk '{print $1}')
ENCUTGW_SET=$(gettag ENCUTGW "$INC")   # explicitly in INCAR? (empty -> defaulted)

# ---------- calculation-type decision tree (INCAR-driven) ----------
gw_family=0; gw_lowscaling=0; rpa=0; bse=0
case "$ALGO_UC" in
  *GW*)   gw_family=1 ;;
  RPA|ACFDT|ACFDTR|RPAR) rpa=1 ;;
  BSE|TDHF|TIMEEV)       bse=1 ;;
esac
# GW can also be implied by tags even if ALGO got masked (e.g. dry runs)
if [[ -n ${NOMEGA:-} && ${NOMEGA%.*} -gt 0 ]] || [[ -n ${NBANDSGW:-} ]]; then gw_family=1; fi
# QP table in OUTCAR is the strongest confirmation
grep -q 'QP-energies' "$OUT" 2>/dev/null && gw_family=1
# low-scaling space-time / cubic GW: ALGO is a GW variant ending in R, OR partitioning tags explicitly > 0
[[ $ALGO_UC == *GW* && $ALGO_UC == *R ]] && { gw_family=1; gw_lowscaling=1; }
ntp=${NTAUPAR%.*}; nop=${NOMEGAPAR%.*}
[[ ${ntp:-0} =~ ^-?[0-9]+$ && ${ntp:-0} -gt 0 ]] && { gw_family=1; gw_lowscaling=1; }
[[ ${nop:-0} =~ ^-?[0-9]+$ && ${nop:-0} -gt 0 ]] && { gw_family=1; gw_lowscaling=1; }

CALC_BASE=""
if   ((gw_family)); then CALC_BASE="GW"
elif ((rpa));       then CALC_BASE="RPA/ACFDT"
elif ((bse));       then CALC_BASE="BSE"
elif [[ ${IBRION%.*} =~ ^(5|6|7|8)$ ]] || [[ $(getlog LEPSILON) == T || $(getlog LCALCEPS) == T ]]; then
     CALC_BASE="DFPT/linear-response"
elif [[ ${NSW:-0} != "" && ${NSW%.*} -gt 0 && ${IBRION:-2} != "" ]]; then
     if [[ ${IBRION%.*} == 0 ]]; then CALC_BASE="AIMD"
     else
       case "${ISIF%.*}" in
         3|6|7) CALC_BASE="cell relaxation (ISIF=${ISIF%.*}, cell+ions)";;
         4|5)   CALC_BASE="cell relaxation (ISIF=${ISIF%.*}, shape, fixed V)";;
         *)     CALC_BASE="ionic relaxation (ISIF=${ISIF:-2})";;
       esac
     fi
elif [[ ${ICHARG%.*} == 11 ]]; then
     CALC_BASE="non-self-consistent (ICHARG=11: band structure or DOS)"
else CALC_BASE="static SCF"
fi

# XC layer (AEXX-aware). NOTE: a GW run sets LHFCALC=T / AEXX=1.0 internally for the self-energy;
# that is NOT a hybrid groundstate, so for GW we report the underlying functional instead.
CALC_XC="GGA"
# META-GGA (SCAN / r2SCAN / TPSS / M06-L ...) is a different rung of the ladder and
# behaves differently (tau-dependent potential, needs LASPH, noisier forces), so it
# must not be reported as plain "GGA". VASP echoes the tag into the OUTCAR; fall back
# to the INCAR. LDA is only assumed when GGA is explicitly switched off.
# (getp only matches NUMERIC values, and METAGGA's value is a word -- read it directly.)
_mgga="$(grep -m1 -aoiE 'METAGGA[[:space:]]*=[[:space:]]*[A-Za-z0-9_-]+' "$OUT" 2>/dev/null \
         | sed -E 's/.*=[[:space:]]*//')"
if [[ -z $_mgga && -s $INC ]]; then
  _mgga="$(grep -m1 -aoiE '^[[:space:]]*METAGGA[[:space:]]*=[[:space:]]*[A-Za-z0-9_-]+' "$INC" 2>/dev/null \
           | sed -E 's/.*=[[:space:]]*//')"
fi
if [[ -n $_mgga && ! $_mgga =~ ^([Nn]one|--)$ ]]; then
  CALC_XC="meta-GGA (${_mgga})"
fi
ax=${AEXX:-0}
if [[ $LHF == T ]] && ! ((gw_family)); then
  if [[ -n ${HFSCREEN:-} ]] && awk -v s="${HFSCREEN:-0}" 'BEGIN{exit !(s>0)}'; then CALC_XC="HSE-type screened hybrid"
  elif awk -v a="$ax" 'BEGIN{exit !(a>=0.18 && a<=0.32)}'; then CALC_XC="PBE0-type hybrid (AEXX=${ax})"
  elif awk -v a="$ax" 'BEGIN{exit !(a>=0.95)}'; then CALC_XC="Hartree-Fock (AEXX=1)"
  else CALC_XC="hybrid (AEXX=${ax})"; fi
fi
[[ $LDAU == T ]] && CALC_XC="${CALC_XC}+U"

# GW flavour text
GW_FLAVOUR=""
if ((gw_family)); then
  case "$ALGO_UC" in
    G0W0*) GW_FLAVOUR="G0W0 (single-shot, no self-consistency)";;
    GW0*|EVGW0*) GW_FLAVOUR="GW0/EVGW0 (eigenvalue self-consistency in G; W fixed at DFT)";;
    QPGW*|SCGW*|GW*) GW_FLAVOUR="QP/scGW (self-consistent quasiparticle)";;
    *) GW_FLAVOUR="GW family (ALGO=${ALGO:-?})";;
  esac
  ((gw_lowscaling)) && GW_FLAVOUR="$GW_FLAVOUR  [low-scaling / space-time]"
fi

hdr "Run metadata"
kv "VASP version"        "${VASPVER:-?}"
kv "Atoms (NIONS)"       "${NIONS:-?}"
kv "Bands (NBANDS)"      "${NBANDS:-?}"
kv "k-points (NKPTS)"    "${NKPTS:-?}"
kv "ISPIN  (SOC)"        "${ISPIN:-?}    ($LSORBIT)"
kv "ENCUT (eV)"          "${ENCUT:-?}"
kv "ISMEAR / SIGMA"      "${ISMEAR:-?} / ${SIGMA:-?}"
kv "EDIFF / EDIFFG"      "${EDIFF:-?} / ${EDIFFG:-?}"
kv "IBRION/NSW/ISIF"     "${IBRION:-?} / ${NSW:-?} / ${ISIF:-?}"
kv "ICHARG"             "${ICHARG:-?}"
kv "KPAR/NCORE/NPAR"     "${KPAR:-?} / ${NCORE:-?} / ${NPAR:-?}"
kv "LORBIT"             "${LORBIT:-?}"
kv "${B}Detected type${R}"  "$B$CALC_BASE$R  ${DIM}[$CALC_XC]$R"
[[ -n $GW_FLAVOUR ]] && kv "GW flavour" "$GW_FLAVOUR"
if ((gw_family)); then
  nbgw="${NBANDSGW:-?}"; [[ ${NBANDSGW%.*} == -1 ]] && nbgw="default(all)"
  kv "GW knobs" "NOMEGA=${NOMEGA:-?}  ENCUTGW=${ENCUTGW:-?}$([[ -z $ENCUTGW_SET ]] && echo ' (defaulted=2/3*ENCUT)')  NBANDSGW=${nbgw}$( ((gw_lowscaling)) || echo '  (conventional quartic-scaling: NTAUPAR/NOMEGAPAR off)')"
  [[ $LHF == T ]] && note "LHFCALC=T / AEXX=${AEXX:-1.0} here are GW's internal exact-exchange settings for the self-energy, not a hybrid groundstate."
fi

#============================ 3. TERMINATION =================================
hdr "Run completion (physics prerequisites)"
# Convergence markers the physics sections below rely on. WHY a run died (OOM /
# walltime / crash) and whether its data is still usable (PLOTTABLE / PARTIAL /
# NOT) now live in `vasp-diagnose` -- run that on a failed folder. vasp-check is
# physics-only: it interprets whatever data is present.
RELAX_DONE=0; SCF_CONVERGED=0
grep -qiE 'reached required accuracy - stopping structural energy minimi[sz]ation' "$OUT" && RELAX_DONE=1
grep -q 'aborting loop because EDIFF is reached' "$OUT" && SCF_CONVERGED=1
# Is this a multi-step RELAXATION? Then electronic convergence proves NOTHING about
# the run finishing: 'aborting loop because EDIFF is reached' is printed once per
# IONIC step, so it is already true at step 1 of 150. Only the ionic marker
# ('reached required accuracy - stopping structural energy minimisation') or the
# timing footer mean the run is done. Treating SCF_CONVERGED as completion made a
# live relaxation report "[ OK ] converged" here while section 5 simultaneously
# reported "[WARN] relaxation did NOT meet EDIFFG" -- a self-contradicting report.
IS_RELAX=0
[[ ${NSW:-0} =~ ^[0-9]+$ ]] && (( NSW > 1 )) && [[ ${IBRION:--1} != "-1" ]] && IS_RELAX=1
if grep -q 'General timing and accounting' "$OUT"; then
  ok "Normal termination (timing footer present)."
elif ((RELAX_DONE)); then
  ok "Reached required accuracy (converged); timing footer absent (OUTCAR likely truncated after the run)."
elif ((IS_RELAX)); then
  note "Relaxation still IN PROGRESS or interrupted: the ionic loop never printed"
  note "  'reached required accuracy' and there is no timing footer. The SCF converges"
  note "  at every ionic step, but that is not run completion. Everything below"
  note "  describes the LATEST ionic geometry, not a converged structure."
elif ((SCF_CONVERGED)); then
  ok "SCF converged (EDIFF reached); timing footer absent (OUTCAR likely truncated after the run)."
else
  note "No completion marker -- this run may have been killed/truncated."
  note "Run 'vasp-diagnose' here for the CAUSE + whether the data is salvageable; the physics below uses whatever survived."
fi

#============================ 4. ELECTRONIC SCF =============================
hdr "Electronic (SCF) convergence"
NONSCF=0; [[ $CALC_BASE == non-self* || ${ICHARG%.*} == 11 ]] && NONSCF=1
# A NELM that the user deliberately capped is not non-convergence. Two cases where
# reaching it is the INTENDED outcome, not a failure:
#   * NELM=1 -- you asked for exactly one step, so "it took one" cannot be a
#     shortfall. This is the GW first step (ALGO=Exact, NELM=1, LOPTICS=.TRUE.),
#     which this very script recommends a few sections further down; flagging it
#     as non-convergence contradicted our own advice on a correct run.
#   * ALGO=Exact / IALGO=90 -- a one-shot LAPACK diagonalisation, which does not
#     self-consist by construction.
DELIBERATE_CAP=0
[[ ${NELM%.*} == 1 ]] && DELIBERATE_CAP=1
_algo="$(gettag ALGO "$OUT")"; [[ -z $_algo ]] && _algo="$(gettag ALGO "$INC")"
[[ ${_algo^^} == EXACT || ${_algo^^} == DIAG ]] && DELIBERATE_CAP=1
if [[ -s $OSZ ]]; then
  # NB: `while ... done < <(cmd)`, NOT `cmd | while`. A pipeline runs its right-hand
  # side in a SUBSHELL, so every warn/fail raised in the loop body incremented a copy
  # of WARNS/FAILS that was discarded on exit -- the counters, and therefore the exit
  # status, never saw them. Process substitution keeps the body in this shell.
  while IFS= read -r line; do
      if [[ $line == *"__NELMHIT__"* ]]; then
        if ((NONSCF)); then note "${line#  __NELMHIT__ } (expected: fixed-charge run does not self-consist)"
        elif ((DELIBERATE_CAP)); then
          note "${line#  __NELMHIT__ } (expected: NELM=${NELM%.*}${_algo:+ with ALGO=$_algo} is a deliberate single-shot step, not a failed SCF)"
        else fail "${line#  __NELMHIT__ } -> non-convergence; raise NELM, adjust mixing (AMIX/BMIX), or ALGO."; fi
      else printf '%s\n' "$line"; fi
  done < <(awk -v nelm="${NELM%.*}" '
    /^[[:space:]]*[A-Za-z]+:[[:space:]]+[0-9]+[[:space:]]/ { ec++; next }
    /F=/ { ionic++; tot+=ec; maxec=(ec>maxec?ec:maxec);
           if (nelm>0 && ec>=nelm) { stuck++; bad[stuck]=ionic" ("ec")"; } ec=0 }
    END{ printf "  ionic steps logged : %d\n", ionic;
         printf "  max SCF iters/step : %d  (NELM=%s)\n", maxec, (nelm>0?nelm:"?");
         printf "  total SCF iters    : %d\n", tot;
         if (stuck>0){ printf "  __NELMHIT__ %d step(s) hit NELM:", stuck;
            for(i=1;i<=stuck && i<=8;i++) printf " %s", bad[i]; printf "\n" } }' "$OSZ")
  if ! awk -v nelm="${NELM%.*}" '/^[[:space:]]*[A-Za-z]+:[[:space:]]+[0-9]+/{n=$2} /F=/{if(nelm>0 && n>=nelm)c++} END{exit (c>0?0:1)}' "$OSZ"; then
    ((NONSCF)) || ok "Every ionic step converged electronically below NELM."
  fi
else
  warn "No OSZICAR -> SCF trajectory unavailable."
fi
((NONSCF)) && note "Non-self-consistent run (ICHARG=11): charge density is frozen; 'convergence' = one diagonalisation pass. Ensure the CHGCAR came from a converged self-consistent run."

# smearing entropy per atom
EENTRO=$(grep 'EENTRO' "$OUT" | tail -n1 | awk '{print $NF}')
if [[ -n ${EENTRO:-} && ${NIONS%.*} -gt 0 ]]; then
  TSpa=$(awk -v e="$EENTRO" -v n="${NIONS%.*}" 'BEGIN{printf "%.3e", (e<0?-e:e)/n}')
  kv "Entropy |T*S|/atom (eV)" "$TSpa"
  if awk -v x="$TSpa" 'BEGIN{exit !(x>1e-3)}'; then
    warn "Smearing entropy/atom > 1 meV: metallic DOS at E_F, or SIGMA too large."
  else ok "Smearing entropy negligible -> insulating/gapped solution."; fi
fi

#============================ 5. IONIC / FORCES =============================
if [[ $CALC_BASE == *relax* ]]; then
  hdr "Ionic convergence & forces"
  if ((RELAX_DONE)); then
    ok "Relaxation converged (reached required accuracy)."
  else
    warn "No 'reached required accuracy' -> relaxation did NOT meet EDIFFG (still running / hit NSW / killed)."
  fi
  while IFS= read -r l; do [[ $l == *"__NOFORCE__"* ]] && { warn "No TOTAL-FORCE block found."; continue; }; printf '%s\n' "$l"
  done < <(awk '
    /TOTAL-FORCE/ { inb=1; started=0; cmax=0; ss=0; n=0; next }
    inb && /^[[:space:]]*-+[[:space:]]*$/ {
      if(!started){started=1; next}
      else { blk++; traj[blk]=cmax; fmax=cmax; frms=sqrt(ss/(n>0?n:1)); fn=n; inb=0; started=0; next } }
    inb && started { m=sqrt($4*$4+$5*$5+$6*$6); if(m>cmax)cmax=m; ss+=m*m; n++ }
    /total drift:/ { dx=$3; dy=$4; dz=$5 }
    END{ if(blk==0){print "  __NOFORCE__"; exit}
         printf "  force blocks (ionic) : %d\n", blk;
         printf "  final max |F| (eV/A) : %.4f\n", fmax;
         printf "  final RMS |F| (eV/A) : %.4f   over %d atoms\n", frms, fn;
         if(dx!=""){d=sqrt(dx*dx+dy*dy+dz*dz); printf "  total drift |d|      : %.4f   [%.1e %.1e %.1e]\n", d, dx,dy,dz}
         s=(blk>12?blk-11:1); printf "  max|F| trajectory    :"; for(i=s;i<=blk;i++) printf " %.3f", traj[i]; printf "\n" }' "$OUT")

  FMAX=$(awk '/TOTAL-FORCE/{inb=1;st=0;cmax=0;next}
              inb&&/^[[:space:]]*-+[[:space:]]*$/{if(!st){st=1;next}else{fm=cmax;inb=0;st=0;next}}
              inb&&st{m=sqrt($4*$4+$5*$5+$6*$6);if(m>cmax)cmax=m} END{printf "%.5f", fm}' "$OUT")
  if [[ -n ${EDIFFG:-} ]] && awk -v g="$EDIFFG" 'BEGIN{exit !(g<0)}'; then
    THR=$(awk -v g="$EDIFFG" 'BEGIN{printf "%.5f", -g}')
    if awk -v f="$FMAX" -v t="$THR" 'BEGIN{exit !(f<=t)}'; then ok "max|F|=${FMAX} <= |EDIFFG|=${THR} eV/A."
    else warn "max|F|=${FMAX} > |EDIFFG|=${THR} eV/A (selective-dynamics-fixed atoms excluded by VASP's own test)."; fi
  else note "EDIFFG>=0 -> energy-based stopping; force threshold not applied."; fi

  if [[ -s $OSZ ]]; then
    while IFS= read -r l; do [[ $l == *"__ENUP__"* ]] && { warn "${l#  __ENUP__ }"; continue; }; printf '%s\n' "$l"
    done < <(awk '/F=/{e=$3; gsub(/[Dd]/,"E",e); v[++k]=e+0}
         END{ if(k<2){print "  single ionic point (monotonicity n/a)"; exit}
              up=0; for(i=2;i<=k;i++) if(v[i]>v[i-1]+1e-6) up++;
              printf "  ionic energy steps   : %d   dE(last)= %.3e eV\n", k, v[k]-v[k-1];
              if(up>0) printf "  __ENUP__ %d uphill energy move(s) (step too large / rough PES?)\n", up;
              else     printf "  energy monotonically non-increasing across ionic steps.\n" }' "$OSZ")
  fi
fi

#=================== 5b. STRUCTURE EQUILIBRIUM (non-relax) ==================
# "Is the geometry I am sitting on actually relaxed?" A STATIC run answers this
# completely: VASP prints the forces and the stress tensor at that geometry
# whether or not you asked it to move anything. Previously the whole force
# analysis was gated behind `CALC_BASE == *relax*`, so a static SCF -- the very
# run you do to VERIFY a relaxation -- reported no forces at all.
# Ions are judged by the forces, the cell by the stress: they are independent,
# and a structure can be converged in one and not the other.
if [[ $CALC_BASE != *relax* ]] && grep -qa 'TOTAL-FORCE' "$OUT"; then
  hdr "Structure equilibrium (is this geometry relaxed?)"
  eval "$(awk '
    /TOTAL-FORCE/ { inb=1; st=0; cmax=0; ss=0; n=0; im=0; mx=0; my=0; mz=0; next }
    inb && /^[[:space:]]*-+[[:space:]]*$/ { if(!st){st=1;next} else {inb=0;st=0;next} }
    inb && st {
      n++
      ax=($4<0?-$4:$4); ay=($5<0?-$5:$5); az=($6<0?-$6:$6)
      if(ax>mx)mx=ax; if(ay>my)my=ay; if(az>mz)mz=az
      m=sqrt($4*$4+$5*$5+$6*$6); ss+=m*m
      if(m>cmax){cmax=m; im=n}
      F_MAX=cmax; F_RMS=sqrt(ss/n); F_N=n; F_ION=im; MX=mx; MY=my; MZ=mz }
    /total drift:/ { dx=$3; dy=$4; dz=$5 }
    # stress: "  in kB   XX YY ZZ XY YZ ZX" (last ionic step wins)
    /^[[:space:]]*in kB/ { sxx=$3; syy=$4; szz=$5; sxy=$6; syz=$7; szx=$8; HAVE_S=1 }
    # VASP really does misspell it "Pullay"; match both.
    /external pressure/ {
      for(i=1;i<=NF;i++){ if($i=="pressure" && $(i+1)=="=") P=$(i+2)
                          if($i ~ /^Pu?ll?ay$/ && $(i+2)=="=") PUL=$(i+3) } }
    # NB: -0.0 < 0 is FALSE in awk, so a naive abs() propagates the sign and the
    # report prints "-0.0000" for a stress component that is exactly zero.
    function a(x){ x=x+0; if(x<0) return -x; return x==0 ? 0 : x }
    END{
      if(F_N+0==0){ print "NOFORCE=1"; exit }
      printf "F_MAX=%.5f\nF_RMS=%.5f\nF_N=%d\nF_ION=%d\n", F_MAX, F_RMS, F_N, F_ION
      printf "MX=%.6f\nMY=%.6f\nMZ=%.6f\n", MX, MY, MZ
      if(dx!="") printf "DRIFT=%.5f\n", sqrt(dx*dx+dy*dy+dz*dz)
      if(HAVE_S){
        sd=a(sxx); if(a(syy)>sd)sd=a(syy); if(a(szz)>sd)sd=a(szz)
        so=a(sxy); if(a(syz)>so)so=a(syz); if(a(szx)>so)so=a(szx)
        printf "S_DIAG=%.4f\nS_OFF=%.4f\nHAVE_S=1\n", sd, so }
      if(P!="")   printf "PRESS=%.4f\n", P
      if(PUL!="") printf "PULAY=%.4f\n", PUL }' "$OUT")"

  if [[ -n ${NOFORCE:-} ]]; then
    warn "TOTAL-FORCE header present but no force rows parsed (OUTCAR truncated mid-block)."
  else
  note "Forces and stress are printed at THIS geometry, so they judge the"
  note "structure directly -- no relaxation run is needed to answer the question."
  kv "max |F| (eV/A)"      "$F_MAX   on ion $F_ION of $F_N"
  kv "RMS |F| (eV/A)"      "$F_RMS"
  [[ -n ${DRIFT:-} ]] && kv "total drift |d| (eV/A)" "$DRIFT"

  # A Cartesian direction with identically zero force on EVERY ion is locked by
  # symmetry, not converged by the optimiser. Worth saying: it means the run never
  # explored that direction, so "relaxed" holds only within the imposed symmetry.
  LOCKED=""
  awk -v v="$MX" 'BEGIN{exit !(v<1e-9)}' && LOCKED="${LOCKED}x "
  awk -v v="$MY" 'BEGIN{exit !(v<1e-9)}' && LOCKED="${LOCKED}y "
  awk -v v="$MZ" 'BEGIN{exit !(v<1e-9)}' && LOCKED="${LOCKED}z "
  [[ -n $LOCKED ]] && kv "symmetry-locked dirs" "${LOCKED% } (force identically 0 on every ion)"

  if [[ -n ${HAVE_S:-} ]]; then
    kv "max |stress| diag (kB)" "$S_DIAG"
    kv "max |stress| shear (kB)" "$S_OFF"
  fi
  [[ -n ${PRESS:-} ]] && kv "external pressure (kB)" "$PRESS${PULAY:+   (Pulay corr $PULAY)}"

  # --- IONS: use |EDIFFG| when the user set a force criterion, else 0.03 eV/A ---
  FTHR=0.03; FSRC="default"
  if [[ -n ${EDIFFG:-} ]] && awk -v g="$EDIFFG" 'BEGIN{exit !(g<0)}'; then
    FTHR=$(awk -v g="$EDIFFG" 'BEGIN{printf "%.5f", -g}'); FSRC="EDIFFG"
  fi
  if awk -v f="$F_MAX" 'BEGIN{exit !(f<=0.01)}'; then
    ok "IONS at equilibrium: max|F| = ${F_MAX} <= 0.01 eV/A (tight)."
  elif awk -v f="$F_MAX" -v t="$FTHR" 'BEGIN{exit !(f<=t)}'; then
    ok "IONS at equilibrium: max|F| = ${F_MAX} <= ${FTHR} eV/A (${FSRC})."
  elif awk -v f="$F_MAX" 'BEGIN{exit !(f<=0.05)}'; then
    warn "IONS marginal: max|F| = ${F_MAX} eV/A is above ${FTHR} (${FSRC}) but below 0.05 -- usable for energies, re-relax before forces/phonons."
  else
    warn "IONS NOT relaxed: max|F| = ${F_MAX} eV/A. This geometry is not a stationary point."
  fi

  # --- CELL: residual pressure maps to a volume error via P/B (B ~ 1000 kB for a
  # typical solid), so 0.5 kB is ~0.05% in volume -- negligible; 2 kB ~0.2%.
  if [[ -n ${PRESS:-} ]]; then
    AP=$(awk -v p="$PRESS" 'BEGIN{printf "%.4f", (p<0?-p:p)}')
    if awk -v p="$AP" 'BEGIN{exit !(p<=0.5)}'; then
      ok "CELL at equilibrium: |P| = ${AP} kB <= 0.5 kB (~0.05% in volume)."
    elif awk -v p="$AP" 'BEGIN{exit !(p<=2.0)}'; then
      note "CELL nearly relaxed: |P| = ${AP} kB (~0.2% in volume). Fine for most properties."
    else
      warn "CELL NOT relaxed: |P| = ${AP} kB residual pressure -> re-relax with ISIF=3."
    fi
    if [[ -n ${HAVE_S:-} ]] && awk -v s="$S_OFF" 'BEGIN{exit !(s>0.1)}'; then
      warn "Residual SHEAR ${S_OFF} kB (off-diagonal stress) -> the cell SHAPE is not relaxed, only its volume."
    fi
    # Pulay: with a basis frozen at the starting cell the pressure is biased. VASP
    # prints the correction it applied; 0 means none was subtracted.
    if [[ -z ${PULAY:-} ]] || awk -v p="${PULAY:-0}" 'BEGIN{exit !((p<0?-p:p)<1e-6)}'; then
      tip "Pulay correction is 0: the stress is computed with the basis frozen at this cell, so |P| is biased by basis incompleteness. To trust it to <1 kB, re-run this static at ENCUT x1.3 and confirm the pressure barely moves."
    fi
  fi
  [[ -n $LOCKED ]] && tip "Because ${LOCKED% } is symmetry-locked, small forces prove equilibrium only WITHIN the imposed symmetry. A symmetry-breaking distortion (Peierls/Jahn-Teller) would not show up here -- test it with ISYM=0 on a slightly perturbed POSCAR."
  fi
fi

#============================ 6. CELL / STRESS =============================
if [[ $CALC_BASE == *relax* || $CALC_BASE == "static SCF" || ((gw_family)) ]]; then
  hdr "Cell, volume & stress"
  VOL=$(grep 'volume of cell' "$OUT" | tail -n1 | awk '{print $NF}')
  kv "Final cell volume (A^3)" "${VOL:-?}"
  LV=$(grep -A1 'length of vectors' "$OUT" | tail -n1)
  [[ -n $LV ]] && kv "|a| |b| |c| (A)" "$(echo "$LV" | awk '{printf "%.4f %.4f %.4f", $1,$2,$3}')"
  PRESS=$(grep 'external pressure' "$OUT" | tail -n1)
  if [[ -n $PRESS ]]; then
    P=$(echo "$PRESS" | awk '{for(i=1;i<=NF;i++) if($i=="pressure"){print $(i+2); break}}')
    PUL=$(echo "$PRESS" | awk '{print $(NF-1)}')
    kv "External pressure (kB)" "${P:-?}   (Pulay corr ~ ${PUL:-?} kB)"
    if [[ $CALC_BASE == *cell* ]] && awk -v p="${P:-0}" 'BEGIN{exit !((p<0?-p:p)>5)}'; then
      warn "Residual |pressure| > 5 kB after a cell relaxation -> raise ENCUT/PREC and re-relax (Pulay stress)."
    fi
  fi
fi

#==================== 6b. WHAT THE RELAXATION DID ==========================
# "reached required accuracy" says the forces are small. It does not say WHAT
# the run did to the structure, and that is usually the thing worth knowing: a
# relaxation can converge beautifully onto a cell that collapsed, an atom that
# hopped site, or a symmetry that rose (ISYM freezing you into a saddle point)
# or fell. None of that is visible in the force table above.
#
# For a relaxation this diffs POSCAR against CONTCAR; for a static run there is
# nothing to diff, so it just describes the geometry that was computed. The work
# is pymatgen's, in wolfpack_structure.py -- vasp-check runs on a login node, so
# unlike the job-side tools it may import python freely. If it cannot, the
# section says so and the rest of the report is unaffected.
_wp_struct="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wolfpack_structure.py"
_wp_py="$(command -v python3 || command -v python || true)"

# WHICH "BEFORE" TO DIFF AGAINST.
#
# A chunked relaxation (vasp-relax-loop) restarts from its own CONTCAR: at the
# end of every chunk the chain does `cp CONTCAR POSCAR` so the next chunk
# resumes from the geometry reached so far. After five chunks the POSCAR in
# this directory is the geometry chunk five STARTED from -- not the one the
# relaxation started from.
#
# Diffing POSCAR against CONTCAR there answers a question nobody asked ("what
# did the last chunk move?") under a heading that says something else, and the
# answer is small and reassuring precisely when the whole relaxation has
# wandered a long way. Nothing about the output reveals it.
#
# The chain already keeps the real thing. Every chunk archives the geometry it
# began with, so chunk 001's copy IS the original input, and it is left
# compressed exactly as the chain wrote it.
_start_struct="POSCAR"; _start_label="POSCAR"
_chunk0="$(ls -d wolfpack_chain/chunk-* 2>/dev/null | sort | head -1)"
_wp_tmp_start=""
if ((IS_RELAX)) && [[ -n "$_chunk0" ]]; then
  for _c in "$_chunk0/POSCAR.in.gz" "$_chunk0/POSCAR.in"; do
    [[ -s "$_c" ]] || continue
    _wp_tmp_start="$(mktemp -t wpcheck_poscar0.XXXXXX)" || break
    if [[ "$_c" == *.gz ]]; then gzip -dc "$_c" > "$_wp_tmp_start" 2>/dev/null
    else cp -f "$_c" "$_wp_tmp_start" 2>/dev/null; fi
    if [[ -s "$_wp_tmp_start" ]]; then
      _start_struct="$_wp_tmp_start"
      _start_label="${_chunk0}/$(basename "$_c")"
      break
    fi
    rm -f "$_wp_tmp_start"; _wp_tmp_start=""
  done
fi
trap '[[ -n "${_wp_tmp_start:-}" ]] && rm -f "$_wp_tmp_start"' EXIT

if [[ -f "$_wp_struct" && -n "$_wp_py" && -s "$_start_struct" ]]; then
  if ((IS_RELAX)) && [[ -s CONTCAR ]]; then
    if [[ "$_start_struct" == "POSCAR" ]]; then
      hdr "What the relaxation changed (POSCAR -> CONTCAR)"
    else
      # Say which file the "before" came from. A report that silently swapped
      # its own input would be as opaque as the bug it fixes.
      hdr "What the relaxation changed (whole chain: $_start_label -> CONTCAR)"
      _nch=$(ls -d wolfpack_chain/chunk-* 2>/dev/null | wc -l)
      note "chunked run: comparing against the geometry the FIRST of $_nch chunk(s)"
      note "started from, not the POSCAR in this folder -- the chain overwrites"
      note "that one at every restart."
    fi
    if ! "$_wp_py" "$_wp_struct" "$_start_struct" CONTCAR 2>&1; then
      note "structure report unavailable (pymatgen missing? 'conda activate wolfpack-dft')"
    fi
  elif ((IS_RELAX)); then
    hdr "What the relaxation changed (POSCAR -> CONTCAR)"
    note "CONTCAR is missing or empty -- nothing to compare against yet."
  else
    hdr "Structure of this calculation"
    if ! "$_wp_py" "$_wp_struct" POSCAR 2>&1; then
      note "structure report unavailable (pymatgen missing? 'conda activate wolfpack-dft')"
    fi
  fi
fi

#======================= 7. MAGNETIZATION ===================================
if [[ ${ISPIN%.*} == 2 || $LSORBIT == T ]]; then
  hdr "Magnetization"
  NETMAG=$(awk '/mag=/{for(i=1;i<=NF;i++) if($i=="mag="){m=$(i+1)}} END{print m}' "$OSZ" 2>/dev/null)
  # fallback: VASP prints "number of electron  N   magnetization  M" each step (independent of LORBIT)
  [[ -z ${NETMAG:-} ]] && NETMAG=$(awk '/number of electron/ && /magnetization/{m=$NF} END{print m}' "$OUT")
  [[ -n ${NETMAG:-} ]] && kv "Net cell moment (uB)" "$NETMAG"
  PERAT=$(awk '
    /magnetization \(x\)/ { cap=1; n=0; delete v; next }
    cap && /# of ion/      { hd=1; next }
    cap && hd && /^[[:space:]]*-+/ { dash++; if(dash==2){cap=0;hd=0;dash=0}; next }
    cap && hd && /^[[:space:]]*[0-9]+[[:space:]]/ { n++; v[n]=$NF }
    END{ for(i=1;i<=n;i++) printf "%d:%.3f ", i, v[i] }' "$OUT")
  if [[ -n $PERAT ]]; then
    note "per-atom m_tot (uB):"
    printf '%s\n' "$PERAT" | tr ' ' '\n' | awk -F: 'NF==2{printf "  ion %-4s % 7.3f", $1, $2; if(++c%5==0)printf "\n"} END{if(c%5)printf "\n"}'
    while IFS= read -r l; do case "$l" in
        *__NONMAG__*) note "Negligible local moments everywhere -> nonmagnetic solution (consistent with closed-shell ions, e.g. Cu+ d10 / V5+ d0). If you expected magnetism, re-seed MAGMOM, check NUPDOWN and ISYM.";;
        *__AFM__*)    ok "Zero net moment but large alternating local moments -> antiferromagnetic ordering (physical).";;
        *)            printf '%s\n' "$l";; esac
    done < <(awk -v s="$PERAT" 'BEGIN{
      n=split(s,a," "); sum=0; absmax=0; nbig=0;
      for(i=1;i<=n;i++){ split(a[i],b,":"); m=b[2]+0; sum+=m; am=(m<0?-m:m); if(am>absmax)absmax=am; if(am>0.2)nbig++ }
      printf "  sum m = %+.3f uB ; max|m| = %.3f uB ; sites |m|>0.2 = %d\n", sum, absmax, nbig;
      if(absmax<0.1){ print "__NONMAG__" }
      else if((sum<0?-sum:sum)<0.1 && nbig>=2){ print "__AFM__" } }')
  else
    if [[ -n ${NETMAG:-} ]] && awk -v m="$NETMAG" 'BEGIN{exit !((m<0?-m:m)<0.05)}'; then
      note "Per-atom block absent (LORBIT=0), but net moment ~0 -> nonmagnetic / fully compensated. Set LORBIT=11 to resolve per-site moments (AFM vs nonmagnetic)."
    else
      note "Per-atom magnetization block not found (set LORBIT=10/11 to print per-site moments)."
    fi
  fi
fi

#==================== 8. EIGENVALUES / OCCUPATIONS / GAP ====================
hdr "Eigenvalues, occupations & gap (KS / DFT+U)"
EF=$(grep 'E-fermi' "$OUT" | tail -n1 | awk '{for(i=1;i<=NF;i++) if($i=="E-fermi"){print $(i+2); break}}')
kv "E-fermi (eV)" "${EF:-?}"

# --- VASP's OWN gap determination (authoritative; prints VBM/CBM with k-coords) ---
while IFS= read -r l; do
    [[ $l == NOVASPGAP ]] && { note "VASP did not print an explicit gap block (metal, or ISMEAR/run type suppresses it) -> using occupation scan below."; continue; }
    printf '%s\n' "$l"
done < <(awk '
  /val\. band max:/ {
    for(i=1;i<=NF;i++) if($i=="@"){ai=i} ; for(i=1;i<=NF;i++) if($i=="="){ei=i}
    vmax=$(ai-1)+0; vx=$(ei+1); vy=$(ei+2); vz=$(ei+3); next }
  /cond\. band min:/ {
    for(i=1;i<=NF;i++) if($i=="@"){ai=i} ; for(i=1;i<=NF;i++) if($i=="="){ei=i}
    cmin=$(ai-1)+0; cx=$(ei+1); cy=$(ei+2); cz=$(ei+3); next }
  /fundamental gap:/ { g=$NF+0; sg=g; svm=vmax; scm=cmin; svx=vx;svy=vy;svz=vz; scx=cx;scy=cy;scz=cz; got=1; next }
  END{
    if(!got){ print "NOVASPGAP"; exit }
    kind=(svx==scx && svy==scy && svz==scz ? "DIRECT":"INDIRECT");
    printf "  fundamental gap (VASP): %.4f eV   (%s)\n", sg, kind;
    printf "  VBM (val. band max)  : % .4f eV   @ k = (%s %s %s)\n", svm, svx,svy,svz;
    printf "  CBM (cond. band min) : % .4f eV   @ k = (%s %s %s)\n", scm, scx,scy,scz;
  }' "$OUT")

# --- independent occupation-based cross-check (also catches partial occupancy / metal) ---
while IFS= read -r l; do case "$l" in
    NODATA) warn "No final eigenvalue block in OUTCAR (NWRITE too low or truncated).";;
    *__INSULATOR__*) ok "No partial occupations across E_F -> clean insulator/semiconductor.";;
    *__METAL__*)     warn "VBM>=CBM with fractional occupations -> metallic (or smearing bridges a tiny gap).";;
    *) printf '%s\n' "$l";; esac
done < <(awk -v ef="${EF:-0}" '
  function abs(x){return x<0?-x:x}
  /spin component/ { sp=$NF+0; next }
  /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ {
    for(i=1;i<=NF;i++) if($i==":"){ci=i; break}
    kp=$(ci-1)+0; KX[kp]=$(ci+1); KY[kp]=$(ci+2); KZ[kp]=$(ci+3); inb=0; next }
  /band No\./ && $0 !~ /KS-energies/ { inb=1; if(sp=="")sp=1; next }   # DFT occ block only, not QP table
  inb && $1 ~ /^[0-9]+$/ && NF>=3 {
    bi=$1+0; en=$2+0; oc=$3+0; key=sp SUBSEP kp SUBSEP bi;
    E[key]=en; O[key]=oc; SP[key]=sp; KPk[key]=kp; BI[key]=bi; SEEN[key]=1;
    if(oc>omax)omax=oc;
    next }
  inb && /^[[:space:]]*$/ { inb=0 }
  END{
    nn=0; for(k in SEEN)nn++; if(nn==0||omax<=0){print "NODATA"; exit}
    full=omax; occT=0.5*full; plo=0.02*full; phi=0.98*full;
    vbm=-1e30; cbm=1e30; vkk=""; ckk=""; vss=""; css=""; vbi=""; cbi="";
    for(k in SEEN){ e=E[k]; o=O[k]; kp=KPk[k];
      if(o>occT){ if(e>vbm){vbm=e;vkk=kp;vss=SP[k];vbi=BI[k]}
                  if(!(kp in vk) || e>vk[kp]) vk[kp]=e }
      else      { if(e<cbm){cbm=e;ckk=kp;css=SP[k];cbi=BI[k]}
                  if(!(kp in ck) || e<ck[kp]) ck[kp]=e } }
    printf "  full occupancy (norm): %.4f\n", full;
    printf "  [xcheck] highest occ  : % .4f eV   band %s spin %s  k-pt %s  (% .5f % .5f % .5f)\n", vbm,vbi,vss,vkk,KX[vkk],KY[vkk],KZ[vkk];
    printf "  [xcheck] lowest unocc : % .4f eV   band %s spin %s  k-pt %s  (% .5f % .5f % .5f)\n", cbm,cbi,css,ckk,KX[ckk],KY[ckk],KZ[ckk];
    gap=cbm-vbm;
    if(gap>0.02){
      kind=(vkk==ckk?"DIRECT":"INDIRECT");
      printf "  [xcheck] gap (occ)    : %.4f eV  (%s)\n", gap, kind;
      if(vss!=css) printf "  (VBM and CBM are in different spin channels)\n";
      # smallest vertical (direct) gap over k-points where both defined
      dg=1e30; dgk="";
      for(kp in vk){ if(kp in ck){ d=ck[kp]-vk[kp]; if(d>0 && d<dg){dg=d; dgk=kp} } }
      if(dg<1e29) printf "  direct (vertical) gap: %.4f eV  at k-pt %s  (% .5f % .5f % .5f)\n", dg, dgk, KX[dgk],KY[dgk],KZ[dgk];
      printf "  VBM/CBM rel. E_fermi : % .3f / % .3f eV\n", vbm-ef, cbm-ef;
      np=0; for(k in SEEN){o=O[k]; if(o>plo&&o<phi)np++}
      if(np==0) print "__INSULATOR__"; else printf "  %d partially-occupied state(s) near E_F\n", np;
    } else { printf "  [xcheck] gap (occ)    : %.4f eV\n", (gap>0?gap:0); print "__METAL__"; }
  }' "$OUT")
note "This is the Kohn-Sham (DFT/DFT+U) gap. For the optical/QP gap use the GW section."

#=================== 8b. OCCUPIED BANDS & NBANDS FOR GW =====================
# Robust count of occupied bands -> the anchor for NBANDS in the GW first step
# (exact diagonalization, ALGO=Exact). Ref: vasp.at/wiki/Practical_guide_to_GW_calculations
hdr "Occupied bands & NBANDS (first GW step: exact diagonalization)"
NELECT=$(awk '/NELECT/{for(i=1;i<=NF;i++) if($i=="NELECT"){print $(i+2); exit}}' "$OUT")
NONCOL=$(getlog LNONCOLLINEAR)
# per-spin full occupancy: 1.0 for ISPIN=2 or non-collinear/SOC; 2.0 for spin-paired ISPIN=1
if [[ ${ISPIN%.*} == 2 || $NONCOL == T || $LSORBIT == T ]]; then FMAX=1.0; SPINPAIR=0; else FMAX=2.0; SPINPAIR=1; fi

# Count from the FINAL eigenvalue dump only (everything after the last "E-fermi :" line),
# so multi-step relaxations report the converged occupation, not an early step.
EFLINE=$(grep -n 'E-fermi' "$OUT" | tail -1 | cut -d: -f1)
OCC_INFO=$(tail -n +"${EFLINE:-1}" "$OUT" 2>/dev/null | awk -v fmax="$FMAX" '
  /spin component/ { sp=$NF+0; next }
  /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ { kp=$2+0; if(sp=="")sp=1; occ[sp,kp]=0; next }
  /band No\./ && $0 !~ /KS-energies/ { inb=1; if(sp=="")sp=1; next }
  inb && $1 ~ /^[0-9]+$/ && NF>=3 {
    b=$1+0; o=$3+0; if(o>mo)mo=o;
    if(o > 0.5*fmax){ occ[sp,kp]++; if(b>hi[sp])hi[sp]=b }
    if(o > 0.05*fmax && o < 0.95*fmax){ part++; if(b>hipart)hipart=b }
    next }
  inb && /^[[:space:]]*$/ { inb=0 }
  END{
    for(key in occ){ split(key,a,SUBSEP); s=a[1]; if(occ[key]>nmax[s])nmax[s]=occ[key] }
    n1=(1 in nmax)?nmax[1]:0; n2=(2 in nmax)?nmax[2]:0; nocc=(n1>n2?n1:n2);
    printf "%d %d %d %.4f %d %d\n", nocc, n1, n2, mo+0, part+0, hipart+0
  }')
read NOCC NOCC1 NOCC2 MAXOCC NPART HIPART <<<"${OCC_INFO:-0 0 0 0 0 0}"
N_OCC=${NOCC:-0}

# expected occupied bands from the electron count (independent cross-check)
NEXP=$(awk -v ne="${NELECT:-0}" -v isp="${ISPIN%.*}" -v nc="$NONCOL" -v so="$LSORBIT" -v mag="${NETMAG:-0}" 'BEGIN{
  m=(mag<0?-mag:mag);
  if(nc=="T"||so=="T") e=ne;        # 1 electron per spinor band
  else if(isp==2)      e=(ne+m)/2;  # the larger spin channel sets NBANDS
  else                 e=ne/2;      # 2 electrons per band
  printf "%.0f", e }')

if [[ ${N_OCC:-0} -gt 0 ]]; then
  kv "electrons (NELECT)" "${NELECT:-?}"
  if   [[ $NONCOL == T || $LSORBIT == T ]]; then kv "spin treatment" "non-collinear / SOC (spinor bands, 1 e-/band)"
  elif ((SPINPAIR));                        then kv "spin treatment" "spin-paired (ISPIN=1, 2 e-/band)"
  else kv "spin treatment" "collinear spin-polarised (ISPIN=2, 1 e-/band/spin)"; fi
  if [[ ${ISPIN%.*} == 2 && ${NOCC1:-0} -ne ${NOCC2:-0} ]]; then
    kv "occupied bands N_occ" "${N_OCC}   (spin-up ${NOCC1} / spin-down ${NOCC2}; NBANDS is per spin -> use the larger)"
  elif [[ ${ISPIN%.*} == 2 ]]; then
    kv "occupied bands N_occ" "${N_OCC}   (per spin; both channels equal -> non-magnetic)"
  else
    kv "occupied bands N_occ" "${N_OCC}"
  fi
  if [[ ${N_OCC} == ${NEXP} ]]; then
    ok "Cross-check vs NELECT: ${NEXP} occupied bands -> agrees (count is exact)."
  else
    warn "Occupation count (${N_OCC}) != NELECT-derived (${NEXP}): partial occupancies or a spin-imbalanced/odd-electron case -> verify before trusting N_occ."
  fi
  kv "highest occ / first empty (LUMO)" "band ${N_OCC} / band $((N_OCC+1))"
  if [[ ${NPART:-0} -eq 0 ]]; then
    ok "No partial occupancies (max f=${MAXOCC} of ${FMAX}) -> N_occ is an exact integer."
  else
    warn "${NPART} partially-occupied band(s) (highest at band ${HIPART}) -> metallic/smeared; N_occ is fuzzy."
    tip "GW needs integer occupancies: keep ISMEAR=0 with a small SIGMA (the wiki: 'small sigma is required to avoid partial occupancies')."
  fi

  # plane-wave ceiling = the most orbitals VASP can diagonalize at this ENCUT
  PWMAX=$(grep -iE 'maximum number of plane-waves' "$OUT" | head -1 | awk '{print $NF+0}')
  PWMIN=$(grep -E '^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:.*plane waves' "$OUT" | awk '{n=$NF+0; if(min==""||n<min)min=n} END{print min+0}')
  CEIL=${PWMIN:-$PWMAX}
  nb=${NBANDS%.*}
  echo "  ---- sizing NBANDS for the ALGO=Exact step ----"
  [[ ${CEIL:-0} -gt 0 ]] && kv "plane-wave ceiling" "~${CEIL} bands (max VASP can diagonalize at ENCUT=${ENCUT:-?} eV; the basis limit)"
  if [[ ${nb:-0} -gt 0 ]]; then
    kv "this OUTCAR: NBANDS" "${nb}  ->  $((nb - N_OCC)) empty band(s) above N_occ"
  fi
  tip "First GW step (per the VASP GW guide): ALGO=Exact, NELM=1, LOPTICS=.TRUE., ISMEAR=0/SIGMA=0.05, restart from the"
  tip "converged ground-state WAVECAR. Set NBANDS well above N_occ=${N_OCC} and CONVERGE the QP gap vs NBANDS *and* ENCUTGW"
  tip "together; the guide recommends taking as many empty states as the basis allows (toward ~${CEIL:-the PW limit})."
  if [[ ${nb:-0} -gt 0 ]]; then
    tip "For pure-MPI: make NBANDS a multiple of the MPI ranks-per-k-point (= total ranks / KPAR) so VASP does not silently raise it."
  fi
else
  note "No final eigenvalue/occupation block found -> cannot determine occupied bands (NWRITE too low, or OUTCAR truncated before the eigenvalues)."
fi

#======================= 9. G0W0 / GW QUASIPARTICLE ========================
if ((gw_family)); then
  hdr "GW / quasiparticle analysis"
  while IFS= read -r l; do case "$l" in
      NOQP)       warn "No 'KS-energies/QP-energies' table found -> not a finished GW run, or output not written (likely killed before the QP step).";;
      *__EDGEMOVE__*) note "A band edge MOVED to a different k-point: the GW correction is k-dependent, not a rigid scissor. Physical, but more sensitive to ENCUTGW/NBANDS -- converge before quoting the gap.";;
      *__GAPCLOSE__*) note "QP gap is SMALLER than the KS gap -- GW usually OPENS it. The common cause is a DFT start that already over-opened the gap, typically a large Hubbard U on the conduction-band orbital in the step that wrote the WAVECAR (this OUTCAR cannot see that: check the INCAR of the preceding run). The result is then starting-point dependent -> cross-check with G0W0 on the plain (U=0) start.";;
      *__LOWZ__*) warn "Mean Z < 0.6: strong self-energy / near-breakdown of perturbation theory -> check NBANDS, NOMEGA, ENCUTGW convergence.";;
      *) printf '%s\n' "$l";; esac
  done < <(awk '
    function abs(x){return x<0?-x:x}
    /QP shifts/ && /iteration/ {        # start of a new GW/QP iteration -> reset
      delete SEEN; delete KS; delete QP; delete ZZ; delete OC; delete KPk; delete BI;
      niter++; next }
    /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ {
      for(i=1;i<=NF;i++) if($i==":"){ci=i;break}
      kp=$(ci-1)+0; KX[kp]=$(ci+1); KY[kp]=$(ci+2); KZ[kp]=$(ci+3); inb=0; next }
    /KS-energies/ && /QP-energies/ {    # per-k-point column header: detect columns only
      col=0; zc=0; ocl=0;
      for(i=1;i<=NF;i++){ tok=$i; if(tok=="No."||tok=="no.")continue; col++; U=toupper(tok);
                          if(U=="Z")zc=col; if(U ~ /OCCUPATION/)ocl=col }
      inb=1; got=0; next }
    inb && $1 ~ /^[0-9]+$/ {
      b=$1+0; ks=$2+0; qp=$3+0;
      z=(zc>0 && zc<=NF)?$zc+0:0; o=(ocl>0 && ocl<=NF)?$ocl+0:$NF+0;
      key=kp SUBSEP b; SEEN[key]=1; KS[key]=ks; QP[key]=qp; ZZ[key]=z; OC[key]=o; KPk[key]=kp; BI[key]=b;
      got=1; next }
    # VASP prints a BLANK LINE between the column header and the first data row,
    # so a blank line may only close the block once data has actually been read --
    # otherwise every QP table is discarded and a finished GW run looks unfinished.
    inb && /^[[:space:]]*$/ { if(got) inb=0; next }
    END{
      nc=0; for(k in SEEN)nc++;
      if(nc==0){print "NOQP"; exit}
      if(niter==0) niter=1;            # single-shot G0W0 may not print a "QP shifts" banner
      # The QP table carries BOTH columns -- KS-energies (the DFT/DFT+U starting
      # eigenvalues) and QP-energies -- so the per-edge GW corrections come from
      # this OUTCAR alone; the preceding DFT folder is never needed.
      ksv=-1e30;ksc=1e30;qpv=-1e30;qpc=1e30; zs=0;zn=0;
      vkk="";ckk="";vbi="";cbi=""; kvk="";kck="";kvb="";kcb="";
      for(k in SEEN){
        if(OC[k]>0.5){ if(KS[k]>ksv){ksv=KS[k];kvk=KPk[k];kvb=BI[k]}
                       if(QP[k]>qpv){qpv=QP[k];vkk=KPk[k];vbi=BI[k]} }
        else         { if(KS[k]<ksc){ksc=KS[k];kck=KPk[k];kcb=BI[k]}
                       if(QP[k]<qpc){qpc=QP[k];ckk=KPk[k];cbi=BI[k]} }
        if(ZZ[k]>0.01 && ZZ[k]<1.5){ zs+=ZZ[k]; zn++ } }
      ksgap=ksc-ksv; qpgap=qpc-qpv;
      kskind=(kvk==kck?"DIRECT":"INDIRECT");
      kind=(vkk==ckk?"DIRECT":"INDIRECT");
      printf "  GW iterations (tables): %d\n", niter;
      printf "  KS gap (DFT input)   : %.4f eV  (%s)\n", ksgap, kskind;
      printf "  QP gap (GW)          : %.4f eV  (%s)\n", qpgap, kind;
      printf "  gap renormalisation  : %+.4f eV  (QP - KS)\n", qpgap-ksgap;
      printf "  band-edge shifts (QP - KS, same table -- no DFT folder needed):\n";
      printf "    VBM : % .4f -> % .4f eV   %+.4f eV   band %s  k-pt %s -> %s\n",
             ksv, qpv, qpv-ksv, vbi, kvk, vkk;
      printf "    CBM : % .4f -> % .4f eV   %+.4f eV   band %s  k-pt %s -> %s\n",
             ksc, qpc, qpc-ksc, cbi, kck, ckk;
      printf "  QP VBM at k-pt %s  (% .5f % .5f % .5f)\n", vkk,KX[vkk],KY[vkk],KZ[vkk];
      printf "  QP CBM at k-pt %s  (% .5f % .5f % .5f)\n", ckk,KX[ckk],KY[ckk],KZ[ckk];
      # A rigid ("scissor") correction leaves the extrema where they were. If an
      # edge migrates to another k-point the correction is k-dependent, which is
      # physical but far more sensitive to ENCUTGW/NBANDS convergence.
      if(kvk!=vkk || kck!=ckk) print "__EDGEMOVE__";
      if(qpgap<ksgap) print "__GAPCLOSE__";
      if(zn>0){ printf "  mean Z (renorm.)     : %.3f  over %d states\n", zs/zn, zn;
                if(zs/zn<0.6) print "__LOWZ__" }
    }' "$OUT")
  note "GW gaps converge SLOWLY in NBANDS and NOMEGA, and ~ENCUTGW^3 in basis. Verify against a convergence series."
fi

#==================== 9b. META-GGA CONSISTENCY (tau-dependent) ==============
# A tau-dependent meta-GGA (SCAN/R2SCAN/TPSS/MBJ) is NOT a functional of the
# density alone: the XC potential also needs the kinetic-energy density
# tau(r) = SUM_nk f_nk |grad psi_nk|^2, built from the OCCUPIED ORBITALS over the
# whole BZ. The CHGCAR holds n(r) and nothing else, so the ordinary band/DOS
# recipe (freeze the charge, ICHARG=11 along a k-path) cannot rebuild the
# Hamiltonian. VASP does not abort -- it returns eigenvalues from the wrong
# potential, and they look completely normal. Everything below exists because
# nothing else in the output complains.
if [[ -n ${_mgga:-} ]]; then
  hdr "meta-GGA consistency (${_mgga})"

  # --- POTCAR must carry core kinetic-energy-density information -------------
  if [[ -s POTCAR ]]; then
    _ked=$(grep -c "kinetic energy-density" POTCAR 2>/dev/null || true)
    _ked=${_ked//[^0-9]/}; _ked=${_ked:-0}
    _nspec=$(awk '/VRHFIN/{n++} END{print n+0}' POTCAR 2>/dev/null); _nspec=${_nspec:-0}
    if (( _ked > 0 )); then
      ok "POTCAR supports meta-GGA: ${_ked} 'kinetic energy-density' block(s) for ${_nspec} species."
      if (( _nspec > 0 && _ked < _nspec )); then
        warn "Only ${_ked} of ${_nspec} species carry it -- the rest fall back to a core tau that is not consistent with ${_mgga}."
      fi
    else
      fail "POTCAR has NO 'kinetic energy-density' block: these POTCARs cannot do a tau-dependent meta-GGA correctly."
      tip "Check for _GW-family POTCARs (O_GW is the classic offender). The R2SCAN branch needs standard POTCARs; they are NOT interchangeable with the GW branch."
    fi
  else
    note "No POTCAR here -- cannot verify meta-GGA (kinetic energy-density) support."
  fi

  # --- the silent trap -------------------------------------------------------
  _ich=${ICHARG%.*}
  if [[ $_ich =~ ^-?[0-9]+$ ]] && (( _ich >= 10 )); then
    fail "ICHARG=${_ich} with METAGGA=${_mgga}: the charge density was frozen, but tau is NOT in the CHGCAR."
    warn "  These eigenvalues come from the wrong potential. VASP did not complain."
    tip "Redo self-consistently: ICHARG=0, ISTART=1 (copy the Scf WAVECAR), regular mesh in KPOINTS, high-symmetry path in KPOINTS_OPT."
  elif [[ $_ich =~ ^-?[0-9]+$ ]]; then
    ok "ICHARG=${_ich} -- self-consistent, as a tau-dependent functional requires."
  fi

  # --- LASPH is mandatory, LMAXTAU governs the one-centre expansion of tau ----
  if [[ $(getlog LASPH) == T ]]; then
    ok "LASPH=.TRUE. -- required: without it the one-centre terms use only a spherically averaged n and tau."
  else
    fail "LASPH is not .TRUE.: mandatory for meta-GGA. One-centre contributions would be computed from spherically averaged density and tau."
  fi
  _lmt=$(getp LMAXTAU); _lmt=${_lmt%.*}
  if [[ $_lmt =~ ^[0-9]+$ ]] && (( _lmt < 6 )); then
    warn "LMAXTAU=${_lmt} < 6: too low for d elements. The default with LASPH=.TRUE. is 6 -- do not lower it."
  fi

  # --- GAMMA TEST: audit a derived run against its own Scf -------------------
  # Gamma sits in the Scf's regular mesh AND at the start of essentially every
  # high-symmetry path. If both runs solved the same Hamiltonian its eigenvalues
  # must agree. This is the decisive check on bands/DOS produced with the wrong
  # recipe -- and it needs no reference data, only the sibling Scf.
  _scf=""
  for _c in ../Scf ../SCF ../scf ../1_Scf ../0_Scf; do
    [[ -f $_c/OUTCAR ]] && { _scf=$_c; break; }
  done
  if [[ -n $_scf ]]; then
    # First eigenvalue block of the last iteration = k-point 1. VASP orders the
    # mesh with Gamma first for a Gamma-centred grid, and a path almost always
    # starts there; the coordinates are printed so the comparison is checkable.
    _gam(){ awk '/ k-point *1 *:/{k=NR; delete v; n=0; coord=$0}
                 k && NR>k+1 && NF>=2 && $1+0>0 { v[++n]=$2 }
                 k && NR>k+1 && NF<2 && n>0 { print coord; for(i=1;i<=n&&i<=6;i++) printf "%s ", v[i]; print ""; k=0; n=0 }
                 END{ if(n>0){ print coord; for(i=1;i<=n&&i<=6;i++) printf "%s ", v[i]; print "" } }' "$1" | tail -2; }
    _a=$(_gam "$_scf/OUTCAR"); _b=$(_gam "$OUT")
    _ea=$(printf '%s\n' "$_a" | tail -1); _eb=$(printf '%s\n' "$_b" | tail -1)
    if [[ -n $_ea && -n $_eb ]]; then
      _dmax=$(awk -v a="$_ea" -v b="$_eb" 'BEGIN{
          na=split(a,A," "); nb=split(b,B," "); n=(na<nb?na:nb); m=0
          for(i=1;i<=n;i++){ d=A[i]-B[i]; if(d<0)d=-d; if(d>m)m=d }
          printf "%.4f", m }')
      kv "Scf reference"        "$_scf/OUTCAR"
      kv "1st k-pt eigenvalues" "this run : ${_eb% }"
      kv "                    " "Scf      : ${_ea% }"
      kv "max |difference| (eV)" "$_dmax"
      if awk -v d="$_dmax" 'BEGIN{exit !(d<=0.01)}'; then
        ok "Eigenvalues agree to ${_dmax} eV -> both runs solved the SAME Hamiltonian. The data is consistent."
      elif awk -v d="$_dmax" 'BEGIN{exit !(d<=0.05)}'; then
        note "Eigenvalues differ by ${_dmax} eV -- small; a denser mesh shifts things slightly. Probably fine, but confirm the k-point coordinates above match."
      else
        fail "Eigenvalues differ by ${_dmax} eV at the same k-point -> these runs did NOT solve the same Hamiltonian."
        warn "  Classic cause: this run used the GGA recipe (ICHARG=11) with a meta-GGA. Redo it."
      fi
      note "Compare the printed k-point coordinates: the test is only meaningful if both are the same point."
    fi
  fi
fi

#======================= 10. PITFALLS & RECOMMENDATIONS =====================
hdr "Pitfalls & recommendations"
ISM=${ISMEAR%.*}

# --- smearing choice vs calculation type ---
if [[ $ISM =~ ^-?[0-9]+$ ]]; then
  if [[ $CALC_BASE == *relax* && $ISM == -5 ]]; then
    warn "ISMEAR=-5 (tetrahedron) gives poor FORCES/stress -> use ISMEAR=0 (or 1/2) during relaxation."
  fi
  if [[ ( $CALC_BASE == "static SCF" || $CALC_BASE == non-self* ) && $ISM -ge 1 ]]; then
    tip "ISMEAR>=1 (Methfessel-Paxton) is for metals; for an insulator/DOS use ISMEAR=-5 (tetrahedron) or 0."
  fi
  if [[ $ISM == -5 && -n ${NKPTS:-} && ${NKPTS%.*} -lt 4 ]]; then
    warn "ISMEAR=-5 with very few k-points (${NKPTS}) -> tetrahedron method is unreliable / VASP may refuse."
  fi
  if [[ $ISM -ge 0 ]] && awk -v s="${SIGMA:-0}" 'BEGIN{exit !(s>0 && s<0.005)}'; then
    warn "ISMEAR>=0 with SIGMA<0.005 eV: occupations can flicker / SCF oscillate; ~0.02-0.05 eV is safer."
  fi
fi

# --- LDA+U geometry consistency (a GGA -> GGA+U workflow) ---
if [[ $LDAU == T && ( $CALC_BASE == "static SCF" || ((gw_family)) ) ]]; then
  warn "LDA+U active in a non-relaxing run: make sure the GEOMETRY was relaxed with the SAME LDAU settings."
  tip "A +U static on a plain-GGA geometry is inconsistent; re-relax under identical LDAUU/LDAUL/LDAUJ first."
  tip "Note: a large U applied to a nominally EMPTY d-shell (e.g. V5+ d0) acts mostly as a conduction-band shift,"
  tip "not as a self-interaction correction. Sanity-check whether U belongs on that shell at all."
fi

# --- GW-specific knobs (the GW rule set, not the DFT one) ------------------
if ((gw_family)); then
  if [[ -n ${NCORE:-} && ${NCORE%.*} -gt 1 ]]; then
    fail "NCORE=${NCORE} with GW: GW requires NCORE=1. Parallelise over k-points with KPAR instead."
    tip "\"Unfortunately you need to use the default for GW and RPA calculations.\" -- https://vasp.at/wiki/Optimizing_the_parallelization"
  fi
  if [[ -n ${NOMEGA:-} && ${NOMEGA%.*} -gt 0 ]]; then
    for _t in NTAUPAR NOMEGAPAR; do
      _v="$(getp "$_t")"; _v="${_v%.*}"
      if [[ -n $_v && $_v -gt 0 ]] && (( ${NOMEGA%.*} % _v != 0 )); then
        fail "${_t}=${_v} is not a divisor of NOMEGA=${NOMEGA}."
        tip "\"For this purpose both tags have to be divisors of NOMEGA.\" -- https://vasp.at/wiki/Practical_guide_to_GW_calculations"
      fi
    done
  fi
  if [[ -z $ENCUTGW_SET ]]; then
    warn "ENCUTGW not set in INCAR -> defaulted to 2/3*ENCUT = ~$(awk -v e="${ENCUT:-0}" 'BEGIN{printf "%.0f", e*2.0/3.0}') eV."
    tip "ENCUTGW is the dominant memory knob (~cube). Set it explicitly and converge it; this also fixes the"
    tip "GW memory estimate you have been calibrating (the commented-out ENCUTGW was the missing anchor value)."
  fi
  if [[ -n ${NBANDS:-} && -n ${NBANDSGW:-} ]] && awk -v a="${NBANDS%.*}" -v b="${NBANDSGW%.*}" 'BEGIN{exit !(b>0 && b>0.8*a)}'; then
    warn "NBANDSGW (${NBANDSGW}) is close to NBANDS (${NBANDS}); GW needs MANY empty bands -> increase NBANDS."
  fi
  tip "The DFT step feeding GW must be well converged with plenty of empty states (LOPTICS=.TRUE., large NBANDS)."
fi

# --- KPAR divisibility -----------------------------------------------------
# Two regimes, two verdicts. "KPAR should factorize the number of k points" is
# on the electronic-minimization page; the GW guide does not repeat it, and in
# GW the k-group holds chi and W, so memory binds. Telling a GW user to "pick a
# divisor of NKPTS" can send them to a layout that OOMs.
if [[ -n ${KPAR:-} && ${KPAR%.*} -gt 1 && -n ${NKPTS:-} && ${NKPTS%.*} -gt 0 ]]; then
  if (( ${NKPTS%.*} % ${KPAR%.*} != 0 )); then
    _idle=$(awk -v n="${NKPTS%.*}" -v k="${KPAR%.*}" \
              'BEGIN{g=int((n+k-1)/k); printf "%.1f", 100*(1-n/(g*k))}')
    if ((gw_family)); then
      note "KPAR=${KPAR} does not divide NKPTS=${NKPTS} -> ~${_idle}% of core-time idles."
      tip "In GW that is a cost, not an error: the k-group holds chi and W, so a group that FITS beats"
      tip "one that balances. Change KPAR only if memory already has room; else add zero-weighted k-points."
    else
      warn "KPAR=${KPAR} does not divide NKPTS=${NKPTS} -> uneven k-group load (~${_idle}% idle ranks). Pick a divisor of NKPTS."
    fi
  fi
fi

# --- NBANDS headroom for the gap (reuses the robust N_occ from the occupied-bands section) ---
if [[ -n ${NBANDS:-} && ${N_OCC:-0} -gt 0 ]]; then
  nb=${NBANDS%.*}; head=$(( nb - N_OCC ))
  if ((gw_family)); then
    if (( head < nb/4 )); then
      warn "GW with only ${head} empty bands above N_occ=${N_OCC} -> the screened interaction / QP energies are under-converged."
      tip "GW typically needs hundreds of empty bands; raise NBANDS substantially (and converge it) in the exact-diagonalization step."
    fi
  else
    if (( head < 2 )); then
      warn "Highest occupied band is at/next to NBANDS=${nb} (only ${head} empty): CBM/DOS tail unreliable; raise NBANDS."
    elif (( head < 4 )); then
      note "Only ${head} empty bands above N_occ=${N_OCC} -> fine for the gap, thin for an unoccupied-DOS tail or as a GW starting point."
    fi
  fi
fi

# --- band-plot smoothness (jagged-band diagnosis) ---
if [[ $CALC_BASE == non-self* ]]; then
  tip "Jagged/'ripped' bands have THREE causes: (a) plotter connectivity at crossings, (b) too few k-points per"
  tip "segment in the line-mode KPOINTS, (c) NBANDS-ceiling noise. Diagnose separately; (b) is the usual fix here."
fi

[[ $WARNS == 0 && $FAILS == 0 ]] && ok "No pitfalls flagged for this configuration."

#============================ FINAL VERDICT =================================
hdr "Verdict"
ETOT=$(grep 'free  energy   TOTEN' "$OUT" | tail -n1 | awk '{print $(NF-1)}')
ESIG0=$(grep 'energy(sigma->0)' "$OUT" | tail -n1 | awk '{print $NF}')
[[ -n ${ETOT:-} ]]  && kv "Final TOTEN (eV)"      "$ETOT"
[[ -n ${ESIG0:-} ]] && kv "energy(sigma->0) (eV)" "$ESIG0"
if [[ -n ${ETOT:-} && ${NIONS%.*} -gt 0 ]]; then
  kv "Energy / atom (eV)" "$(awk -v e="$ETOT" -v n="${NIONS%.*}" 'BEGIN{printf "%.6f", e/n}')"
fi
kv "Calculation"  "$CALC_BASE  [$CALC_XC]"
if grep -q 'General timing and accounting' "$OUT"; then kv "Completion" "normal (timing footer present)"
elif ((RELAX_DONE));                             then kv "Completion" "converged; footer absent (OUTCAR truncated post-run)"
elif ((IS_RELAX)); then kv "Completion" "ionic loop UNFINISHED (still running, or stopped before EDIFFG)"
elif ((SCF_CONVERGED));                          then kv "Completion" "SCF converged; footer absent (OUTCAR truncated post-run)"
else kv "Completion" "incomplete -> run 'vasp-diagnose' for the cause + data salvage"; fi

echo
if [[ $FAILS -gt 0 ]]; then
  printf '%s%s OVERALL: FAIL  (%d failed, %d warnings)%s\n' "$B" "$RED" "$FAILS" "$WARNS" "$R"; exit 1
elif [[ $WARNS -gt 0 ]]; then
  printf '%s%s OVERALL: PASS with %d warning(s)%s\n' "$B" "$YEL" "$WARNS" "$R"; exit 0
else
  printf '%s%s OVERALL: PASS - clean, converged, physically consistent%s\n' "$B" "$GRN" "$R"; exit 0
fi
