#!/usr/bin/env bash
#==============================================================================
# vasp_diagnose.sh  --  smart root-cause analysis of a FAILED VASP run.
#
#   Parses everything a crashed calculation folder left behind (the SLURM
#   .out/.err logs, `sacct` if reachable, the OUTCAR header, the INCAR) and
#   reports WHY the job died -- OOM, walltime, segfault/crash, missing input,
#   or non-convergence -- together with the MEASURED peak memory per rank and
#   the parallel layout it actually ran with.
#
#   It ALSO classifies whether the DATA is still usable despite the exit
#   (FULL / PLOTTABLE / PARTIAL / NOT_USABLE): a DFT or DFT+U run that was killed
#   AFTER it wrote the eigenvalues / occupations is often fully usable for
#   post-processing (bands, DOS, the occupation matrices a Hubbard-U fit needs)
#   -- the death only truncated the footer/file-writing. (Physics interpretation
#   itself -- gaps, magnetism, CBM/VBM -- lives in `vasp-check`.)
#
#   It prints a human report AND a single machine-readable line:
#       WP_DIAG cause=OOM measured_mb=18150 ranks=120 kpar=3 ncore=1 npar=40 \
#               nodes=4 nomega=100 is_gw=1
#   so a relaunch wrapper can feed the numbers straight into the ONE refine core
#   (vasp_test_recommend.py) and relaunch with a fixed configuration.
#
#   This does NOT modify anything -- it only reads.
#
# USAGE
#   vasp-diagnose [DIR]        # default DIR = .
#   vasp-diagnose -h | --help
#==============================================================================
set -uo pipefail

DIR="."
case "${1:-}" in
    -h|--help)
        sed -n '2,28p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "" ) : ;;
    * ) DIR="$1" ;;
esac
[[ -d "$DIR" ]] || { echo "vasp-diagnose: no such directory: $DIR" >&2; exit 2; }

c_b=$'\e[1m'; c_r=$'\e[31m'; c_y=$'\e[33m'; c_g=$'\e[32m'; c_0=$'\e[0m'
[[ -t 1 ]] || { c_b=""; c_r=""; c_y=""; c_g=""; c_0=""; }

_oc="$DIR/OUTCAR"
_incar="$DIR/INCAR"

# --- locate the scheduler logs (newest first) ------------------------------ #
shopt -s nullglob
_logs=( "$DIR"/VASP-*.out "$DIR"/VASP-*.err "$DIR"/slurm-*.out "$DIR"/slurm-*.err "$DIR"/*.out "$DIR"/*.err )
shopt -u nullglob
# de-dup while keeping order, newest by mtime
_log_list="$(printf '%s\n' "${_logs[@]}" 2>/dev/null | awk '!seen[$0]++' | xargs -r ls -1t 2>/dev/null)"

# --- job id (from a VASP-*-<id>.out / slurm-<id>.out name) ----------------- #
JOBID=""
for f in $_log_list; do
    _id="$(basename "$f" | grep -oE '[0-9]{5,}' | tail -1)"
    [[ -n "$_id" ]] && { JOBID="$_id"; break; }
done

# --- sacct (authoritative State + MaxRSS), if reachable -------------------- #
SACCT_STATE=""; SACCT_MAXRSS_MB=""; SACCT_AVERSS_MB=""; SACCT_REQMEM=""
_to_mb() { # K/M/G[suffix] -> MB integer
    local v="$1"; [[ -z "$v" || "$v" == "0" ]] && { echo ""; return; }
    local n="${v%[KMGTkmgt]*}" u="${v: -1}"
    case "$u" in
        K|k) awk "BEGIN{printf \"%.0f\", $n/1024}" ;;
        M|m) awk "BEGIN{printf \"%.0f\", $n}" ;;
        G|g) awk "BEGIN{printf \"%.0f\", $n*1024}" ;;
        T|t) awk "BEGIN{printf \"%.0f\", $n*1048576}" ;;
        *)   awk "BEGIN{printf \"%.0f\", $v/1048576}" ;;   # plain bytes
    esac
}
if [[ -n "$JOBID" ]] && command -v sacct >/dev/null 2>&1; then
    # --units=M pins EVERY memory field to MB. Without it sacct may hand back MaxRSS
    # with a "K" suffix but AveRSS as raw bytes, and _to_mb's suffix-less branch
    # (which assumes KB) then reads AveRSS 1024x too large. Older SLURM has no
    # --units, so fall back to the suffixed form.
    _sa="$(sacct -j "$JOBID" --format=State,MaxRSS,AveRSS,ReqMem -P -n --units=M 2>/dev/null)"
    [[ -z "$_sa" ]] && _sa="$(sacct -j "$JOBID" --format=State,MaxRSS,AveRSS,ReqMem -P -n 2>/dev/null)"
    if [[ -n "$_sa" ]]; then
        SACCT_STATE="$(printf '%s\n' "$_sa" | awk -F'|' 'NR==1{print $1}' | awk '{print $1}')"
        # MaxRSS is reported on the .batch/step lines; take the largest
        _mr="$(printf '%s\n' "$_sa" | awk -F'|' '{print $2}' | grep -oE '[0-9.]+[KMGT]?' | sort -t. -k1 -n | tail -1)"
        SACCT_MAXRSS_MB="$(_to_mb "$_mr")"
        # AveRSS = MEAN over ranks. The node total SLURM enforces is mean x ranks,
        # so this -- not MaxRSS -- is what a re-size must be based on (rank 0 is
        # typically a large outlier on k-point-parallel runs).
        _ar="$(printf '%s\n' "$_sa" | awk -F'|' '{print $3}' | grep -oE '[0-9.]+[KMGT]?' | sort -t. -k1 -n | tail -1)"
        SACCT_AVERSS_MB="$(_to_mb "$_ar")"
        # A mean can never exceed the max it is a mean of. If it does, the two fields
        # came back in different units -> drop AveRSS rather than re-size the job from
        # a number that is off by 1024x.
        if [[ -n "$SACCT_AVERSS_MB" && -n "$SACCT_MAXRSS_MB" ]] && awk -v a="$SACCT_AVERSS_MB" \
             -v m="$SACCT_MAXRSS_MB" 'BEGIN{exit !(m>0 && a>m*1.001)}'; then
            SACCT_AVERSS_MB=""
        fi
        SACCT_REQMEM="$(printf '%s\n' "$_sa" | awk -F'|' 'NR==1{print $4}')"
    fi
fi

_grep_logs() { [[ -n "$_log_list" ]] && grep -aiE "$1" $_log_list 2>/dev/null | head -3; }

# --- layout from the OUTCAR header (most reliable) ------------------------- #
RANKS=""; NODES=""; KPAR=""; RPK=""; NCORE=""
if [[ -f "$_oc" ]]; then
    _run="$(grep -m1 -aE 'running[[:space:]]+[0-9]+[[:space:]]+mpi-ranks' "$_oc" 2>/dev/null)"
    RANKS="$(grep -oE 'running[[:space:]]+[0-9]+' <<<"$_run" | grep -oE '[0-9]+' | head -1)"
    NODES="$(grep -oE 'on[[:space:]]+[0-9]+[[:space:]]+nodes' <<<"$_run" | grep -oE '[0-9]+' | head -1)"
    _dk="$(grep -m1 -aE 'distrk:[[:space:]]*each k-point on' "$_oc" 2>/dev/null)"
    RPK="$(grep -oE 'on[[:space:]]+[0-9]+[[:space:]]+cores' <<<"$_dk" | grep -oE '[0-9]+' | head -1)"
    KPAR="$(grep -oE '[0-9]+[[:space:]]+groups' <<<"$_dk" | grep -oE '[0-9]+' | head -1)"
    NCORE="$(grep -m1 -aoE 'one band on NCORE=[[:space:]]*[0-9]+' "$_oc" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
fi
# fall back to the slurm script / INCAR for anything missing
_slurm="$(ls -1t "$DIR"/slurm_vasptest.sh "$DIR"/slurm.sh 2>/dev/null | head -1)"
[[ -z "$RANKS"  && -n "$_slurm" ]] && RANKS="$(grep -m1 -oiE '[-]{2}ntasks=[0-9]+' "$_slurm" | grep -oE '[0-9]+')"
[[ -z "$NODES"  && -n "$_slurm" ]] && NODES="$(grep -m1 -oiE '[-]{2}nodes=[0-9]+' "$_slurm" | grep -oE '[0-9]+')"
[[ -z "$KPAR"   && -f "$_incar" ]] && KPAR="$(grep -m1 -oiE '^[[:space:]]*KPAR[[:space:]]*=[[:space:]]*[0-9]+' "$_incar" | grep -oE '[0-9]+')"
[[ -z "$NCORE"  && -f "$_incar" ]] && NCORE="$(grep -m1 -oiE '^[[:space:]]*NCORE[[:space:]]*=[[:space:]]*[0-9]+' "$_incar" | grep -oE '[0-9]+')"
RANKS="${RANKS:-0}"; NODES="${NODES:-1}"; KPAR="${KPAR:-1}"; NCORE="${NCORE:-1}"
(( KPAR < 1 )) && KPAR=1; (( NCORE < 1 )) && NCORE=1
[[ -z "$RPK" || "$RPK" -lt 1 ]] && RPK=$(( RANKS / KPAR )); (( RPK < 1 )) && RPK=1
NPAR=$(( RPK / NCORE )); (( NPAR < 1 )) && NPAR=1

# --- requested mem-per-cpu (the cgroup limit it hit) ----------------------- #
REQ_MB=""
[[ -n "$_slurm" ]] && REQ_MB="$(grep -m1 -oiE '[-]{2}mem-per-cpu=[0-9]+' "$_slurm" | grep -oE '[0-9]+')"

# --- is this GW? ----------------------------------------------------------- #
IS_GW=0; ALGO=""; NOMEGA=""
if [[ -f "$_incar" ]]; then
    ALGO="$(grep -m1 -ioE '^[[:space:]]*ALGO[[:space:]]*=[[:space:]]*[A-Za-z0-9_]+' "$_incar" | sed -E 's/.*=[[:space:]]*//')"
    NOMEGA="$(grep -m1 -oiE '^[[:space:]]*NOMEGA[[:space:]]*=[[:space:]]*[0-9]+' "$_incar" | grep -oE '[0-9]+')"
fi
case "${ALGO^^}" in GW*|EVGW*|QPGW*|SCGW*|G0W0*|ACFDT*|RPA*|CHI*|BSE*) IS_GW=1 ;; esac

# --- /usr/bin/time -v RSS fallback (kbytes) -------------------------------- #
TIME_RSS_MB=""
if [[ -n "$_log_list" ]]; then
    _rk="$(grep -aE 'Maximum resident set size' $_log_list 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)"
    [[ -n "$_rk" ]] && TIME_RSS_MB="$(awk "BEGIN{printf \"%.0f\", $_rk/1024}")"
fi

# --- VASP's own OUTCAR memory line (last resort) --------------------------- #
OUTCAR_MB=""
if [[ -f "$_oc" ]]; then
    _mk="$(grep -aE 'total amount of memory used by VASP' "$_oc" 2>/dev/null | grep -oE '[0-9]+' | tail -1)"
    [[ -n "$_mk" ]] && OUTCAR_MB="$(awk "BEGIN{printf \"%.0f\", $_mk/1024}")"
fi

# --- VASP's OWN reported GW requirement (AUTHORITATIVE floor) --------------- #
# Conventional GW prints, during the response-function setup:
#   min. memory requirement per mpi rank  7282.6 MB, per node 873917.5 MB
#   Available memory per mpi rank: 4961 MB, required memory: 7282 MB.
# This is the true per-rank FLOOR (NOMEGA-independent) -- far more reliable than the
# OOM MaxRSS (which is capped at the cgroup limit). Search the OUTCAR AND the logs.
VASP_REQ_MB=""; VASP_PERNODE_MB=""; ENCUTGW=""; NBANDS=""
_srcs=""
[[ -f "$_oc" ]] && _srcs="$_oc"
[[ -n "$_log_list" ]] && _srcs="$_srcs $_log_list"
if [[ -n "$_srcs" ]]; then
    _mm="$(grep -ahE 'min\.? *memory requirement per mpi rank' $_srcs 2>/dev/null | tail -1)"
    if [[ -n "$_mm" ]]; then
        VASP_REQ_MB="$(grep -oE 'per mpi rank[[:space:]]+[0-9]+(\.[0-9]+)?' <<<"$_mm" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
        VASP_PERNODE_MB="$(grep -oE 'per node[[:space:]]+[0-9]+(\.[0-9]+)?' <<<"$_mm" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
    fi
    # the "required memory: R MB" line is the value the OOM check tripped on
    _rq="$(grep -ahE 'required memory:[[:space:]]*[0-9]+' $_srcs 2>/dev/null | grep -oE 'required memory:[[:space:]]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' | sort -n | tail -1)"
    # use the larger of the two reported numbers as the per-rank floor
    if [[ -n "$_rq" ]]; then
        if [[ -z "$VASP_REQ_MB" ]] || awk "BEGIN{exit !($_rq > ${VASP_REQ_MB:-0})}"; then VASP_REQ_MB="$_rq"; fi
    fi
    [[ -n "$VASP_REQ_MB" ]] && VASP_REQ_MB="$(awk "BEGIN{printf \"%.0f\", $VASP_REQ_MB}")"
    [[ -n "$VASP_PERNODE_MB" ]] && VASP_PERNODE_MB="$(awk "BEGIN{printf \"%.0f\", $VASP_PERNODE_MB}")"
fi
[[ -f "$_oc" ]] && ENCUTGW="$(grep -m1 -aoE 'ENCUTGW[[:space:]]*=[[:space:]]*[0-9.]+' "$_oc" | grep -oE '[0-9.]+' | head -1)"
[[ -z "$ENCUTGW" && -f "$_incar" ]] && ENCUTGW="$(grep -m1 -ioE '^[[:space:]]*ENCUTGW[[:space:]]*=[[:space:]]*[0-9.]+' "$_incar" | grep -oE '[0-9.]+' | head -1)"
[[ -f "$_oc" ]] && NBANDS="$(grep -m1 -aoE 'NBANDS[[:space:]]*=[[:space:]]*[0-9]+' "$_oc" | grep -oE '[0-9]+' | head -1)"

# --- decide the ROOT CAUSE (priority order) -------------------------------- #
CAUSE="UNKNOWN"; EVIDENCE=""; FINISHED=0
if [[ -f "$_oc" ]] && grep -qaE 'Total CPU time used|Voluntary context switches|reached required accuracy' "$_oc" 2>/dev/null; then
    FINISHED=1
fi
_oom="$(_grep_logs 'oom-kill|out of memory|out-of-memory|killed by the cgroup|cgroup out-of-memory|Cannot allocate memory|insufficient virtual memory|memory exhausted|std::bad_alloc|severe.*allocat|OUT_OF_MEMORY')"
_time="$(_grep_logs 'DUE TO TIME LIMIT|TIME LIMIT|CANCELLED.*TIME|TIMEOUT')"
_segv="$(_grep_logs 'Segmentation fault|SIGSEGV|SIGBUS|signal (11|6|7)|core dumped|BAD TERMINATION|EXIT CODE: [0-9]')"
_miss="$(_grep_logs 'No such file|not found|ERROR.*POTCAR|ERROR.*POSCAR|WAVECAR.*(missing|empty)')"
_relax=0
if [[ -f "$_incar" ]] && grep -qiE '^[[:space:]]*NSW[[:space:]]*=[[:space:]]*([2-9]|[0-9]{2,})' "$_incar" 2>/dev/null; then
    _relax=1
fi
# A job SLURM still lists as RUNNING/PENDING has not failed and has not finished --
# diagnosing it as either is wrong. This must be tested BEFORE any completion
# heuristic: sacct is authoritative about the job's state, the OUTCAR is not.
if [[ "$SACCT_STATE" == RUNNING* || "$SACCT_STATE" == PENDING* \
      || "$SACCT_STATE" == REQUEUED* || "$SACCT_STATE" == RESIZING* ]]; then
    CAUSE="RUNNING"; EVIDENCE="sacct State=${SACCT_STATE} -- the job has not ended yet."
elif [[ "$SACCT_STATE" == OUT_OF_MEMORY* || -n "$_oom" ]]; then
    CAUSE="OOM"; EVIDENCE="${_oom:-sacct State=OUT_OF_MEMORY}"
elif [[ "$SACCT_STATE" == TIMEOUT* || -n "$_time" ]]; then
    CAUSE="TIME"; EVIDENCE="${_time:-sacct State=TIMEOUT}"
elif [[ -n "$_segv" ]]; then
    CAUSE="CRASH"; EVIDENCE="$_segv"
elif [[ -n "$_miss" ]]; then
    CAUSE="MISSING_INPUT"; EVIDENCE="$_miss"
elif (( FINISHED )); then
    CAUSE="COMPLETED"; EVIDENCE="OUTCAR shows the run finished normally."
elif [[ -f "$_oc" ]] && (( ! _relax )) \
     && grep -qaE 'aborting loop because EDIFF is reached' "$_oc" 2>/dev/null; then
    # NSW<=1 only. In a relaxation this line is printed once per IONIC step, so it is
    # already true at step 1 of 150 and says nothing about the run being over.
    CAUSE="COMPLETED"; EVIDENCE="SCF converged (EDIFF reached)."
elif (( _relax )) && [[ -f "$_oc" ]] \
     && grep -qaE 'aborting loop because EDIFF is reached' "$_oc" 2>/dev/null; then
    CAUSE="UNFINISHED"; EVIDENCE="ionic loop never printed 'reached required accuracy' \
(the SCF converges each ionic step, which is not run completion)."
else
    CAUSE="UNKNOWN"; EVIDENCE="no OOM/time/crash signature in the logs."
fi

# --- pick the MEASURED peak memory per rank -------------------------------- #
# For GW, PROVISION TO VASP's OWN printed "min. memory requirement" on an OOM -- it is the
# number VASP will try to allocate and it is NOMEGA-stable. (An earlier x0.80 "real-RSS"
# discount OOM'd the next run at NOMEGA=100 -- do NOT discount.) If the job PROGRESSED
# (not OOM), sacct MaxRSS is the true peak for THIS run and is used directly.
MEAS_MB=""; MEAS_SRC=""
if (( IS_GW )) && [[ "$CAUSE" != OOM && -n "$SACCT_MAXRSS_MB" ]]; then
    MEAS_MB="$SACCT_MAXRSS_MB"; MEAS_SRC="sacct MaxRSS (real peak; the job progressed)"
elif (( IS_GW )) && [[ "$CAUSE" == OOM && -n "$VASP_REQ_MB" ]]; then
    MEAS_MB="$VASP_REQ_MB"; MEAS_SRC="VASP's own required memory (provision to it; OOM capped the MaxRSS)"
elif [[ -n "$SACCT_MAXRSS_MB" ]]; then MEAS_MB="$SACCT_MAXRSS_MB"; MEAS_SRC="sacct MaxRSS"
elif [[ -n "$TIME_RSS_MB" ]];   then MEAS_MB="$TIME_RSS_MB";   MEAS_SRC="/usr/bin/time -v RSS"
elif (( IS_GW )) && [[ -n "$VASP_REQ_MB" ]]; then MEAS_MB="$VASP_REQ_MB"; MEAS_SRC="VASP's own required memory"
elif [[ "$CAUSE" == OOM && -n "$REQ_MB" ]]; then MEAS_MB="$REQ_MB"; MEAS_SRC="cgroup limit it hit (mem-per-cpu)"
elif [[ -n "$OUTCAR_MB" ]];     then MEAS_MB="$OUTCAR_MB";     MEAS_SRC="OUTCAR (VASP table; real RSS is larger)"
fi

# --- DATA SALVAGE: is the physics usable even though the job died? ---------- #
# A DFT / DFT+U run that was OOM-killed or hit the walltime AFTER it produced the
# eigenvalues/occupations is often still fully usable for post-processing (bands,
# DOS, the occupation matrices a Hubbard-U fit needs) -- the death only truncated
# the file-writing/footer. This block classifies what survived to disk.
NKPTS=""; ISPIN=""
if [[ -f "$_oc" ]]; then
    NKPTS="$(grep -m1 -aoE 'NKPTS[[:space:]]*=[[:space:]]*[0-9]+' "$_oc" | grep -oE '[0-9]+' | head -1)"
    ISPIN="$(grep -m1 -aoE 'ISPIN[[:space:]]*=[[:space:]]*[0-9]+' "$_oc" | grep -oE '[0-9]+' | head -1)"
fi
NKPTS="${NKPTS:-0}"; ISPIN="${ISPIN:-1}"
_want=$NKPTS; [[ "$ISPIN" == 2 ]] && _want=$(( NKPTS * 2 ))

# vasprun.xml well-formed? (pymatgen Vasprun/BSVasprun gate)
VR_OK=0; [[ -s "$DIR/vasprun.xml" ]] && tail -c 8192 "$DIR/vasprun.xml" 2>/dev/null | grep -q '</modeling>' && VR_OK=1
# EIGENVAL complete? (header line 6: NELECT NKPTS NBANDS; count k-blocks)
EIG_OK=0
if [[ -s "$DIR/EIGENVAL" ]]; then
    _ew="$(awk 'NR==6{print $2; exit}' "$DIR/EIGENVAL")"
    _eh="$(awk 'NR>6 && NF==4 && $1 ~ /^-?[0-9.]+$/{c++} END{print c+0}' "$DIR/EIGENVAL")"
    [[ "${_ew:-0}" -gt 0 && "${_eh:-0}" -ge "${_ew:-1}" ]] && EIG_OK=1
fi
# final eigenvalue blocks inside OUTCAR (skip the "plane waves per k-point" listing)
OUTEIG_OK=0
if [[ -f "$_oc" && "$NKPTS" -gt 0 ]]; then
    _oh="$(awk '/spin component/{sp=$NF}
        /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/{k[sp"|"$2]=1}
        END{n=0;for(i in k)n++;print n+0}' "$_oc")"
    [[ "${_oh:-0}" -ge "${_want:-1}" ]] && OUTEIG_OK=1
fi
# occupation matrices present? (LDA+U deliverable for a Hubbard-U fit)
OCC_OK=0
[[ -f "$_oc" ]] && grep -qaE 'onsite density matrix|occupancies and eigenvalues of spin' "$_oc" 2>/dev/null && OCC_OK=1
# QP table (GW deliverable)
QP_OK=0; QP_HAVE=0
if (( IS_GW )); then
    QP_HAVE="$(awk '/QP shifts/ && /iteration/{delete K;next}
        /^[[:space:]]*k-point[[:space:]]+[0-9]+[[:space:]]*:/ && $0 !~ /plane waves/{kp=$2+0}
        /KS-energies/ && /QP-energies/{K[kp]=1}
        END{n=0;for(i in K)n++;print n+0}' "$_oc" 2>/dev/null)"
    [[ "$NKPTS" -gt 0 && "${QP_HAVE:-0}" -ge "$NKPTS" ]] && QP_OK=1
fi

USABLE="UNKNOWN"; USE_WHY=""
if [[ "$CAUSE" == RUNNING ]]; then
    # Nothing is final while the job is alive: VASP writes EIGENVAL/DOSCAR/WAVECAR/
    # CHGCAR at the END, so mid-run they are empty and no verdict on the data holds.
    USABLE="IN_PROGRESS"; USE_WHY="job still running -- final outputs are not written yet"
elif [[ "$CAUSE" == COMPLETED ]]; then
    # Only claim "all outputs present" after actually confirming one is readable --
    # a 0-byte EIGENVAL/DOSCAR exists but contains nothing.
    if (( VR_OK || EIG_OK )); then USABLE="FULL"; USE_WHY="run finished; outputs verified readable"
    else USABLE="PARTIAL"; USE_WHY="run finished, but vasprun.xml/EIGENVAL are missing or empty"
    fi
elif (( IS_GW )); then
    if   (( QP_OK )); then USABLE="PLOTTABLE"; USE_WHY="QP table complete for all ${NKPTS} k-points"
    elif (( QP_HAVE > 0 )); then USABLE="PARTIAL"; USE_WHY="QP table only partial (${QP_HAVE}/${NKPTS} k-points)"
    elif (( OUTEIG_OK )); then USABLE="PARTIAL"; USE_WHY="no QP yet, but the preceding DFT eigenvalues are complete (DFT-level bands usable)"
    else USABLE="NOT_USABLE"; USE_WHY="run stopped before/inside the GW step; no QP, no complete eigenvalues"
    fi
else
    if   (( VR_OK )); then USABLE="PLOTTABLE"; USE_WHY="vasprun.xml well-formed -> pymatgen parses it"
    elif (( EIG_OK )); then USABLE="PLOTTABLE"; USE_WHY="EIGENVAL complete -> bands readable"
    elif (( OUTEIG_OK )); then USABLE="PARTIAL"; USE_WHY="eigenvalues complete in OUTCAR (vasprun/EIGENVAL truncated) -> scrape from OUTCAR"
    elif (( OCC_OK )); then USABLE="PARTIAL"; USE_WHY="occupations present in OUTCAR -> usable for a Hubbard-U fit even though the run died"
    else USABLE="NOT_USABLE"; USE_WHY="eigenvalues/occupations incomplete and vasprun.xml truncated"
    fi
    (( OCC_OK )) && [[ "$USABLE" != NOT_USABLE ]] && USE_WHY="${USE_WHY}; occupation matrices present (U-fit data OK)"
fi

# --- human report ---------------------------------------------------------- #
echo "${c_b}=== vasp-diagnose : $DIR ===${c_0}"
echo "  job logs        : $(printf '%s ' $(basename -a $_log_list 2>/dev/null) | sed 's/ $//')"
echo "  job id          : ${JOBID:-?}    sacct state: ${SACCT_STATE:-(sacct n/a)}"
echo "  ran at          : ${RANKS} ranks on ${NODES} node(s); KPAR=${KPAR} NCORE=${NCORE} NPAR=${NPAR} (${RPK} ranks/k-group)"
if [[ -n "$MEAS_MB" ]]; then
    echo "  peak memory/rank: ${MEAS_MB} MB   (${MEAS_SRC})"
    if [[ -n "$SACCT_AVERSS_MB" ]] && (( SACCT_AVERSS_MB > 0 )); then
        echo "  mean memory/rank: ${SACCT_AVERSS_MB} MB   (sacct AveRSS -- the node total is mean x ranks; re-sizing uses THIS)"
        awk -v m="${SACCT_MAXRSS_MB:-0}" -v a="$SACCT_AVERSS_MB" 'BEGIN{ if(a>0 && m/a>=1.5)
            printf "  rank imbalance  : x%.1f  (one rank dominates -- sizing from the peak would over-reserve by this factor)\n", m/a }'
    fi
    [[ -n "$REQ_MB" ]] && echo "  requested/rank  : ${REQ_MB} MB   (the cgroup limit)"
fi
if (( IS_GW )) && [[ -n "$VASP_REQ_MB" ]]; then
    echo "  VASP requirement: ${VASP_REQ_MB} MB/rank$( [[ -n "$VASP_PERNODE_MB" ]] && echo ", ${VASP_PERNODE_MB} MB/node" )   (VASP's own 'min. memory requirement' -- provision mem-per-cpu >= this; NOMEGA-stable)"
    [[ -n "$ENCUTGW" ]] && echo "  ENCUTGW         : ${ENCUTGW} eV   (drives the per-NODE response fn ~ ENCUTGW^3; the memory lever if a k-group won't fit a node)"
fi
case "$CAUSE" in
  OOM)  echo "  ${c_r}ROOT CAUSE${c_0}      : OUT-OF-MEMORY -- the per-rank request was too small for the real peak.";;
  TIME) echo "  ${c_y}ROOT CAUSE${c_0}      : WALLTIME -- the job ran out of time before finishing.";;
  CRASH)echo "  ${c_r}ROOT CAUSE${c_0}      : CRASH (segfault/abort) -- not a resource limit; check INCAR/inputs.";;
  MISSING_INPUT) echo "  ${c_r}ROOT CAUSE${c_0}      : MISSING/BAD INPUT file.";;
  COMPLETED) echo "  ${c_g}ROOT CAUSE${c_0}      : none -- the run appears to have FINISHED (not a failure).";;
  RUNNING) echo "  ${c_g}ROOT CAUSE${c_0}      : none -- the job is STILL RUNNING. Nothing to diagnose yet.";;
  UNFINISHED) echo "  ${c_y}ROOT CAUSE${c_0}      : ionic loop UNFINISHED -- the relaxation never reached EDIFFG."
              echo "                    Not a crash: no OOM/walltime/segfault signature. Either it is still"
              echo "                    running, it hit NSW, or it was cancelled.";;
  *)    echo "  ${c_y}ROOT CAUSE${c_0}      : UNKNOWN -- no clear signature; inspect the logs by hand.";;
esac
[[ -n "$EVIDENCE" ]] && { echo "  evidence        :"; echo "$EVIDENCE" | head -2 | cut -c1-104 | sed 's/^/      /'; }
case "$USABLE" in
  FULL)       echo "  ${c_g}DATA${c_0}            : FULL -- all outputs present (${USE_WHY}).";;
  PLOTTABLE)  echo "  ${c_g}DATA${c_0}            : USABLE/PLOTTABLE despite the exit -- ${USE_WHY}.";;
  PARTIAL)    echo "  ${c_y}DATA${c_0}            : PARTIAL -- ${USE_WHY}.";;
  NOT_USABLE) echo "  ${c_r}DATA${c_0}            : NOT usable -- ${USE_WHY}.";;
  *)          echo "  DATA            : ${USE_WHY:-could not assess}.";;
esac
case "$CAUSE" in
  OOM)  if (( IS_GW )); then
            echo "  fix             : the GW floor is NOMEGA-independent -- do NOT just raise MAXMEM.";
            echo "                    Spread the SAME ranks over MORE nodes (fewer ranks/node), or lower";
            echo "                    ENCUTGW (floor ~ ENCUTGW^3), then resubmit.";
        else
            echo "  fix             : raise the per-rank request and/or split across more nodes.";
            echo "                    then resubmit.";
        fi ;;
  TIME) echo "  fix             : longer walltime, or more ranks/nodes for speed.";;
  CRASH|MISSING_INPUT) echo "  fix             : not auto-fixable -- correct the input, then re-run the pipeline.";;
  RUNNING) echo "  next            : wait for the job to end, then re-run vasp-diagnose. 'vasp-check' already";
           echo "                    works on the partial OUTCAR if you want the physics so far.";;
  UNFINISHED) echo "  fix             : if it hit NSW, restart from CONTCAR (cp CONTCAR POSCAR). If the forces";
              echo "                    plateau above |EDIFFG|, the force NOISE FLOOR is the limit, not the";
              echo "                    optimiser -- see LREAL/ADDGRID/EDIFF before raising NSW.";;
esac
[[ "$USABLE" == PLOTTABLE || "$USABLE" == PARTIAL || "$USABLE" == FULL ]] && \
    echo "  salvage         : run 'vasp-check' here for the physics (gap, magnetism, CBM/VBM) on the surviving data."

# --- machine-readable summary line ---------------------------------------- # #
# vasp_req_mb / vasp_pernode_mb are VASP's OWN reported GW floor (authoritative, used by
# a relaunch wrapper to re-size). encutgw is the #1 reduction lever (floor ~ ENCUTGW^3).
echo "WP_DIAG cause=${CAUSE} usable=${USABLE} measured_mb=${MEAS_MB:-0} averss_mb=${SACCT_AVERSS_MB:-0} req_mb=${REQ_MB:-0} vasp_req_mb=${VASP_REQ_MB:-0} vasp_pernode_mb=${VASP_PERNODE_MB:-0} encutgw=${ENCUTGW:-0} nbands=${NBANDS:-0} ranks=${RANKS} kpar=${KPAR} ncore=${NCORE} npar=${NPAR} nodes=${NODES} nomega=${NOMEGA:-0} is_gw=${IS_GW}"
