#!/usr/bin/env bash
#==============================================================================
# vasp_check.sh  --  what a VASP run produced, as data.
#
#   Reads a run, finished or killed, and tabulates what it holds: the
#   parameters it ran with, how far it got, electronic and ionic convergence,
#   forces, cell and stress, what a relaxation changed (POSCAR vs CONTCAR),
#   magnetization, band edges and gap, occupations, GW quasiparticle energies
#   and the meta-GGA prerequisites.
#
#   It states numbers and draws no physical conclusions: no "metallic", no
#   "antiferromagnetic", no advice. Those are the reader's call. The only
#   verdicts are CHECKS against the run's own criteria (NELM, EDIFFG) and
#   against explicit VASP requirements (NCORE=1 for GW, LASPH with a meta-GGA,
#   ...). They are listed together at the end, one line each, [ OK ] / [WARN] /
#   [FAIL].
#
#   Why a job died, and whether its data survived: vasp-diagnose.
#
# Usage:   vasp_check.sh [DIR]            (default DIR = .)
#          vasp_check.sh -h | --help
# Exit:    0 = no failed check, 1 = at least one [FAIL], 2 = usage error
#==============================================================================
set -uo pipefail

#------------------------------- presentation --------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""
fi

FAILS=0; WARNS=0; CHK=()
hdr(){  printf '\n%s== %s ==%s\n' "$B$CYN" "$1" "$R"; }
kv(){   printf '  %-28s %s\n' "$1" "$2"; }
note(){ printf '  %s%s%s\n' "$DIM" "$1" "$R"; }
# Checks are collected and printed together at the end: the sections above
# them hold data only.
chk_ok(){   CHK+=("  ${GRN}[ OK ]${R} $1"); }
chk_warn(){ CHK+=("  ${YEL}[WARN]${R} $1"); WARNS=$((WARNS+1)); }
chk_fail(){ CHK+=("  ${RED}[FAIL]${R} $1"); FAILS=$((FAILS+1)); }
# grid TAG VALUE [TAG VALUE ...]: INCAR-style pairs, five to a line
grid(){
  local n=0 line=""
  while (( $# >= 2 )); do
    line+=$(printf '%-17s' "$1 ${2:-?}"); shift 2; n=$((n+1))
    (( n % 5 == 0 )) && { printf '  %s\n' "${line%"${line##*[! ]}"}"; line=""; }
  done
  [[ -n $line ]] && printf '  %s\n' "${line%"${line##*[! ]}"}"
  return 0
}
hsize(){ awk -v b="$1" 'BEGIN{ if (b < 1024) printf "%d B", b
  else if (b < 1048576) printf "%.0f kB", b/1024
  else if (b < 1073741824) printf "%.1f MB", b/1048576
  else printf "%.1f GB", b/1073741824 }'; }

usage(){
  cat <<'EOF'
vasp_check.sh [DIR]   What a VASP run produced, as data. DIR defaults to here.
  -h, --help          Show this help.

SECTIONS (each only when the run has the data)
  Run                 calculation type, VASP version, completion, files
  Parameters          the INCAR tags that matter, as VASP applied them
  Electronic          ionic steps, SCF iterations, steps that reached NELM
  Ionic               forces per step, final max/RMS |F|, energy per step
  Forces and stress   at the geometry of a static run
  Cell and stress     volume, lattice lengths, external pressure
  What the relaxation changed   POSCAR vs CONTCAR, side by side
  Magnetization       net and per-ion moments
  Band edges and gap  E-fermi, gap, VBM/CBM with band, spin and k-point
  Occupations         NELECT, occupied bands, NBANDS, plane waves
  GW                  KS vs QP gap, band-edge shifts, mean Z
  meta-GGA            POTCAR kinetic-energy density, ICHARG, LASPH
  Checks              the run against its own NELM/EDIFFG and VASP's rules
  Energy              TOTEN, energy(sigma->0), per atom; the result

No physical interpretation and no advice: numbers, and checks.
Why a run died and whether its data is usable: vasp-diagnose.

EXIT CODES
  0  no failed check          1  at least one [FAIL]          2  usage error
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

printf '%svasp-check  %s%s\n' "$B" "$(pwd)" "$R"

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

#================================ COMPLETION =================================
RELAX_DONE=0; SCF_CONVERGED=0; FOOTER=0
grep -qiE 'reached required accuracy - stopping structural energy minimi[sz]ation' "$OUT" && RELAX_DONE=1
grep -q 'aborting loop because EDIFF is reached' "$OUT" && SCF_CONVERGED=1
grep -q 'General timing and accounting' "$OUT" && FOOTER=1
# A multi-step relaxation prints 'aborting loop because EDIFF is reached' at
# EVERY ionic step, so for one of those only the ionic marker or the timing
# footer says the run is done.
IS_RELAX=0
[[ ${NSW:-0} =~ ^[0-9]+$ ]] && (( NSW > 1 )) && [[ ${IBRION:--1} != "-1" ]] && IS_RELAX=1
if   ((FOOTER));     then COMPLETION="normal (timing footer present)"
elif ((RELAX_DONE)); then COMPLETION="reached required accuracy; no timing footer"
elif ((IS_RELAX));   then COMPLETION="ionic loop unfinished: no 'reached required accuracy', no timing footer"
elif ((SCF_CONVERGED)); then COMPLETION="SCF converged; no timing footer"
else COMPLETION="no completion marker"; fi
if ((FOOTER || RELAX_DONE || SCF_CONVERGED)) && ! { ((IS_RELAX)) && ! ((FOOTER || RELAX_DONE)); }; then
  chk_ok "run completed: $COMPLETION"
else
  chk_warn "run not completed: $COMPLETION"
fi

#==================================== RUN ====================================
hdr "Run"
_type="$CALC_BASE, $CALC_XC"
[[ -n $GW_FLAVOUR ]] && _type="$_type; $GW_FLAVOUR"
kv "type"        "$_type"
kv "VASP"        "${VASPVER:-?}"
kv "completion"  "$COMPLETION"
_have=(); _absent=()
for f in OUTCAR OSZICAR INCAR KPOINTS POSCAR CONTCAR vasprun.xml EIGENVAL DOSCAR PROCAR WAVECAR CHGCAR; do
  # An empty file is not a missing one: VASP writes a 0-byte CONTCAR for a
  # static run and 0-byte CHG/CHGCAR with LCHARG=.FALSE.
  if   [[ -s $f ]]; then _have+=("$f $(hsize "$(wc -c <"$f")")")
  elif [[ -e $f ]]; then _have+=("$f (empty)")
  else _absent+=("$f"); fi
done
_line=""; _first=1
for x in "${_have[@]}"; do
  if (( ${#_line} + ${#x} > 60 )) && [[ -n $_line ]]; then
    if ((_first)); then kv "files" "$_line"; _first=0; else kv "" "$_line"; fi
    _line=""
  fi
  _line+="${_line:+,  }$x"
done
[[ -n $_line ]] && { if ((_first)); then kv "files" "$_line"; else kv "" "$_line"; fi; }
((${#_absent[@]})) && kv "absent" "${_absent[*]}"

#================================ PARAMETERS =================================
hdr "Parameters"
grid NIONS "${NIONS:-?}" NBANDS "${NBANDS:-?}" NKPTS "${NKPTS:-?}" ISPIN "${ISPIN:-?}" LSORBIT "$LSORBIT" \
     ENCUT "${ENCUT:-?}" ISMEAR "${ISMEAR:-?}" SIGMA "${SIGMA:-?}" EDIFF "${EDIFF:-?}" EDIFFG "${EDIFFG:-?}" \
     IBRION "${IBRION:-?}" NSW "${NSW:-?}" ISIF "${ISIF:-?}" ICHARG "${ICHARG:-?}" LORBIT "${LORBIT:-?}" \
     NELM "${NELM:-?}" KPAR "${KPAR:-?}" NCORE "${NCORE:-?}" NPAR "${NPAR:-?}"
if ((gw_family)); then
  nbgw="${NBANDSGW:-?}"; [[ ${NBANDSGW%.*} == -1 ]] && nbgw="all"
  _ecgw="${ENCUTGW:-?}"
  [[ -z $ENCUTGW_SET ]] && _ecgw="${_ecgw}(default)"
  grid NOMEGA "${NOMEGA:-?}" ENCUTGW "$_ecgw" NBANDSGW "$nbgw" NTAUPAR "${NTAUPAR:-?}" NOMEGAPAR "${NOMEGAPAR:-?}"
fi

#================================ ELECTRONIC =================================
hdr "Electronic convergence"
NONSCF=0; [[ $CALC_BASE == non-self* || ${ICHARG%.*} == 11 ]] && NONSCF=1
# A NELM the user capped on purpose is not non-convergence: NELM=1 (the GW
# first step) and ALGO=Exact/Diag (a one-shot diagonalisation).
DELIBERATE_CAP=0
[[ ${NELM%.*} == 1 ]] && DELIBERATE_CAP=1
_algo="$(gettag ALGO "$OUT")"; [[ -z $_algo ]] && _algo="$(gettag ALGO "$INC")"
[[ ${_algo^^} == EXACT || ${_algo^^} == DIAG ]] && DELIBERATE_CAP=1
if [[ -s $OSZ ]]; then
  eval "$(awk -v nelm="${NELM%.*}" '
    /^[[:space:]]*[A-Za-z]+:[[:space:]]+[0-9]+[[:space:]]/ { ec++; next }
    /F=/ { ionic++; tot+=ec; maxec=(ec>maxec?ec:maxec)
           if (nelm>0 && ec>=nelm) { stuck++; if (stuck<=8) bad=bad (bad==""?"":", ") ionic " (" ec ")" }
           ec=0 }
    END{ printf "S_IONIC=%d\nS_MAXEC=%d\nS_TOT=%d\nS_STUCK=%d\nS_BAD=\"%s\"\n", ionic, maxec, tot, stuck, bad }' "$OSZ")"
  kv "ionic steps"           "$S_IONIC"
  kv "SCF iterations"        "$S_TOT in total, at most $S_MAXEC per ionic step"
  kv "steps that reached NELM" "$S_STUCK${S_BAD:+   (step (iterations): $S_BAD)}"
  if (( S_STUCK == 0 )); then
    chk_ok "SCF met EDIFF (${EDIFF:-?}) within NELM (${NELM%.*}) at every ionic step"
  elif ((NONSCF)); then
    chk_ok "SCF: fixed charge density (ICHARG=11), one diagonalisation pass by design"
  elif ((DELIBERATE_CAP)); then
    chk_ok "SCF: NELM=${NELM%.*}${_algo:+ with ALGO=$_algo} is a single-step setting"
  else
    chk_fail "SCF reached NELM=${NELM%.*} without meeting EDIFF at $S_STUCK ionic step(s)"
  fi
else
  kv "OSZICAR" "absent: no SCF trajectory"
  chk_warn "no OSZICAR: SCF convergence cannot be checked"
fi
((NONSCF)) && kv "charge density" "fixed (ICHARG=11)"
EENTRO=$(grep 'EENTRO' "$OUT" | tail -n1 | awk '{print $NF}')
if [[ -n ${EENTRO:-} && ${NIONS%.*} -gt 0 ]]; then
  kv "|T*S| per atom (eV)" "$(awk -v e="$EENTRO" -v n="${NIONS%.*}" 'BEGIN{v=(e<0?-e:e)/n; if(v==0)v=0; printf "%.3e", v}')"
fi

#=================================== IONIC ===================================
if [[ $CALC_BASE == *relax* ]]; then
  hdr "Ionic convergence"
  eval "$(awk '
    /TOTAL-FORCE/ { inb=1; started=0; cmax=0; ss=0; n=0; next }
    inb && /^[[:space:]]*-+[[:space:]]*$/ {
      if(!started){started=1; next}
      else { blk++; traj[blk]=cmax; fmax=cmax; frms=sqrt(ss/(n>0?n:1)); fn=n; inb=0; started=0; next } }
    inb && started { m=sqrt($4*$4+$5*$5+$6*$6); if(m>cmax)cmax=m; ss+=m*m; n++ }
    /total drift:/ { dx=$3; dy=$4; dz=$5 }
    END{ if(blk==0){ print "F_BLK=0"; exit }
         printf "F_BLK=%d\nF_MAX=%.4f\nF_RMS=%.4f\nF_N=%d\n", blk, fmax, frms, fn
         if(dx!="") printf "F_DRIFT=%.4f\n", sqrt(dx*dx+dy*dy+dz*dz)
         s=(blk>12?blk-11:1); t=""; for(i=s;i<=blk;i++) t=t sprintf(" %.3f", traj[i])
         printf "F_TRAJ=\"%s\"\n", substr(t,2) }' "$OUT")"
  THR=""
  if [[ -n ${EDIFFG:-} ]] && awk -v g="$EDIFFG" 'BEGIN{exit !(g<0)}'; then
    THR=$(awk -v g="$EDIFFG" 'BEGIN{printf "%.4f", -g}')
  fi
  kv "reached required accuracy" "$( ((RELAX_DONE)) && echo yes || echo no )"
  if (( ${F_BLK:-0} > 0 )); then
    kv "ionic steps (force blocks)" "$F_BLK"
    kv "max |F| (eV/A)"   "$F_MAX${THR:+   (|EDIFFG| $THR)}"
    kv "RMS |F| (eV/A)"   "$F_RMS   over $F_N atoms"
    [[ -n ${F_DRIFT:-} ]] && kv "total drift (eV/A)" "$F_DRIFT"
    kv "max |F| per step" "$F_TRAJ"
  else
    kv "forces" "no TOTAL-FORCE block in OUTCAR"
  fi
  [[ -z $THR ]] && kv "stopping criterion" "energy (EDIFFG = ${EDIFFG:-?} eV)"
  if [[ -s $OSZ ]]; then
    eval "$(awk '/F=/{e=$3; gsub(/[Dd]/,"E",e); v[++k]=e+0}
         END{ up=0; for(i=2;i<=k;i++) if(v[i]>v[i-1]+1e-6) up++
              printf "E_K=%d\nE_UP=%d\n", k, up
              if(k>=2) printf "E_DLAST=%.3e\n", v[k]-v[k-1] }' "$OSZ")"
    if (( E_K >= 2 )); then
      kv "energy change, last step" "${E_DLAST} eV"
      kv "steps where E rose"       "$E_UP of $((E_K-1))"
    fi
  fi
  if ((RELAX_DONE)); then
    chk_ok "relaxation reached EDIFFG (${EDIFFG:-?})${F_MAX:+: max |F| $F_MAX eV/A}"
  else
    chk_warn "relaxation has not reached EDIFFG (${EDIFFG:-?})${F_MAX:+: max |F| $F_MAX eV/A${THR:+ against $THR}}"
  fi
fi

#======================= FORCES AND STRESS (non-relax) =======================
# A static run prints the forces and the stress tensor at its geometry whether
# or not anything moved: the data on whether that geometry is stationary.
if [[ $CALC_BASE != *relax* ]] && grep -qa 'TOTAL-FORCE' "$OUT"; then
  hdr "Forces and stress at this geometry"
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
    kv "forces" "TOTAL-FORCE header present, no rows (OUTCAR truncated mid-block)"
  else
    THR=""
    if [[ -n ${EDIFFG:-} ]] && awk -v g="$EDIFFG" 'BEGIN{exit !(g<0)}'; then
      THR=$(awk -v g="$EDIFFG" 'BEGIN{printf "%.4f", -g}')
    fi
    _on=""; (( F_ION > 0 )) && _on="   on ion $F_ION of $F_N"
    kv "max |F| (eV/A)" "$F_MAX$_on${THR:+   (|EDIFFG| $THR)}"
    kv "RMS |F| (eV/A)" "$F_RMS"
    [[ -n ${DRIFT:-} ]] && kv "total drift (eV/A)" "$DRIFT"
    # A Cartesian component that is exactly zero on EVERY ion.
    LOCKED=""
    awk -v v="$MX" 'BEGIN{exit !(v<1e-9)}' && LOCKED="${LOCKED}x "
    awk -v v="$MY" 'BEGIN{exit !(v<1e-9)}' && LOCKED="${LOCKED}y "
    awk -v v="$MZ" 'BEGIN{exit !(v<1e-9)}' && LOCKED="${LOCKED}z "
    [[ -n $LOCKED ]] && kv "zero on every ion" "force component ${LOCKED% }"
    if [[ -n ${HAVE_S:-} ]]; then
      kv "stress, max |diagonal| (kB)" "$S_DIAG"
      kv "stress, max |shear| (kB)"    "$S_OFF"
    fi
  fi
fi

#============================== CELL AND STRESS ==============================
if [[ $CALC_BASE == *relax* || $CALC_BASE == "static SCF" ]] || ((gw_family)); then
  hdr "Cell and stress"
  VOL=$(grep 'volume of cell' "$OUT" | tail -n1 | awk '{print $NF}')
  kv "volume (A^3)" "${VOL:-?}"
  LV=$(grep -A1 'length of vectors' "$OUT" | tail -n1)
  [[ -n $LV ]] && kv "|a| |b| |c| (A)" "$(echo "$LV" | awk '{printf "%.4f  %.4f  %.4f", $1,$2,$3}')"
  PRESSL=$(grep 'external pressure' "$OUT" | tail -n1)
  if [[ -n $PRESSL ]]; then
    P=$(echo "$PRESSL" | awk '{for(i=1;i<=NF;i++) if($i=="pressure"){print $(i+2); break}}')
    PUL=$(echo "$PRESSL" | awk '{print $(NF-1)}')
    kv "external pressure (kB)" "${P:-?}   (Pulay ${PUL:-?})"
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

# A chained relaxation (vasp-relax-loop) never overwrites this folder's POSCAR:
# each chunk runs in wolfpack_chain/NNN/, and the latest CONTCAR is copied
# here. POSCAR -> CONTCAR is therefore the whole relaxation.
_nch=0
if ((IS_RELAX)) && grep -qs '^chain_kind="relax"' wolfpack_chain/chain.env; then
  _nch=$(ls -d wolfpack_chain/[0-9][0-9][0-9] 2>/dev/null | wc -l)
fi

if [[ -f "$_wp_struct" && -n "$_wp_py" && -s POSCAR ]]; then
  if ((IS_RELAX)) && [[ -s CONTCAR ]]; then
    hdr "What the relaxation changed (POSCAR -> CONTCAR)"
    (( _nch > 0 )) && note "chained relaxation: POSCAR is the input, CONTCAR the latest of ${_nch} completed chunk(s)"
    if ! "$_wp_py" "$_wp_struct" POSCAR CONTCAR --labels="POSCAR,CONTCAR" 2>&1; then
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

#=============================== MAGNETIZATION ===============================
if [[ ${ISPIN%.*} == 2 || $LSORBIT == T ]]; then
  hdr "Magnetization"
  NETMAG=$(awk '/mag=/{for(i=1;i<=NF;i++) if($i=="mag="){m=$(i+1)}} END{print m}' "$OSZ" 2>/dev/null)
  # VASP also prints "number of electron  N  magnetization  M" every step
  [[ -z ${NETMAG:-} ]] && NETMAG=$(awk '/number of electron/ && /magnetization/{m=$NF} END{print m}' "$OUT")
  [[ -n ${NETMAG:-} ]] && kv "net moment (uB)" "$NETMAG"
  PERAT=$(awk '
    /magnetization \(x\)/ { cap=1; n=0; delete v; next }
    cap && /# of ion/      { hd=1; next }
    cap && hd && /^[[:space:]]*-+/ { dash++; if(dash==2){cap=0;hd=0;dash=0}; next }
    cap && hd && /^[[:space:]]*[0-9]+[[:space:]]/ { n++; v[n]=$NF }
    END{ for(i=1;i<=n;i++) printf "%d:%.3f ", i, v[i] }' "$OUT")
  if [[ -n $PERAT ]]; then
    printf '  %s\n' "per ion (uB)"
    printf '%s\n' "$PERAT" | tr ' ' '\n' | awk -F: 'NF==2{v=$2+0; if(v>-0.0005 && v<0.0005)v=0; printf "    %3s %7.3f", $1, v; if(++c%6==0)printf "\n"} END{if(c%6)printf "\n"}'
    kv "sum, max |m|, |m| > 0.2" "$(awk -v s="$PERAT" 'BEGIN{
      n=split(s,a," "); sum=0; mx=0; nb=0
      for(i=1;i<=n;i++){ split(a[i],b,":"); m=b[2]+0; sum+=m; am=(m<0?-m:m); if(am>mx)mx=am; if(am>0.2)nb++ }
      printf "%+.3f uB,  %.3f uB,  %d of %d ions", sum, mx, nb, n }')"
  else
    kv "per ion" "not in OUTCAR (LORBIT=${LORBIT:-0})"
  fi
fi

#============================ BAND EDGES AND GAP =============================
hdr "Band edges and gap"
EF=$(grep 'E-fermi' "$OUT" | tail -n1 | awk '{for(i=1;i<=NF;i++) if($i=="E-fermi"){print $(i+2); break}}')
kv "E-fermi (eV)" "${EF:-?}"
# VASP's own gap block, when it prints one.
eval "$(awk '
  /val\. band max:/ { for(i=1;i<=NF;i++) if($i=="@"){ai=i}; for(i=1;i<=NF;i++) if($i=="="){ei=i}
                      vmax=$(ai-1)+0; vk=$(ei+1)" "$(ei+2)" "$(ei+3); next }
  /cond\. band min:/ { for(i=1;i<=NF;i++) if($i=="@"){ai=i}; for(i=1;i<=NF;i++) if($i=="="){ei=i}
                      cmin=$(ai-1)+0; ck=$(ei+1)" "$(ei+2)" "$(ei+3); next }
  /fundamental gap:/ { g=$NF+0; sv=vmax; sc=cmin; svk=vk; sck=ck; got=1; next }
  END{ if(!got) exit
       printf "V_GAP=%.4f\nV_KIND=%s\nV_VBM=%.4f\nV_VK=\"%s\"\nV_CBM=%.4f\nV_CK=\"%s\"\n", g, (svk==sck?"direct":"indirect"), sv, svk, sc, sck }' "$OUT")"
# The eigenvalues and occupations themselves: the band edges with their band,
# spin and k-point, and the partially occupied states.
eval "$(awk -v ef="${EF:-0}" '
  /spin component/ { sp=$NF+0; next }
  /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/ {
    for(i=1;i<=NF;i++) if($i==":"){ci=i; break}
    kp=$(ci-1)+0; KX[kp]=$(ci+1); KY[kp]=$(ci+2); KZ[kp]=$(ci+3); inb=0; next }
  /band No\./ && $0 !~ /KS-energies/ { inb=1; if(sp=="")sp=1; next }
  inb && $1 ~ /^[0-9]+$/ && NF>=3 {
    bi=$1+0; en=$2+0; oc=$3+0; key=sp SUBSEP kp SUBSEP bi
    E[key]=en; O[key]=oc; SP[key]=sp; KPk[key]=kp; BI[key]=bi; SEEN[key]=1
    if(oc>omax)omax=oc; next }
  inb && /^[[:space:]]*$/ { inb=0 }
  END{
    nn=0; for(k in SEEN)nn++; if(nn==0||omax<=0){ print "O_NODATA=1"; exit }
    full=omax; occT=0.5*full; plo=0.02*full; phi=0.98*full
    vbm=-1e30; cbm=1e30
    for(k in SEEN){ e=E[k]; o=O[k]; kp=KPk[k]
      if(o>occT){ if(e>vbm){vbm=e;vkk=kp;vss=SP[k];vbi=BI[k]}
                  if(!(kp in vk) || e>vk[kp]) vk[kp]=e }
      else      { if(e<cbm){cbm=e;ckk=kp;css=SP[k];cbi=BI[k]}
                  if(!(kp in ck) || e<ck[kp]) ck[kp]=e }
      if(o>plo && o<phi) np++ }
    gap=cbm-vbm; if(gap<0) gap=0
    printf "O_VBM=%.4f\nO_VB=%s\nO_VS=%s\nO_VK=%s\nO_VKC=\"%.4f %.4f %.4f\"\n", vbm, vbi, vss, vkk, KX[vkk], KY[vkk], KZ[vkk]
    printf "O_CBM=%.4f\nO_CB=%s\nO_CS=%s\nO_CK=%s\nO_CKC=\"%.4f %.4f %.4f\"\n", cbm, cbi, css, ckk, KX[ckk], KY[ckk], KZ[ckk]
    printf "O_GAP=%.4f\nO_KIND=%s\nO_NPART=%d\n", gap, (vkk==ckk?"direct":"indirect"), np+0
    printf "O_VREL=%.3f\nO_CREL=%.3f\n", vbm-ef, cbm-ef
    dg=1e30; for(kp in vk){ if(kp in ck){ d=ck[kp]-vk[kp]; if(d>0 && d<dg){dg=d; dgk=kp} } }
    if(dg<1e29) printf "O_DG=%.4f\nO_DGK=%s\nO_DGKC=\"%.4f %.4f %.4f\"\n", dg, dgk, KX[dgk], KY[dgk], KZ[dgk] }' "$OUT")"
if [[ -n ${V_GAP:-} ]]; then
  kv "gap (eV)" "$V_GAP   $V_KIND   (VASP)${O_GAP:+;  $O_GAP from the occupations}"
elif [[ -n ${O_GAP:-} ]]; then
  kv "gap (eV)" "$O_GAP   $O_KIND   (from the occupations)"
fi
if [[ -n ${O_VBM:-} ]]; then
  kv "VBM, highest occupied (eV)"  "$O_VBM   band $O_VB, spin $O_VS, k-pt $O_VK  ($O_VKC)"
  kv "CBM, lowest unoccupied (eV)" "$O_CBM   band $O_CB, spin $O_CS, k-pt $O_CK  ($O_CKC)"
  [[ -n ${O_DG:-} ]] && kv "smallest direct gap (eV)" "$O_DG   k-pt $O_DGK  ($O_DGKC)"
  kv "VBM, CBM minus E-fermi (eV)" "$O_VREL,  $O_CREL"
  kv "partially-occupied states" "$O_NPART"
elif [[ -n ${V_GAP:-} ]]; then
  kv "VBM (eV)" "$V_VBM   k ($V_VK)"
  kv "CBM (eV)" "$V_CBM   k ($V_CK)"
fi
[[ -n ${O_NODATA:-} ]] && kv "eigenvalues" "no final eigenvalue block in OUTCAR"

#================================ OCCUPATIONS ================================
hdr "Occupations"
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
  kv "NELECT" "${NELECT:-?}"
  if   [[ $NONCOL == T || $LSORBIT == T ]]; then kv "electrons per band" "1 (non-collinear / SOC)"
  elif ((SPINPAIR));                        then kv "electrons per band" "2 (ISPIN=1)"
  else                                           kv "electrons per band" "1 per spin (ISPIN=2)"; fi
  if [[ ${ISPIN%.*} == 2 ]]; then
    kv "occupied bands" "${N_OCC}   (spin up ${NOCC1}, spin down ${NOCC2})"
  else
    kv "occupied bands" "${N_OCC}"
  fi
  kv "expected from NELECT" "${NEXP}"
  # Only defined with whole occupations: with partially occupied bands the
  # count of "occupied" ones is a threshold, not a number of electrons.
  if [[ ${NPART:-0} -eq 0 ]]; then
    if [[ ${N_OCC} == ${NEXP} ]]; then chk_ok "occupied bands (${N_OCC}) match NELECT"
    else chk_warn "occupied bands (${N_OCC}) differ from the ${NEXP} NELECT gives, with no partial occupations"; fi
  fi
  kv "partially occupied bands" "${NPART:-0}$( [[ ${NPART:-0} -gt 0 ]] && echo "   (highest: band ${HIPART})")"
  nb=${NBANDS%.*}
  [[ ${nb:-0} -gt 0 ]] && kv "NBANDS" "${nb}   ($((nb - N_OCC)) above the occupied)"
  PWMAX=$(grep -iE 'maximum number of plane-waves' "$OUT" | head -1 | awk '{print $NF+0}')
  PWMIN=$(grep -E '^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:.*plane waves' "$OUT" | awk '{n=$NF+0; if(min==""||n<min)min=n} END{print min+0}')
  CEIL=${PWMIN:-$PWMAX}
  [[ ${CEIL:-0} -gt 0 ]] && kv "plane waves per k-point" "${CEIL}   (fewest over the k-points)"
else
  kv "occupations" "no final eigenvalue block in OUTCAR"
fi

#==================================== GW =====================================
if ((gw_family)); then
  hdr "GW quasiparticles"
  _gwout="$(awk '
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
      printf "  %-28s %d\n", "QP tables (iterations)", niter;
      printf "  %-28s %.4f   %s\n", "KS gap (eV)", ksgap, tolower(kskind);
      printf "  %-28s %.4f   %s\n", "QP gap (eV)", qpgap, tolower(kind);
      printf "  %-28s %+.4f\n", "QP - KS gap (eV)", qpgap-ksgap;
      printf "  %-28s %.4f -> %.4f   (%+.4f)   band %s, k-pt %s -> %s\n", "VBM, KS -> QP (eV)",
             ksv, qpv, qpv-ksv, vbi, kvk, vkk;
      printf "  %-28s %.4f -> %.4f   (%+.4f)   band %s, k-pt %s -> %s\n", "CBM, KS -> QP (eV)",
             ksc, qpc, qpc-ksc, cbi, kck, ckk;
      printf "  %-28s k-pt %s  (%.4f %.4f %.4f)\n", "QP VBM at", vkk,KX[vkk],KY[vkk],KZ[vkk];
      printf "  %-28s k-pt %s  (%.4f %.4f %.4f)\n", "QP CBM at", ckk,KX[ckk],KY[ckk],KZ[ckk];
      # A rigid ("scissor") correction leaves the extrema where they were. If an
      # edge migrates to another k-point the correction is k-dependent, which is
      # physical but far more sensitive to ENCUTGW/NBANDS convergence.
      if(kvk!=vkk || kck!=ckk) print "__EDGEMOVE__";
      if(qpgap<ksgap) print "__GAPCLOSE__";
      if(zn>0){ printf "  %-28s %.3f   over %d states\n", "mean Z", zs/zn, zn;
                if(zs/zn<0.6) print "__LOWZ__" }
    }' "$OUT")"
  if [[ $_gwout == NOQP* ]]; then
    kv "QP table" "none in OUTCAR"
    chk_warn "GW run without a KS/QP-energies table in its OUTCAR"
  else
    printf '%s\n' "$_gwout" | grep -v '^__'
  fi
fi

#================================= META-GGA ==================================
# A tau-dependent meta-GGA needs the kinetic-energy density, which CHGCAR does
# not hold (so a frozen-charge run cannot rebuild the potential), LASPH, and
# POTCARs that carry the core kinetic-energy density.
if [[ -n ${_mgga:-} ]]; then
  hdr "meta-GGA (${_mgga})"
  if [[ -s POTCAR ]]; then
    _ked=$(grep -c "kinetic energy-density" POTCAR 2>/dev/null || true); _ked=${_ked//[^0-9]/}; _ked=${_ked:-0}
    _nspec=$(awk '/VRHFIN/{n++} END{print n+0}' POTCAR 2>/dev/null); _nspec=${_nspec:-0}
    kv "POTCAR kin. energy density" "${_ked} block(s) for ${_nspec} species"
    if (( _ked == 0 )); then
      chk_fail "METAGGA=${_mgga}: the POTCAR carries no kinetic-energy-density block"
    elif (( _nspec > 0 && _ked < _nspec )); then
      chk_warn "METAGGA=${_mgga}: only ${_ked} of ${_nspec} POTCAR species carry kinetic-energy density"
    else
      chk_ok "METAGGA=${_mgga}: every POTCAR species carries kinetic-energy density"
    fi
  else
    kv "POTCAR" "absent: kinetic-energy density not verifiable"
  fi
  _ich=${ICHARG%.*}
  kv "ICHARG" "${ICHARG:-?}"
  if [[ $_ich =~ ^-?[0-9]+$ ]]; then
    if (( _ich >= 10 )); then chk_fail "METAGGA=${_mgga} with ICHARG=${_ich}: the kinetic-energy density is not in CHGCAR"
    else chk_ok "METAGGA=${_mgga} run self-consistently (ICHARG=${_ich})"; fi
  fi
  kv "LASPH" "$(getlog LASPH)"
  if [[ $(getlog LASPH) == T ]]; then chk_ok "METAGGA=${_mgga} with LASPH=.TRUE."
  else chk_fail "METAGGA=${_mgga} without LASPH=.TRUE."; fi
  _lmt=$(getp LMAXTAU); [[ -n $_lmt ]] && kv "LMAXTAU" "${_lmt%.*}"
  # The first k-point against the sibling Scf: the same Hamiltonian must give
  # the same eigenvalues there.
  _scf=""
  for _c in ../Scf ../SCF ../scf ../1_Scf ../0_Scf; do
    [[ -f $_c/OUTCAR ]] && { _scf=$_c; break; }
  done
  if [[ -n $_scf ]]; then
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
      kv "reference Scf" "$_scf/OUTCAR"
      kv "k-pt 1, this run (eV)" "${_eb% }"
      kv "k-pt 1, Scf (eV)"      "${_ea% }"
      kv "max |difference| (eV)" "$_dmax"
      if awk -v d="$_dmax" 'BEGIN{exit !(d<=0.05)}'; then
        chk_ok "first k-point eigenvalues agree with $_scf to $_dmax eV"
      else
        chk_fail "first k-point eigenvalues differ from $_scf by $_dmax eV"
      fi
    fi
  fi
fi

#================================== CHECKS ===================================
# VASP's own requirements, stated as facts. Physics advice lives elsewhere.
ISM=${ISMEAR%.*}
if ((gw_family)); then
  if [[ -n ${NCORE:-} && ${NCORE%.*} -gt 1 ]]; then
    chk_fail "GW with NCORE=${NCORE%.*}: GW requires NCORE=1 (vasp.at/wiki/Optimizing_the_parallelization)"
  fi
  if [[ -n ${NOMEGA:-} && ${NOMEGA%.*} -gt 0 ]]; then
    for _t in NTAUPAR NOMEGAPAR; do
      _v="$(getp "$_t")"; _v="${_v%.*}"
      if [[ -n $_v && $_v -gt 0 ]] && (( ${NOMEGA%.*} % _v != 0 )); then
        chk_fail "${_t}=${_v} is not a divisor of NOMEGA=${NOMEGA%.*} (vasp.at/wiki/Practical_guide_to_GW_calculations)"
      fi
    done
  fi
fi
if [[ -n ${KPAR:-} && ${KPAR%.*} -gt 1 && -n ${NKPTS:-} && ${NKPTS%.*} -gt 0 ]]; then
  if (( ${NKPTS%.*} % ${KPAR%.*} != 0 )); then
    _idle=$(awk -v n="${NKPTS%.*}" -v k="${KPAR%.*}" 'BEGIN{g=int((n+k-1)/k); printf "%.1f", 100*(1-n/(g*k))}')
    chk_warn "KPAR=${KPAR%.*} does not divide NKPTS=${NKPTS%.*}: ${_idle}% of the k-group slots are empty"
  fi
fi
if [[ $ISM == -5 && -n ${NKPTS:-} && ${NKPTS%.*} -lt 4 ]]; then
  chk_warn "ISMEAR=-5 with ${NKPTS%.*} k-points: the tetrahedron method needs at least 4"
fi

hdr "Checks"
for c in "${CHK[@]}"; do printf '%s\n' "$c"; done

#================================== ENERGY ===================================
hdr "Energy"
# Both from the summary VASP prints once per COMPLETED ionic step ("free  energy
# TOTEN" and "energy  without entropy=", two spaces each). Every SCF iteration
# prints a look-alike line with one space; taking the last of those gave, for a
# running job, an energy(sigma->0) from the unfinished next step beside the
# TOTEN of the last finished one -- 0.95 eV apart on a real run.
ETOT=$(grep 'free  energy   TOTEN' "$OUT" | tail -n1 | awk '{print $(NF-1)}')
ESIG0=$(grep 'energy  without entropy=' "$OUT" | tail -n1 | awk '{print $NF}')
NSTEP_E=$(grep -c 'free  energy   TOTEN' "$OUT")
[[ -n ${ETOT:-} ]]  && kv "TOTEN (eV)"            "$ETOT   (ionic step ${NSTEP_E}, the last completed)"
[[ -n ${ESIG0:-} ]] && kv "energy(sigma->0) (eV)" "$ESIG0"
if [[ -n ${ETOT:-} && ${NIONS%.*} -gt 0 ]]; then
  kv "TOTEN per atom (eV)" "$(awk -v e="$ETOT" -v n="${NIONS%.*}" 'BEGIN{printf "%.6f", e/n}')"
fi

echo
if [[ $FAILS -gt 0 ]]; then
  printf '%s%s RESULT: FAIL  (%d failed, %d warnings)%s\n' "$B" "$RED" "$FAILS" "$WARNS" "$R"; exit 1
elif [[ $WARNS -gt 0 ]]; then
  printf '%s%s RESULT: PASS  (%d warnings)%s\n' "$B" "$YEL" "$WARNS" "$R"; exit 0
else
  printf '%s%s RESULT: PASS  (every check passed)%s\n' "$B" "$GRN" "$R"; exit 0
fi
