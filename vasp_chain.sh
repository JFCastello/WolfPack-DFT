#!/usr/bin/env bash
###############################################################################
# vasp_chain.sh   (on PATH as: vasp-scf-loop, vasp-relax-loop)
#
# Converge a VASP calculation as a CHAIN of short jobs instead of one long one.
#
# WHY
#   Many schedulers make a long walltime wait a long time. A job that asks for
#   10 hours can sit in the queue for days while a 1-hour job backfills into a
#   gap immediately. This runs the same calculation as a sequence of short jobs:
#   each one caps its iterations to fit the walltime, restarts from the previous
#   one's wavefunction, and submits its own successor before exiting. You launch
#   it once and it keeps going until the calculation converges.
#
# HOW THE CHAIN CONTINUES ITSELF
#   Each job decides, after VASP exits, whether to submit the next one. There is
#   no --dependency chain: exactly as many jobs run as are needed, and nothing
#   is left queued when it converges. It also means a job killed by the
#   scheduler cannot submit a successor, so the chain stops by construction
#   rather than by a rule that might be wrong.
#
# USAGE
#   cd <calc folder>            # after vasp-dry-run, vasp-recommend-slurm, vasp-test
#   vasp-scf-loop               # a static SCF: chunks NELM
#   vasp-relax-loop             # a relaxation: chunks NSW, never NELM
#   ... --status                # where is it
#   ... --stop                  # finish the current chunk, then stop cleanly
#   ... --resume                # continue a stopped chain
#
# REQUIREMENTS
#   vasp-test must have run here: its slurm_vasptest.sh carries the MEASURED
#   memory and geometry, and .wolfpack/state.env the measured per-step rate.
#   Both are needed to size a chunk; neither can be guessed.
###############################################################################
set -uo pipefail

# --------------------------------------------------------------------------- #
# Presentation
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
    c_b=$'\033[1m'; c_d=$'\033[2m'; c_r=$'\033[31m'; c_g=$'\033[32m'
    c_y=$'\033[33m'; c_c=$'\033[36m'; c_0=$'\033[0m'
else
    c_b=""; c_d=""; c_r=""; c_g=""; c_y=""; c_c=""; c_0=""
fi
hdr(){  printf '\n%s== %s ==%s\n' "$c_b$c_c" "$1" "$c_0"; }
say(){  printf '%s==>%s %s\n' "$c_b" "$c_0" "$*"; }
ok(){   printf '  %s[ OK ]%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '  %s[WARN]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die(){  printf '  %s[FAIL]%s %s\n' "$c_r" "$c_0" "$1" >&2; exit "${2:-1}"; }
note(){ printf '  %s%s%s\n' "$c_d" "$*" "$c_0"; }
kv(){   printf '  %-28s %s\n' "$1" "$2"; }

usage(){ sed -n '2,33p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; }

# --------------------------------------------------------------------------- #
# Mode: one implementation, two commands. The rendered job passes --mode
# explicitly because it invokes the real path, where the symlink name is gone.
# --------------------------------------------------------------------------- #
MODE=""
case "$(basename "$0")" in
    *scf*)   MODE="scf"   ;;
    *relax*) MODE="relax" ;;
esac

ACTION="start"
for a in "$@"; do
    case "$a" in
        -h|--help) usage; exit 0 ;;
    esac
done
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        MODE="${2:?}"; shift 2 ;;
        --chunk-body)  ACTION="chunk"; shift ;;
        --status)      ACTION="status"; shift ;;
        --stop)        ACTION="stop"; shift ;;
        --resume)      ACTION="resume"; shift ;;
        --now)         STOP_NOW=1; shift ;;
        --walltime)    OPT_WALLTIME="${2:?}"; shift 2 ;;
        --max-chunks)  OPT_MAXCHUNKS="${2:?}"; shift 2 ;;
        --force)       OPT_FORCE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1  (try --help)" 2 ;;
    esac
done
STOP_NOW="${STOP_NOW:-0}"; OPT_FORCE="${OPT_FORCE:-0}"
[[ -n $MODE ]] || die "cannot tell which mode to run: invoke as vasp-scf-loop or vasp-relax-loop" 2
[[ $MODE == scf || $MODE == relax ]] || die "unknown mode: $MODE" 2

# VASP's own graceful stop, and which loop each flavour leaves.
#   LSTOP  finishes the CURRENT IONIC STEP and exits -- the relaxation keeps a
#          consistent CONTCAR, so the chain resumes from a real geometry.
#   LABORT leaves the ELECTRONIC loop and still writes the WAVECAR, which is
#          what a static run needs. LSTOP would be meaningless there: a static
#          run has no ionic loop to stop at the end of.
stop_tag(){ [[ $MODE == relax ]] && printf 'LSTOP' || printf 'LABORT'; }

# --------------------------------------------------------------------------- #
# Cluster profile.  Required, not optional: these describe THIS cluster and a
# built-in guess would size a job for someone else's hardware.
# --------------------------------------------------------------------------- #
_wp_conf="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
# shellcheck source=/dev/null
[[ -f "$_wp_conf" ]] && source "$_wp_conf"

_wp_require(){
    local missing=() v
    for v in "$@"; do [[ -z "${!v:-}" ]] && missing+=("$v"); done
    (( ${#missing[@]} == 0 )) && return 0
    {
        echo
        echo "=============================================================================="
        echo " CANNOT RUN -- this cluster has not been configured"
        echo "=============================================================================="
        echo " These values describe YOUR cluster and cannot be guessed:"
        for v in "${missing[@]}"; do echo "     ${v}"; done
        echo
        echo " Create or update the profile (a handful of questions, once per cluster):"
        echo "     vasp-configure"
        echo "=============================================================================="
        echo
    } >&2
    exit 2
}

# --------------------------------------------------------------------------- #
# Chain layout.  VISIBLE, and deliberately NOT under .wolfpack/: vasp-clean
# removes that directory by default, which would strand a live chain.
# --------------------------------------------------------------------------- #
CHDIR="wolfpack_chain"
CH_ENV="$CHDIR/chain.env"
CH_LOG="$CHDIR/chain.log"
CH_JOB="$CHDIR/slurm_chunk.sh"
CH_RUN="$CHDIR/RUNNING"
CH_STOP="$CHDIR/STOP"
CH_DONE="$CHDIR/FINISHED"
CH_DEAD="$CHDIR/STOPPED"

# Defaults; every one overridable from the profile or the command line.
DEF_WALLTIME_MIN=600          # 10 h -- short enough to backfill on most sites
DEF_MARGIN_MIN=5
DEF_MAX_CHUNKS=50
DEF_MAX_WALL_MIN=2880         # 48 h of accumulated compute
DEF_DEADLINE_DAYS=7
NELM_FLOOR=8                  # a chunk holding fewer steps than this is pointless
NELM_CEIL=500
SAFETY=1.15                   # per-step time is a prediction; leave room
SIGNAL_LEAD=120               # seconds of warning before the walltime kill

# --------------------------------------------------------------------------- #
# State: sourceable key="value", merged and replaced ATOMICALLY.  Appending
# would leave hundreds of duplicate keys over a long chain, and a chunk dying
# mid-write must never leave a file that cannot be sourced.
# --------------------------------------------------------------------------- #
state_load(){ [[ -f "$CH_ENV" ]] && { set -a; # shellcheck source=/dev/null
    source "$CH_ENV"; set +a; }; return 0; }

state_set(){   # state_set key value [key value ...]
    local tmp="$CH_ENV.new" k v
    mkdir -p "$CHDIR"
    : > "$tmp"
    {
        echo "# WolfPack-DFT chunked-run state -- written by $(basename "$0")"
        while [[ $# -gt 1 ]]; do
            k="$1"; v="$2"; shift 2
            printf '%s="%s"\n' "$k" "$v"
            printf -v "$k" '%s' "$v"
        done
    } >> "$tmp"
    # carry forward every key we were not just given
    if [[ -f "$CH_ENV" ]]; then
        while IFS='=' read -r k v; do
            [[ $k == \#* || -z $k ]] && continue
            grep -qE "^${k}=" "$tmp" || printf '%s=%s\n' "$k" "$v" >> "$tmp"
        done < "$CH_ENV"
    fi
    mv -f "$tmp" "$CH_ENV"
}

log_line(){    # append-only; this is what the user reads after waking up
    mkdir -p "$CHDIR"
    [[ -f "$CH_LOG" ]] || printf '# %-4s %-10s %-6s %5s %5s %9s %8s %5s %-10s %s\n' \
        idx jobid kind cap used t_step elapsed frac verdict detail > "$CH_LOG"
    printf '  %-4s %-10s %-6s %5s %5s %9s %8s %5s %-10s %s\n' "$@" >> "$CH_LOG"
}

# --------------------------------------------------------------------------- #
# INCAR: replace the WHOLE LINE, never append a duplicate.
#
# Whether VASP honours the first or the last occurrence of a repeated tag is
# version-dependent, and a chain rewrites the same tags once per chunk, so
# appending would make the result depend on the VASP build. Whole-line
# replacement is correct under either rule.
#
# The anchored pattern is also what keeps NELM from eating NELMIN/NELMDL and
# EDIFF from eating EDIFFG: after the tag only whitespace may precede the '=',
# and a leading '#' is not whitespace, so commented lines are left alone.
# --------------------------------------------------------------------------- #
incar_set(){
    local k="$1" v="$2" c="${3:-}" line
    line="$k = $v"; [[ -n $c ]] && line="$line   # $c"
    [[ -f INCAR.chain.bak ]] || cp -f INCAR INCAR.chain.bak 2>/dev/null
    if grep -qiE "^[[:space:]]*${k}[[:space:]]*=" INCAR; then
        sed -i -E "s|^([[:space:]]*)${k}[[:space:]]*=.*|\\1${line}|I" INCAR
    else
        printf '%s\n' "$line" >> INCAR
    fi
}
incar_get(){
    grep -m1 -oiE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*[^ #!]+" INCAR 2>/dev/null \
      | sed -E 's/.*=[[:space:]]*//'
}
# What VASP ACTUALLY used, from its own echo. Closes the loop on a failed sed or
# a value VASP silently overrode.
outcar_tag(){ grep -m1 -aoE "$1[[:space:]]*=[[:space:]]*-?[0-9]+" "${2:-OUTCAR}" 2>/dev/null \
      | grep -oE -- '-?[0-9]+$'; }

int(){ local v="${1//[^0-9-]/}"; echo "${v:-0}"; }
fnum(){ local v="$1"; [[ $v =~ ^-?[0-9]*\.?[0-9]+([eEdD][-+]?[0-9]+)?$ ]] && echo "$v" || echo 0; }

# --------------------------------------------------------------------------- #
# Is this CONTCAR safe to become the next POSCAR?
#
# A killed job can leave it empty, truncated mid-line, or half-written with a
# plausible header and no coordinates. Writing that over POSCAR ends the run and
# loses the geometry, so it is checked BEFORE anything is overwritten.
#
# Deliberately pure awk/bash. The rendered job loads only VASP's modules, so a
# python import here would be a latent failure inside a compute job at 3am, at
# the exact moment the chain is trying to recover.
# --------------------------------------------------------------------------- #
contcar_ok(){   # contcar_ok <contcar> <reference-poscar>  -> prints a reason on failure
    local c="$1" ref="$2" nat_ref nat_c lines want
    [[ -s "$c" ]] || { echo "empty or missing"; return 1; }
    nat_ref=$(awk 'NR==7{s=0; for(i=1;i<=NF;i++) s+=$i+0; print s; exit}' "$ref" 2>/dev/null)
    nat_c=$(awk 'NR==7{s=0; for(i=1;i<=NF;i++) s+=$i+0; print s; exit}' "$c" 2>/dev/null)
    [[ ${nat_c:-0} -gt 0 ]] || { echo "no species-count line"; return 1; }
    if [[ ${nat_ref:-0} -gt 0 && ${nat_c} -ne ${nat_ref} ]]; then
        echo "atom count changed: ${nat_ref} -> ${nat_c}"; return 1
    fi
    # 8 header lines + the coordinates (+1 when Selective dynamics is present)
    want=$(( 8 + nat_c ))
    awk 'NR==8 && tolower(substr($1,1,1))=="s"{exit 0} NR==8{exit 1}' "$c" && want=$(( want + 1 ))
    lines=$(grep -c '' "$c")
    (( lines >= want )) || { echo "truncated: ${lines} lines, expected at least ${want}"; return 1; }
    # three lattice rows of three numbers, and a non-degenerate cell
    awk 'NR>=3 && NR<=5 { if (NF<3) exit 1
             for(i=1;i<=3;i++) if ($i !~ /^-?[0-9]*\.?[0-9]+([eEdD][-+]?[0-9]+)?$/) exit 1
             a[NR-2,1]=$1; a[NR-2,2]=$2; a[NR-2,3]=$3 }
         END{ d = a[1,1]*(a[2,2]*a[3,3]-a[2,3]*a[3,2]) \
                - a[1,2]*(a[2,1]*a[3,3]-a[2,3]*a[3,1]) \
                + a[1,3]*(a[2,1]*a[3,2]-a[2,2]*a[3,1])
              if (d<0) d=-d
              exit (d > 1e-8 ? 0 : 1) }' "$c" || { echo "lattice unreadable or degenerate"; return 1; }
    # The last coordinate row must parse.
    #
    # NB: no `exit 0` in the main block. In awk, exit jumps to END, and an exit
    # THERE overrides the status -- so `NR==w{...exit 0} END{exit 1}` always
    # reports failure, including on a perfectly good file. Carry a flag instead.
    awk -v w="$want" '
        NR==w { seen=1; good=(NF>=3)
                for(i=1;i<=3 && good;i++)
                    if ($i !~ /^-?[0-9]*\.?[0-9]+([eEdD][-+]?[0-9]+)?$/) good=0 }
        END{ exit (seen && good ? 0 : 1) }' "$c" \
        || { echo "last coordinate row unreadable"; return 1; }
    return 0
}

# Cell volume, for the sanity check on how far one chunk moved.
cell_volume(){
    awk 'NR==2{s=$1+0} NR>=3&&NR<=5{a[NR-2,1]=$1;a[NR-2,2]=$2;a[NR-2,3]=$3}
         END{ d = a[1,1]*(a[2,2]*a[3,3]-a[2,3]*a[3,2]) \
                - a[1,2]*(a[2,1]*a[3,3]-a[2,3]*a[3,1]) \
                + a[1,3]*(a[2,1]*a[3,2]-a[2,2]*a[3,1])
              if (d<0) d=-d; printf "%.6f", d*s*s*s }' "$1" 2>/dev/null
}

# --------------------------------------------------------------------------- #
# Control verbs
# --------------------------------------------------------------------------- #
if [[ $ACTION == status ]]; then
    [[ -f "$CH_ENV" ]] || die "no chain here ($CH_ENV not found)." 3
    state_load
    hdr "Chunked run -- ${chain_kind:-?}"
    kv "state"           "${chain_state:-?}${stop_reason:+  (${stop_reason})}"
    kv "chunks done"     "${chunk_index:-0} of max ${max_chunks:-?}"
    if [[ "${chain_kind:-}" == relax ]]; then
        kv "per-ionic-step time" "${t_ionic_s:-?} s"
        kv "last cap"        "${last_nsw_cap:-?} ionic steps"
        kv "ionic steps"     "${nsw_done:-0} of ${nsw_target:-?}"
        [[ -n "${last_fmax:-}" ]] && kv "last max|F|" "${last_fmax} eV/A"
    else
        kv "per-step time"   "${t_elec_s:-?} s"
        kv "last cap"        "${last_nelm_cap:-?} electronic steps"
        kv "electronic steps" "${nelm_total:-0} of ${nelm_target:-?}"
    fi
    kv "compute used"    "$(awk -v s="${wall_used_s:-0}" 'BEGIN{printf "%.1f h", s/3600}')"
    kv "core-hours"      "${corehours:-0}"
    [[ -f "$CH_LOG" ]] && { echo; note "per-chunk history ($CH_LOG):"; cat "$CH_LOG"; }
    exit 0
fi

if [[ $ACTION == stop ]]; then
    [[ -f "$CH_ENV" ]] || die "no chain here ($CH_ENV not found)." 3
    mkdir -p "$CHDIR"
    printf 'stopped by %s at %s\n' "${USER:-?}" "$(date -Iseconds)" > "$CH_STOP"
    say "STOP requested."
    note "The running chunk will finish normally, archive its output, and NOT submit a"
    note "successor. Nothing is lost. Continue later with: $(basename "$0") --resume"
    if (( STOP_NOW )); then
        # VASP's own graceful stop. LABORT leaves the electronic loop and still
        # writes the WAVECAR, so the chain stays resumable -- unlike scancel.
        printf '%s = .TRUE.\n' "$(stop_tag)" > STOPCAR
        if [[ $MODE == relax ]]; then
            say "STOPCAR written (LSTOP): VASP will finish the current ionic step and exit,"
            note "leaving a consistent CONTCAR to resume from."
        else
            say "STOPCAR written (LABORT): VASP will leave the electronic loop at the next"
            note "opportunity and still write its WAVECAR."
        fi
    fi
    exit 0
fi

# --------------------------------------------------------------------------- #
# Shared bootstrap for start / resume / chunk
# --------------------------------------------------------------------------- #
_wp_require WP_MAIN_PARTITION WP_MAIN_CPUS_PER_NODE WP_MAIN_MEM_PER_NODE_MB WP_VASP_STD

[[ -s INCAR ]] || die "no INCAR here -- run this in a VASP calculation folder." 2

SRC_SLURM="slurm_vasptest.sh"
sb_num(){ [[ -f "$SRC_SLURM" ]] && grep -m1 -oiE -- "--$1=[0-9]+" "$SRC_SLURM" | grep -oE '[0-9]+'; }
sb_str(){ [[ -f "$SRC_SLURM" ]] && grep -m1 -oiE -- "--$1=[^[:space:]]+" "$SRC_SLURM" | sed -E 's/.*=//'; }

# --------------------------------------------------------------------------- #
# THE CHUNK BODY -- runs inside the SLURM job
# --------------------------------------------------------------------------- #
if [[ $ACTION == chunk ]]; then
    state_load
    chunk_start=$(date +%s)
    idx=$(( $(int "${chunk_index:-0}") + 1 ))
    SELF="${chain_self:-$(readlink -f "$0")}"

    say "chunk ${idx} -- job ${SLURM_JOB_ID:-?}"

    # A leftover STOPCAR would end every future chunk after a single step.
    if [[ -f STOPCAR ]]; then
        note "removing a leftover STOPCAR from a previous chunk"
        rm -f STOPCAR
    fi

    # Archive the PREVIOUS chunk's job logs out of the calculation directory.
    # They must live here while current, because vasp-diagnose looks for *.out
    # in the calculation folder and would otherwise find no evidence at all.
    prev=$(printf '%03d' $(( idx - 1 )))
    if (( idx > 1 )) && [[ -d "$CHDIR/chunk-$prev" ]]; then
        for f in VASP-chain-*.out VASP-chain-*.err; do
            [[ -e $f ]] || continue
            case "$f" in *"${SLURM_JOB_ID:-@}"*) continue ;; esac
            mv -f "$f" "$CHDIR/chunk-$prev/" 2>/dev/null
        done
    fi

    # ---- cap for THIS chunk -------------------------------------------------
    cap=$(int "${next_cap:-0}")
    recovery=0; [[ "${next_is_recovery:-0}" == 1 ]] && recovery=1

    if [[ $MODE == scf ]]; then
        (( cap < NELM_FLOOR )) && cap=$NELM_FLOOR
        incar_set NELM   "$cap"                "chunk ${idx} cap (vasp-scf-loop)"
        nelmin=$(int "$(incar_get NELMIN)"); (( nelmin < 1 )) && nelmin=2
        (( nelmin > cap )) && nelmin=$cap
        incar_set NELMIN "$nelmin"             "must not exceed the chunk cap"
        incar_set NSW    "0"                   "static: the SCF chain never moves ions"
        incar_set IBRION "-1"                  "static"
    else
        (( cap < 1 )) && cap=1
        # NELM is NEVER chunked in a relaxation. A truncated electronic loop
        # yields forces that are simply wrong, and the optimiser then takes a
        # step based on them -- so the chain only ever cuts BETWEEN ionic steps.
        incar_set NSW  "$cap"                  "chunk ${idx} cap (vasp-relax-loop)"
        incar_set NELM "$(int "${nelm_target:-60}")" \
                       "full: a truncated SCF would give wrong forces"
        if (( recovery )); then
            say "recovery chunk: one ionic step with the full electronic budget"
            note "the previous chunk's last ionic step ran out of NELM, so its forces"
            note "were unreliable; this converges the electrons at that geometry first."
        fi
    fi

    incar_set LWAVE  ".TRUE."                  "the restart object between chunks"
    incar_set LCHARG ".TRUE."
    if (( idx > 1 )); then
        incar_set ISTART "1"                   "continue from the previous chunk's WAVECAR"
        incar_set ICHARG "0"                   "charge from the wavefunction"
        # A negative NELMDL delays the charge update at a COLD start. On a restart
        # it would burn that many non-self-consistent steps out of every chunk.
        incar_set NELMDL "0"                   "restart: no delay (would waste the cap)"
        [[ -n "${nbands:-}" ]] && incar_set NBANDS "$nbands" "pinned from chunk 1"
    fi

    # ---- the walltime safety net -------------------------------------------
    # A walltime SIGKILL cannot be trapped: it would kill this script exactly
    # where the successor is submitted, leaving the chain dead with no message
    # and the chunk's work lost (VASP writes the WAVECAR at the end). SLURM can
    # send a catchable signal first; STOPCAR is VASP's own clean stop, so the
    # chunk ends a little short and the normal decision logic still runs.
    _hit_walltime=0
    _on_warning(){ _hit_walltime=1; printf '%s = .TRUE.\n' "$(stop_tag)" > STOPCAR; }
    trap _on_warning USR1

    # ---- run ----------------------------------------------------------------
    run_start=$(date +%s)
    # Backgrounded on purpose: bash only runs a trap between commands, so a
    # foreground VASP would swallow the warning signal until it had already been
    # killed. `wait` is interruptible, which is what lets the trap fire in time.
    /usr/bin/time -v srun --cpu-bind=cores "${chain_exe:-vasp_std}" &
    _vpid=$!
    wait "$_vpid"; rc=$?
    # A trapped signal makes `wait` return 128+signum, NOT the child's status.
    # Taking that as VASP's exit code would report a chunk the safety net just
    # rescued as a failure -- the exact opposite of what happened. Keep waiting
    # for the real exit.
    while kill -0 "$_vpid" 2>/dev/null; do
        wait "$_vpid"; rc=$?
    done
    run_end=$(date +%s)
    elapsed=$(( run_end - run_start ))
    rm -f STOPCAR

    # ---- measure ------------------------------------------------------------
    nelm_eff=$(int "$(outcar_tag NELM)"); (( nelm_eff < 1 )) && nelm_eff=$cap
    footer=0; grep -qa 'General timing and accounting' OUTCAR 2>/dev/null && footer=1
    ediff_hit=0; grep -qa 'aborting loop because EDIFF is reached' OUTCAR 2>/dev/null && ediff_hit=1
    steps=$(grep -c 'LOOP:' OUTCAR 2>/dev/null); steps=$(int "$steps")
    t_step=$(awk '/LOOP:/{k=split($0,a,"real time"); if(k>1){s+=a[2]+0;c++}}
                  END{ if(c>0) printf "%.2f", s/c; else printf "0" }' OUTCAR)
    sum_loop=$(awk '/LOOP:/{k=split($0,a,"real time"); if(k>1) s+=a[2]+0} END{printf "%.2f", s+0}' OUTCAR)
    startup=$(awk -v w="$elapsed" -v s="$sum_loop" 'BEGIN{r=w-s; if(r<0)r=0; printf "%.1f", r}')
    de=$(awk '/^(DAV|RMM|EDDAV|CG|DIIS):/{d=$4} END{printf "%s", (d==""?"":d)}' OSZICAR 2>/dev/null)
    frac=$(awk -v e="$elapsed" -v b="${t_vasp_budget_s:-1}" 'BEGIN{printf "%.2f", (b>0? e/b : 0)}')

    # ---- relax-only measurements -------------------------------------------
    ionic=0; t_ionic=0; fmax=""; nelm_hits=0; nelm_hit_last=0; relax_done=0; nsw_eff=0
    if [[ $MODE == relax ]]; then
        nsw_eff=$(int "$(outcar_tag NSW)"); (( nsw_eff < 1 )) && nsw_eff=$cap
        # 'LOOP+:' is the IONIC step. It is a different literal from 'LOOP:', so
        # the two greps cannot overlap and neither needs to exclude the other.
        ionic=$(grep -c 'LOOP+:' OUTCAR 2>/dev/null); ionic=$(int "$ionic")
        # Cross-check against OSZICAR; on disagreement take the SMALLER, which is
        # a partially written final step.
        _fcount=$(grep -c 'F=' OSZICAR 2>/dev/null); _fcount=$(int "$_fcount")
        (( _fcount > 0 && _fcount < ionic )) && ionic=$_fcount
        relax_done=0
        grep -qaiE 'reached required accuracy - stopping structural energy minimi[sz]ation' \
            OUTCAR 2>/dev/null && relax_done=1

        # Cost of an ionic step: the MAX of (mean excluding the first) and (the
        # last). Two deliberate choices. The first ionic step of a cold chain
        # costs several times the steady state and would shrink every later
        # chunk if averaged in. And for IBRION=1/2 the cost RISES through a
        # relaxation -- forces shrink, the SCF needs more steps, line searches
        # appear -- so a plain mean under-sizes and walks into the walltime.
        t_ionic=$(awk -v first="${chunk_index:-0}" '
            /LOOP\+:/{ k=split($0,a,"real time"); if(k>1){ n++; v[n]=a[2]+0 } }
            END{ if(n==0){ print 0; exit }
                 s=0; c=0; start=(first==0 && n>1 ? 2 : 1)
                 for(i=start;i<=n;i++){ s+=v[i]; c++ }
                 m=(c>0? s/c : v[n]); last=v[n]
                 printf "%.1f", (last>m? last : m) }' OUTCAR)

        # Ionic steps whose ELECTRONIC loop ran out of NELM: their forces are not
        # trustworthy. Lifted from vasp-check's OSZICAR counter.
        read -r nelm_hits nelm_hit_last < <(awk -v nelm="$(int "${nelm_target:-0}")" '
            /^[[:space:]]*[A-Za-z]+:[[:space:]]+[0-9]+[[:space:]]/ { ec++; next }
            /F=/ { last=(nelm>0 && ec>=nelm); if(last) hits++; ec=0 }
            END{ printf "%d %d", hits+0, last+0 }' OSZICAR 2>/dev/null)
        nelm_hits=$(int "$nelm_hits"); nelm_hit_last=$(int "$nelm_hit_last")

        # max|F| of the final force block, the numeric convergence test.
        fmax=$(awk '/TOTAL-FORCE/{inb=1;st=0;cmax=0;next}
                    inb&&/^[[:space:]]*-+[[:space:]]*$/{if(!st){st=1;next}else{fm=cmax;inb=0;st=0;next}}
                    inb&&st{m=sqrt($4*$4+$5*$5+$6*$6); if(m>cmax)cmax=m}
                    END{ if(fm!="") printf "%.4f", fm }' OUTCAR 2>/dev/null)
    fi

    # ---- decide -------------------------------------------------------------
    # verdict starts at STOP. CONTINUE is reached only by an explicit positive
    # test, which is what makes "never resubmit into a failure" structural.
    verdict="STOP"; reason=""; detail=""

    # Shared branches first: these end a chain whatever it is computing.
    if [[ -f "$CH_STOP" ]]; then
        reason="user"; detail="stop requested"
    elif (( rc != 0 )) || (( footer == 0 )); then
        reason="failed"; detail="rc=${rc} footer=${footer}"
    elif grep -qaE 'NaN|\*\*\*\*\*' OSZICAR 2>/dev/null; then
        reason="numerical"; detail="NaN or overflow in OSZICAR"
    elif [[ ! -s WAVECAR ]] || [[ $(stat -c %Y WAVECAR 2>/dev/null || echo 0) -lt $chunk_start ]]; then
        # Without a fresh WAVECAR every later chunk restarts cold and the chain
        # can never converge -- this is the rail that prevents an endless run.
        reason="no_restart_object"; detail="WAVECAR missing, empty or not rewritten"
    elif [[ $MODE == scf ]]; then
        if (( ediff_hit )); then
            verdict="CONVERGED"; detail="EDIFF reached in ${steps} steps"
        elif (( steps < nelm_eff )) && (( ! _hit_walltime )); then
            reason="stopped_early"
            detail="${steps} of ${nelm_eff} steps, no EDIFF marker and no cap reached"
        else
            verdict="CONTINUE"; detail="${steps}/${nelm_eff} steps"
        fi
    else
        # --- relax ----------------------------------------------------------
        # Symmetry can change as atoms move, which changes NKPTS and makes the
        # stored WAVECAR unreadable. VASP would then regenerate it silently and
        # the restart is lost with no error anywhere.
        _nk=$(int "$(outcar_tag NKPTS)")
        if (( idx == 1 )) && (( _nk > 0 )); then
            state_set nkpts "$_nk"
        elif (( _nk > 0 )) && [[ -n "${nkpts:-}" ]] && (( _nk != $(int "$nkpts") )); then
            reason="symmetry_drift"
            detail="NKPTS changed ${nkpts} -> ${_nk}: the stored WAVECAR no longer matches"
        fi

        if [[ -z $reason ]]; then
            _fok=0
            if [[ -n "$fmax" ]] && awk -v g="${chain_ediffg:-0}" 'BEGIN{exit !(g<0)}'; then
                awk -v f="$fmax" -v g="${chain_ediffg:-0}" \
                    'BEGIN{ t=(g<0?-g:g); exit !(f<=t) }' && _fok=1
            fi
            if (( relax_done )); then
                verdict="CONVERGED"; detail="reached required accuracy after ${ionic} ionic step(s)"
            elif (( _fok )) && (( ! nelm_hit_last )); then
                # Belt to the marker's braces: max|F| is already under |EDIFFG|
                # and the last step's electrons did converge, so the forces that
                # say so can be trusted.
                verdict="CONVERGED"; detail="max|F|=${fmax} within |EDIFFG|"
            elif (( ionic == 0 )); then
                reason="no_ionic_progress"
                detail="not one ionic step fitted in ${elapsed}s; raise --walltime"
            elif (( nelm_hit_last )); then
                # The LAST step's forces are unreliable and VASP has already moved
                # the ions with them. The pre-move geometry exists only inside
                # XDATCAR, so it cannot simply be redone -- and rebuilding a POSCAR
                # from a possibly-truncated trajectory is a worse risk than the
                # single imperfect step. Instead, take the geometry and spend the
                # next chunk converging the electrons AT it.
                if (( recovery )) || (( $(int "${nelm_hit_streak:-0}") >= 1 )); then
                    reason="electronic_nonconvergence"
                    detail="the electronic loop keeps exhausting NELM=${nelm_target}; more ionic steps cannot fix that"
                else
                    verdict="CONTINUE"
                    detail="${ionic}/${nsw_eff} ionic, last step hit NELM -> recovery chunk next"
                fi
            elif awk -v h="$nelm_hits" -v n="$ionic" 'BEGIN{exit !(n>0 && h > 0.5*n)}'; then
                reason="electronic_nonconvergence"
                detail="${nelm_hits} of ${ionic} ionic steps exhausted NELM"
            elif (( ionic < nsw_eff )) && (( ! _hit_walltime )); then
                reason="stopped_early"
                detail="${ionic} of ${nsw_eff} ionic steps, no accuracy marker and no cap reached"
            else
                verdict="CONTINUE"; detail="${ionic}/${nsw_eff} ionic steps, max|F|=${fmax:-?}"
            fi
        fi
    fi

    # --- no longer making progress -------------------------------------------
    if [[ $verdict == CONTINUE && $MODE == scf && -n "$de" && -n "${last_de:-}" ]]; then
        if awk -v a="$de" -v b="${last_de}" -v e="${chain_ediff:-1e-6}" \
              'BEGIN{ A=(a<0?-a:a); B=(b<0?-b:b); exit !(A >= 0.98*B && A > 100*e) }'; then
            streak=$(( $(int "${stall_streak:-0}") + 1 ))
            if (( streak >= 2 )); then
                verdict="STOP"; reason="stalled"
                detail="|dE| flat for ${streak} chunks at ${de} eV"
            fi
            state_set stall_streak "$streak"
        else
            state_set stall_streak 0
        fi
    elif [[ $verdict == CONTINUE && $MODE == relax && -n "$fmax" && -n "${last_fmax:-}" ]]; then
        # A force plateau is usually NOT the optimiser's fault: it is the noise
        # floor of the forces themselves (real-space projectors, ADDGRID, a loose
        # EDIFF). Saying so saves the user from raising NSW forever.
        if awk -v a="$fmax" -v b="${last_fmax}" -v g="${chain_ediffg:-0}" \
              'BEGIN{ t=(g<0?-g:g); exit !(a >= 0.98*b && (t<=0 || a > t)) }'; then
            streak=$(( $(int "${stall_streak:-0}") + 1 ))
            if (( streak >= 3 )); then
                verdict="STOP"; reason="force_plateau"
                detail="max|F| stuck near ${fmax} eV/A for ${streak} chunks"
            fi
            state_set stall_streak "$streak"
        else
            state_set stall_streak 0
        fi
    fi

    # ---- archive ------------------------------------------------------------
    cdir="$CHDIR/chunk-$(printf '%03d' "$idx")"
    mkdir -p "$cdir"
    _arch=(OUTCAR OSZICAR vasprun.xml)
    [[ $MODE == relax ]] && _arch+=(CONTCAR XDATCAR POSCAR)
    for f in "${_arch[@]}"; do
        [[ -s $f ]] || continue
        # POSCAR is archived under the name that says what it was: the geometry
        # this chunk STARTED from, which is about to be overwritten.
        [[ $f == POSCAR ]] && { cp -f POSCAR "$cdir/POSCAR.in"; gzip -f "$cdir/POSCAR.in" 2>/dev/null; continue; }
        cp -f "$f" "$cdir/"; gzip -f "$cdir/$f" 2>/dev/null
    done
    # One continuous trajectory: the per-chunk XDATCARs are otherwise the only
    # record, and people plot the whole relaxation.
    if [[ $MODE == relax && -s XDATCAR ]]; then
        if [[ -f "$CHDIR/XDATCAR.all" ]]; then tail -n +8 XDATCAR >> "$CHDIR/XDATCAR.all"
        else cp -f XDATCAR "$CHDIR/XDATCAR.all"; fi
    fi

    wall_used=$(( $(int "${wall_used_s:-0}") + elapsed ))
    ranks=$(int "${chain_ranks:-1}")
    ch=$(awk -v r="$ranks" -v e="$wall_used" 'BEGIN{printf "%.1f", r*e/3600}')
    state_set chunk_index "$idx" nelm_total "$(( $(int "${nelm_total:-0}") + steps ))" \
              wall_used_s "$wall_used" corehours "$ch" t_elec_s "$t_step" \
              t_startup_s "$startup" last_nelm_cap "$cap" last_de "${de:-}" \
              last_elapsed_s "$elapsed"
    if [[ $MODE == relax ]]; then
        state_set nsw_done "$(( $(int "${nsw_done:-0}") + ionic ))" \
                  last_fmax "${fmax:-}" t_ionic_s "${t_ionic:-0}" \
                  nelm_hit_streak "$(( nelm_hit_last ? $(int "${nelm_hit_streak:-0}") + 1 : 0 ))" \
                  next_is_recovery 0
    fi
    (( idx == 1 )) && [[ -z "${nbands:-}" ]] && \
        state_set nbands "$(int "$(outcar_tag NBANDS)")"

    # ---- finalise the verdict BEFORE logging --------------------------------
    # The budget rails below can turn a CONTINUE into a STOP, so the log line has
    # to come after them: chain.log is what the user reads to find out why the
    # chain ended, and a line claiming CONTINUE on the chunk that stopped it
    # would send them looking in the wrong place.
    newcap=""; _floor=$NELM_FLOOR; next_recovery=0
    if [[ $verdict == CONTINUE ]]; then
        budget=$(int "${t_work_s:-0}")
        if [[ $MODE == scf ]]; then
            # The cap is limited by what is LEFT of the user's own NELM: a chain
            # stands in for one job with that NELM, so the whole chain may spend
            # at most that many steps. Otherwise chunking would quietly redefine
            # the step budget, and a run the user expected to abandon after 200
            # steps would grind on for thousands.
            done_steps=$(int "${nelm_total:-0}")
            target=$(int "${nelm_target:-0}")
            remain=$NELM_CEIL
            (( target > 0 )) && remain=$(( target - done_steps ))
            newcap=$(awk -v b="$budget" -v t="$t_step" -v s="$SAFETY" -v c="$NELM_CEIL" \
                         -v f="$NELM_FLOOR" -v r="$remain" \
                     'BEGIN{ if(t<=0){print f; exit} n=int(b/(t*s));
                             if(n>c)n=c; if(r>0 && n>r)n=r; if(n<f)n=f; print n }')
        else
            _floor=1
            done_steps=$(int "${nsw_done:-0}")
            target=$(int "${nsw_target:-0}")
            remain=$NELM_CEIL
            (( target > 0 )) && remain=$(( target - done_steps ))
            if (( nelm_hit_last )); then
                # The next chunk converges the electrons at the geometry VASP has
                # already moved to, before any further ionic steps are taken.
                newcap=1; next_recovery=1
            else
                # Governor: one anomalously fast chunk must not produce a cap that
                # then runs into the walltime.
                #
                # Compare against THIS chunk's cap, not the stored one. The stored
                # value is still the previous chunk's at this point, so using it
                # lags by one and lets the first resize grow unchecked -- a
                # 3-step calibration chunk jumped straight to 26, which is the
                # exact jump the governor exists to prevent.
                _prev=$cap
                newcap=$(awk -v b="$budget" -v t="$t_ionic" -v s="$SAFETY" -v c="$NELM_CEIL" \
                             -v r="$remain" -v p="$_prev" \
                         'BEGIN{ if(t<=0){print 1; exit} n=int(b/(t*s))
                                 if(p>0 && n>2*p) n=2*p
                                 if(n>c)n=c; if(r>0 && n>r)n=r; if(n<1)n=1; print n }')
                # Below 3 ionic steps per chunk the optimiser restart cost (a CG
                # line search or an accumulated Hessian thrown away every
                # boundary) starts to dominate the work actually done.
                (( newcap < 3 && remain >= 3 )) && \
                    warn "only ${newcap} ionic step(s) fit per chunk: the optimiser restarts more often than it advances. Consider a longer --walltime."
            fi
            state_set last_nsw_cap "$cap"
        fi
        if (( _hit_walltime )); then
            newcap=$(awk -v n="$newcap" -v f="$_floor" 'BEGIN{v=int(n*0.7); print (v<f?f:v)}')
            tight=$(( $(int "${tight_streak:-0}") + 1 ))
            state_set tight_streak "$tight"
            if (( tight >= 2 )); then
                verdict="STOP"; reason="budget_drift"
                detail="two chunks in a row ran into the walltime; the timing model is wrong"
            fi
        else
            state_set tight_streak 0
        fi
    fi
    if [[ $verdict == CONTINUE ]]; then
        if (( idx >= $(int "${max_chunks:-$DEF_MAX_CHUNKS}") )); then
            verdict="STOP"; reason="budget"; detail="reached max_chunks=${max_chunks}"
        elif (( wall_used > $(int "${max_wall_min:-$DEF_MAX_WALL_MIN}") * 60 )); then
            verdict="STOP"; reason="budget"; detail="accumulated compute exceeded the limit"
        elif (( $(date +%s) > $(int "${deadline_epoch:-0}") )); then
            verdict="STOP"; reason="budget"; detail="past the wall-clock deadline"
        elif [[ $MODE == scf ]] && (( steps == 0 )); then
            verdict="STOP"; reason="no_progress"; detail="the chunk produced no electronic step"
        elif (( target > 0 && remain <= 0 )); then
            # The same outcome a single job with this cap would have had.
            verdict="STOP"
            if [[ $MODE == scf ]]; then
                reason="nelm_budget"
                detail="spent all ${target} electronic steps of NELM without converging"
            else
                reason="nsw_budget"
                detail="spent all ${target} ionic steps of NSW without reaching EDIFFG"
            fi
        fi
    fi

    # ---- advance the geometry (relax only) ----------------------------------
    # Ordering matters and is deliberate: the chunk is already archived, so this
    # runs AFTER the record is safe and BEFORE the successor is submitted. A
    # death before the sbatch leaves a folder that resumes; after it, a folder
    # with a successor already running. There is no moment where both are true.
    #
    # A static run never touches POSCAR, and its CONTCAR is 0 bytes by design.
    if [[ $MODE == relax ]] && [[ $verdict == CONTINUE || $verdict == CONVERGED ]]; then
        if _why=$(contcar_ok CONTCAR POSCAR); then
            _v0=$(cell_volume POSCAR); _v1=$(cell_volume CONTCAR)
            if awk -v a="${_v0:-0}" -v b="${_v1:-0}" \
                  'BEGIN{ exit !(a>0 && b>0 && (b > 1.5*a || b < 0.5*a)) }'; then
                # A structure that blew up should end the chain, not propagate.
                verdict="STOP"; reason="bad_geometry"
                detail="cell volume changed ${_v0} -> ${_v1} A^3 in one chunk"
                cp -f CONTCAR CONTCAR.rejected
            else
                # Atomic rename: a cp interrupted half-way would leave a corrupt
                # POSCAR and a dead folder.
                cp -f CONTCAR POSCAR.new && mv -f POSCAR.new POSCAR
            fi
        else
            # Never fall back to the old POSCAR and resubmit: that would redo
            # identical work for ever.
            verdict="STOP"; reason="bad_contcar"
            detail="CONTCAR unusable (${_why}); kept as CONTCAR.rejected"
            cp -f CONTCAR CONTCAR.rejected 2>/dev/null
        fi
    fi

    _sig=""; (( _hit_walltime )) && _sig=" [signalled]"
    if [[ $MODE == relax ]]; then
        log_line "$idx" "${SLURM_JOB_ID:-?}" "RELAX" "$cap" "$ionic" "${t_ionic:-0}" \
                 "$elapsed" "$frac" "$verdict" "${detail}${_sig}"
    else
        log_line "$idx" "${SLURM_JOB_ID:-?}" "SCF" "$cap" "$steps" "$t_step" "$elapsed" \
                 "$frac" "$verdict" "${detail}${_sig}"
    fi

    # ---- act ----------------------------------------------------------------
    if [[ $verdict == CONVERGED ]]; then
        state_set chain_state converged stop_reason ""
        {
            echo "converged at chunk ${idx} on $(date -Iseconds)"
            if [[ $MODE == relax ]]; then
                echo "ionic steps total      : $(int "${nsw_done:-0}")"
                echo "final max|F| (eV/A)    : ${fmax:-?}"
            fi
            echo "electronic steps total : $(int "${nelm_total:-0}")"
            echo "compute used           : $(awk -v s="$wall_used" 'BEGIN{printf "%.1f h", s/3600}')"
            echo "core-hours             : ${ch}"
        } > "$CH_DONE"
        rm -f "$CH_RUN"
        # One report block, never one per chunk.
        {
            printf '\n%.0s#' {1..78}; echo
            echo "#  CHUNKED ${MODE^^} -- converged"
            echo "#  $(date '+%Y-%m-%d %H:%M:%S')"
            printf '%.0s#' {1..78}; echo; echo
            cat "$CH_DONE"; echo
            cat "$CH_LOG"
        } >> report.out 2>/dev/null
        say "CONVERGED after ${idx} chunk(s)."
        if [[ $MODE == relax ]] && (( $(int "${chain_isif:-2}") >= 3 )); then
            note "ISIF>=3: the plane-wave basis was rebuilt at every chunk boundary, so"
            note "follow this with a fresh static run at the final geometry before"
            note "quoting energies. vasp-check's structure-equilibrium section audits it."
        fi
        # The physics verdict, so it is waiting when the user wakes up.
        command -v vasp-check >/dev/null 2>&1 && { echo; vasp-check 2>&1 | tail -40; }
        # One 'finished' mail from the last chunk only.
        scontrol update "JobId=${SLURM_JOB_ID:-0}" MailType=END,FAIL >/dev/null 2>&1
        exit 0
    fi

    if [[ $verdict == CONTINUE ]]; then
        state_set next_cap "$newcap" chain_state running next_is_recovery "$next_recovery"
        say "not converged yet (${steps}/${nelm_eff} steps); submitting chunk $((idx+1)) with cap ${newcap}"
        if out=$(sbatch "$CH_JOB" 2>&1); then
            jid="${out##* }"
            echo "$jid" > "$CH_RUN"
            state_set jobids "${jobids:-} ${jid}"
            say "submitted: $out"
            exit 0
        fi
        # Never retry in-job: that is how a chain becomes 4000 queued jobs.
        # Logged separately, because the line above already recorded CONTINUE.
        verdict="STOP"; reason="sbatch_failed"; detail="$out"
        log_line "$idx" "${SLURM_JOB_ID:-?}" "SCF" "$cap" "$steps" "$t_step" "$elapsed" \
                 "$frac" "STOP" "sbatch failed: ${out}"
    fi

    # ---- stop ---------------------------------------------------------------
    state_set chain_state stopped stop_reason "$reason"
    rm -f "$CH_RUN"
    {
        echo "stopped at chunk ${idx} on $(date -Iseconds)"
        echo "reason  : ${reason}"
        echo "detail  : ${detail}"
        echo
        echo "Resume with:   $(basename "$SELF" .sh | sed 's/vasp_chain/vasp-scf-loop/') --resume"
        echo "Diagnose with: vasp-diagnose"
    } > "$CH_DEAD"
    warn "chain stopped: ${reason} -- ${detail}"
    note "see $CH_DEAD"
    if [[ $reason == failed ]]; then
        command -v vasp-diagnose >/dev/null 2>&1 && \
            WP_DIAG_ASSUME_ENDED=1 vasp-diagnose 2>&1 | tail -25 | tee -a "$CH_DEAD"
    fi
    exit 1
fi

# --------------------------------------------------------------------------- #
# LAUNCHER (login node): validate, size chunk 1, render the job, submit
# --------------------------------------------------------------------------- #
if [[ -n "${SLURM_JOB_ID:-}" ]]; then
    die "this is the launcher; inside a job it must be called with --chunk-body." 2
fi

hdr "Chunked $([[ $MODE == relax ]] && echo relaxation || echo SCF) -- setup"

# ---- prerequisites --------------------------------------------------------
[[ -f "$SRC_SLURM" ]] || die "no ${SRC_SLURM} here. Run the pipeline first:
     vasp-dry-run  ->  vasp-recommend-slurm  ->  vasp-test
   ${SRC_SLURM} carries the MEASURED memory and geometry; it cannot be guessed." 3

if [[ $ACTION != resume ]] && [[ -f "$CH_ENV" ]]; then
    state_load
    if [[ "${chain_state:-}" == running ]]; then
        jid=$(tr -dc '0-9' < "$CH_RUN" 2>/dev/null)
        if [[ -n $jid ]] && [[ -n "$(squeue -h -j "$jid" 2>/dev/null)" ]]; then
            die "a chain is already running here (job ${jid}). Use --status, or --stop first." 3
        fi
    fi
fi
rm -f "$CH_STOP"

# An ABSENT tag is not a zero. VASP's IBRION defaults to -1 when NSW=0, so a
# static INCAR normally omits it entirely -- reading that as IBRION=0 would
# reject every plain SCF as molecular dynamics.
ibrion_raw=$(incar_get IBRION)
_nsw_src="INCAR"; [[ -f INCAR.chain.bak ]] && _nsw_src="INCAR.chain.bak"
nsw=$(int "$(grep -m1 -oiE "^[[:space:]]*NSW[[:space:]]*=[[:space:]]*[0-9]+" "$_nsw_src" 2>/dev/null | grep -oE '[0-9]+')")

if [[ -n $ibrion_raw ]] && (( $(int "$ibrion_raw") == 0 )); then
    die "IBRION=0 is molecular dynamics. Velocities and thermostat state are not in
   any file this chain carries between jobs, so chunking it would silently give
   wrong physics." 2
fi

if [[ $MODE == scf ]]; then
    (( nsw > 1 )) && die "this INCAR has NSW=${nsw}: it is a relaxation, not a static SCF.
   Use vasp-relax-loop for that." 2
else
    (( nsw > 1 )) || die "this INCAR has NSW=${nsw}: there is no relaxation to chunk.
   Use vasp-scf-loop for a static run." 2
    _ib=$(int "${ibrion_raw:-2}")
    (( _ib == 3 )) && warn "IBRION=3 is damped dynamics: it carries velocity state that a chunk
     boundary discards, so the trajectory will differ from an unchunked run."

    # ISIF>=3 relaxes the CELL, and the plane-wave basis is rebuilt for the new
    # cell at every chunk boundary. With ENCUT close to the POTCAR's ENMAX that
    # rebuild shifts the energy (Pulay), and a chain crosses that boundary many
    # times rather than once. The usual 1.3x rule stops being advice here.
    _isif=$(int "$(incar_get ISIF)")
    if (( _isif >= 3 )); then
        _encut=$(fnum "$(incar_get ENCUT)")
        # A POTCAR writes this as "ENMAX  = 295.446; ENMIN  = 221.584 eV", so the
        # tag, the '=' and the number are separate fields -- and a concatenated
        # POTCAR repeats the line once per species, hence the max.
        _enmax=$(awk '/ENMAX/ { line=$0
                         sub(/.*ENMAX[^0-9.+-]*/, "", line)
                         v=line+0; if(v>m) m=v }
                      END{ printf "%.1f", m+0 }' POTCAR 2>/dev/null)
        if awk -v e="$_encut" -v m="$_enmax" 'BEGIN{exit !(m>0 && e>0 && e < 1.3*m)}'; then
            if (( ! OPT_FORCE )); then
                die "ISIF=${_isif} relaxes the cell, but ENCUT=${_encut} eV is only \
$(awk -v e="$_encut" -v m="$_enmax" 'BEGIN{printf "%.2f", e/m}')x the POTCAR's ENMAX=${_enmax} eV.
   A chunked cell relaxation rebuilds the plane-wave basis at every boundary, so
   the Pulay error this causes is paid many times over. Raise ENCUT to at least
   $(awk -v m="$_enmax" 'BEGIN{printf "%.0f", 1.3*m}') eV, or pass --force if you know what you are doing." 2
            fi
            warn "ENCUT is below 1.3 x ENMAX for a cell relaxation (--force given)."
        fi
    fi
fi

# ---- measured inputs ------------------------------------------------------
# shellcheck source=/dev/null
[[ -f .wolfpack/state.env ]] && source .wolfpack/state.env
t_e="${test_avg_loop:-0}"
awk -v t="$t_e" 'BEGIN{exit !(t>0)}' || die "no measured per-step time in .wolfpack/state.env.
   Re-run vasp-test here: the chunk size is derived from it and cannot be guessed." 3

RANKS=$(sb_num ntasks);        RANKS=$(int "${RANKS:-0}")
NODES=$(sb_num nodes);         NODES=$(int "${NODES:-1}")
NTPN=$(sb_num ntasks-per-node);NTPN=$(int "${NTPN:-$RANKS}")
MEMCPU=$(sb_num mem-per-cpu);  MEMCPU=$(int "${MEMCPU:-0}")
PART=$(sb_str partition);      PART="${PART:-${WP_MAIN_PARTITION}}"
EXE=$(grep -m1 -E '^/usr/bin/time -v srun ' "$SRC_SLURM" 2>/dev/null | awk '{print $NF}')
EXE="${EXE:-${exe:-${WP_VASP_STD}}}"
(( RANKS > 0 ))  || die "${SRC_SLURM} has no --ntasks." 3
(( MEMCPU > 0 )) || die "${SRC_SLURM} has no --mem-per-cpu." 3

# ---- budget ---------------------------------------------------------------
WALL=$(int "${OPT_WALLTIME:-${WP_CHUNK_WALLTIME_MIN:-$DEF_WALLTIME_MIN}}")
MARGIN=$(int "${WP_CHUNK_MARGIN_MIN:-$DEF_MARGIN_MIN}")
m2=$(awk -v w="$WALL" 'BEGIN{printf "%d", w*0.08}'); (( m2 > MARGIN )) && MARGIN=$m2
STARTUP=$(int "${test_startup_s:-120}")
T_VASP=$(( WALL*60 - MARGIN*60 ))
T_WORK=$(( T_VASP - STARTUP ))
(( T_WORK < 60 )) && die "the walltime budget leaves no room to compute (${WALL} min minus
   ${MARGIN} min margin minus ${STARTUP}s start-up). Raise --walltime." 2

# The user's ORIGINAL NELM, which is the whole chain's step budget.
#
# It must come from INCAR.chain.bak when that exists: the chain rewrites NELM in
# the live INCAR once per chunk, so on a second run the live file holds the last
# chunk's cap, and reading it here would silently redefine the budget as whatever
# the previous chain happened to stop at.
_nelm_src="INCAR"
[[ -f INCAR.chain.bak ]] && _nelm_src="INCAR.chain.bak"
NELM_ORIG=$(int "$(grep -m1 -oiE "^[[:space:]]*NELM[[:space:]]*=[[:space:]]*[0-9]+" "$_nelm_src" 2>/dev/null | grep -oE '[0-9]+')")
(( NELM_ORIG < 1 )) && NELM_ORIG=$NELM_CEIL
# The benchmark ran on the debug partition, at a different rank count, with
# LWAVE/LCHARG off -- so its rate is a starting estimate, not a measurement of
# this job. Chunk 1 is deliberately conservative and recalibrates from reality.
CAL=$(awk -v t="$t_e" -v tr="${test_ranks:-0}" -v pr="$RANKS" -v eff="${test_cpu_eff:-100}" \
      'BEGIN{ r=(tr>0&&pr>0? tr/pr : 1); e=eff/100; if(e<0.3)e=0.3; if(e>1)e=1;
              printf "%.3f", t*r/e }')
if [[ $MODE == scf ]]; then
    CAP1=$(awk -v b="$T_WORK" -v t="$CAL" -v s="$SAFETY" -v c="$NELM_CEIL" -v f="$NELM_FLOOR" \
           -v o="$NELM_ORIG" 'BEGIN{ if(t<=0){print f; exit}
                 n=int(b/(t*s*1.5)); if(n>c)n=c; if(n>o)n=o; if(n<f)n=f; print n }')
    (( CAP1 < NELM_FLOOR )) && die "one chunk cannot hold ${NELM_FLOOR} SCF steps at
   ${CAL}s per step within ${WALL} min. Raise --walltime or the rank count." 2
    CAP_UNIT="electronic steps"
else
    # An IONIC step costs several electronic ones, and the benchmark rarely
    # completed even one -- so chunk 1 estimates, and only chunk 1. From chunk 2
    # the cost is read straight off VASP's own LOOP+ lines, one per ionic step.
    #
    # NELMIN is the floor, not a detail: VASP performs at least that many
    # electronic steps per ionic step however good the restart is.
    SPI=$(fnum "${test_scf_per_ionic:-0}")
    _nelmin=$(int "$(incar_get NELMIN)"); (( _nelmin < 2 )) && _nelmin=2
    SPI=$(awk -v s="$SPI" -v nm="$_nelmin" 'BEGIN{
              if(s<=0) s=12;                  # no measurement: a common mid-range
              if(s<nm) s=nm; if(s>25) s=25;   # clamp: the estimate is weak either way
              printf "%.1f", s }')
    # +15% for the force/stress evaluation and the CONTCAR/XDATCAR writes.
    T_ION=$(awk -v t="$CAL" -v s="$SPI" 'BEGIN{printf "%.1f", t*s*1.15}')
    # Chunk 1 is a CALIBRATION chunk: deliberately tiny, because it also absorbs
    # the cold start, where the first ionic step costs several times the steady
    # state and would otherwise poison the estimate for everything after it.
    CAP1=$(awk -v b="$T_WORK" -v t="$T_ION" -v r="$nsw" 'BEGIN{
               if(t<=0){print 1; exit} n=int(b/(t*1.5)); if(n>3)n=3; if(n>r)n=r
               if(n<1)n=1; print n }')
    (( CAP1 < 1 )) && die "one chunk cannot hold a single ionic step at ~${T_ION}s each
   within ${WALL} min. Raise --walltime or the rank count." 2
    CAP_UNIT="ionic steps"
fi

kv "VASP executable"    "$EXE"
kv "geometry"           "${NODES} node(s) x ${NTPN} ranks, ${MEMCPU} MB/cpu on '${PART}'"
kv "measured rate"      "${t_e} s/step (benchmark) -> ${CAL} s/step (scaled estimate)"
kv "chunk walltime"     "${WALL} min  (margin ${MARGIN} min, start-up ${STARTUP}s)"
if [[ $MODE == relax ]]; then
    kv "estimated ionic step" "~${T_ION} s  (${SPI} electronic steps each)"
    kv "first chunk cap"    "${CAP1} ionic steps  (calibration; later chunks measure)"
    kv "target NSW"         "$nsw"
    kv "NELM per ionic step" "${NELM_ORIG}  (never chunked: a truncated SCF gives wrong forces)"
else
    kv "first chunk cap"    "${CAP1} electronic steps  (calibration; later chunks resize)"
    kv "original NELM"      "$NELM_ORIG"
fi

# ---- is chunking even worth it? -------------------------------------------
# Short jobs backfill better than long ones only if they are also SMALL. Saying
# so up front is better than letting the user discover it after a week.
if command -v sacct >/dev/null 2>&1; then
    medwait=$(sacct -X -a -r "$PART" -S "$(date -d '7 days ago' +%F)" \
                -o Submit,Start -n -P 2>/dev/null \
              | awk -F'|' '$1!="" && $2!="" && $2!="Unknown"{
                    cmd="date -d \""$1"\" +%s"; cmd|getline s; close(cmd)
                    cmd="date -d \""$2"\" +%s"; cmd|getline t; close(cmd)
                    if(t>=s) print t-s }' | sort -n | awk '{a[NR]=$1} END{if(NR)print a[int(NR/2)+1]}')
    if [[ -n ${medwait:-} ]] && (( medwait > 0 )); then
        est=$(awk -v n="$(( (NELM_ORIG + CAP1 - 1) / CAP1 ))" -v w="$medwait" -v j="$((WALL*60))" \
              'BEGIN{printf "%.1f", n*(w+j)/3600}')
        kv "median queue wait" "$(awk -v w="$medwait" 'BEGIN{printf "%.1f h", w/3600}') on '${PART}' (last 7 days)"
        kv "rough turnaround"  "~${est} h across $(( (NELM_ORIG + CAP1 - 1) / CAP1 )) chunk(s)"
        if (( NTPN * NODES > WP_MAIN_CPUS_PER_NODE )); then
            warn "this job spans more than one node. Short jobs backfill well only when they"
            warn "are also small; at this size chunking may not shorten the queue wait, and"
            warn "you pay the start-up and WAVECAR I/O once per chunk. Consider one long job."
        fi
    fi
fi

# ---- render the job ONCE --------------------------------------------------
# Rendered once and reused verbatim by every chunk, which freezes the allocation
# at setup: editing slurm_vasptest.sh later cannot change a running chain.
mkdir -p "$CHDIR"
SELF=$(readlink -f "$0")
tt=$(printf '%02d:%02d:00' $((WALL/60)) $((WALL%60)))
{
    echo "#!/bin/bash"
    echo "#SBATCH --job-name=vasp-chain-${MODE}"
    echo "#SBATCH --partition=${PART}"
    echo "#SBATCH --nodes=${NODES}"
    echo "#SBATCH --ntasks=${RANKS}"
    echo "#SBATCH --ntasks-per-node=${NTPN}"
    echo "#SBATCH --cpus-per-task=1"
    echo "#SBATCH --mem-per-cpu=${MEMCPU}"
    echo "#SBATCH --time=${tt}"
    echo "#SBATCH --output=VASP-chain-%j.out"
    echo "#SBATCH --error=VASP-chain-%j.err"
    # A requeued job would re-run this script from the top in a directory the
    # first attempt already half-modified.
    echo "#SBATCH --no-requeue"
    # Catchable warning before the uncatchable walltime kill.
    echo "#SBATCH --signal=B:USR1@${SIGNAL_LEAD}"
    # One mail per chain, not per chunk: the last chunk re-enables END itself.
    [[ -n "${WP_EMAIL:-}" ]] && { echo "#SBATCH --mail-user=${WP_EMAIL}"; echo "#SBATCH --mail-type=FAIL"; }
    echo ""
    echo "# Generated by vasp-scf-loop on $(date -Iseconds). Re-used by every chunk."
    echo 'cd "$SLURM_SUBMIT_DIR" || exit 1'
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        [[ "${WP_MODULE_PURGE:-1}" == "1" ]] && echo "${WP_MODULE_CMD:-ml} purge"
        echo "${WP_MODULE_CMD:-ml} ${WP_VASP_MODULES}"
    fi
    echo "export OMP_NUM_THREADS=1"
    echo "export MKL_NUM_THREADS=1"
    [[ -n "${WP_EXTRA_ENV:-}" ]] && echo "${WP_EXTRA_ENV}"
    echo ""
    # --mode explicitly: the job invokes the real file path, where the symlink
    # name the user typed -- and with it the mode -- is no longer visible.
    echo "exec '${SELF}' --mode ${MODE} --chunk-body"
} > "$CH_JOB"
chmod +x "$CH_JOB"

# ---- state ----------------------------------------------------------------
if [[ $ACTION == resume ]] && [[ -f "$CH_ENV" ]]; then
    state_load
    say "resuming at chunk $(( $(int "${chunk_index:-0}") + 1 ))"
    state_set chain_state running stop_reason ""
else
    rm -f "$CH_DONE" "$CH_DEAD"
    state_set chain_kind "$MODE" chain_state running chain_started "$(date -Iseconds)" \
              chain_self "$SELF" chain_exe "$EXE" chain_ranks "$RANKS" \
              chain_ediff "$(incar_get EDIFF)" nelm_target "$NELM_ORIG" \
              nsw_target "$nsw" chain_ediffg "$(incar_get EDIFFG)" \
              chain_isif "$(int "$(incar_get ISIF)")" \
              t_ionic_s "${T_ION:-0}" nsw_done 0 nelm_hit_streak 0 recovery_used 0 \
              chunk_index 0 nelm_total 0 wall_used_s 0 corehours 0 \
              next_cap "$CAP1" t_elec_s "$CAL" t_startup_s "$STARTUP" \
              t_work_s "$T_WORK" t_vasp_budget_s "$T_VASP" \
              max_chunks "$(int "${OPT_MAXCHUNKS:-${WP_CHAIN_MAX_CHUNKS:-$DEF_MAX_CHUNKS}}")" \
              max_wall_min "$DEF_MAX_WALL_MIN" \
              deadline_epoch "$(date -d "+${DEF_DEADLINE_DAYS} days" +%s)" \
              stall_streak 0 tight_streak 0
fi

# ---- go -------------------------------------------------------------------
if out=$(sbatch "$CH_JOB" 2>&1); then
    jid="${out##* }"
    echo "$jid" > "$CH_RUN"
    state_set jobids "${jobids:-} ${jid}"
    echo
    ok "chain started: $out"
    note "It will keep submitting chunks until it converges."
    note "  watch:  $(basename "$0") --status"
    note "  stop :  $(basename "$0") --stop        (finishes the current chunk first)"
else
    die "sbatch failed: $out"
fi
