#!/usr/bin/env bash
###############################################################################
# vasp_chain.sh   (on PATH as: vasp-scf-loop)
#
# Converge a static VASP SCF as a CHAIN of short jobs instead of one long one.
#
# WHY
#   Many schedulers make a long walltime wait a long time. A job that asks for
#   10 hours can sit in the queue for days while a 1-hour job backfills into a
#   gap immediately. This runs the same SCF as a sequence of short jobs: each
#   one caps its electronic steps (NELM) to fit the walltime, restarts from the
#   previous one's wavefunction, and submits its own successor before exiting.
#   You launch it once and it keeps going until the SCF converges.
#
#   A relaxation is vasp-relax-loop (vasp_relax_loop.sh), a different design.
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
#   ... --status                # where is it
#   ... --stop                  # finish the current chunk, then stop cleanly
#   ... --resume                # continue a stopped OR DEAD chain -- after an
#                               # OOM kill it raises the memory by itself
#   ... --fresh                 # archive an unfinished chain and start over
#   ... --walltime MIN          # the chunk walltime (else WP_CHUNK_WALLTIME_MIN)
#
# THE CHUNK WALLTIME is chosen once, at launch, and then fixed for the whole
# chain: from --walltime if given, else from WP_CHUNK_WALLTIME_MIN.
#
# THE ONLY LIMIT is your own NELM: the whole chain spends at most that many
# electronic steps.
#
# MEMORY is measured after every chunk (sacct, or VASP's own OUTCAR footer)
# and the next chunk's --mem-per-cpu is rewritten from it. When the ranks no
# longer fit a node, they are spread over more nodes; the rank count, and so
# KPAR/NCORE, never changes under a running chain.
#
# REQUIREMENTS
#   vasp-test must have run here: its slurm_vasptest.sh carries the MEASURED
#   memory and geometry, and .wolfpack/state.env the measured per-step rate.
#   Both are needed to size a chunk; neither can be guessed.
###############################################################################
set -uo pipefail

# What vasp-scf-loop and vasp-relax-loop share: presentation, state, the
# CONTCAR check, the memory helpers.
_wp_chainlib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wolfpack_chain_lib.sh"
# shellcheck source=/dev/null
if [[ -r "$_wp_chainlib" ]]; then source "$_wp_chainlib"; else
    echo "ERROR: wolfpack_chain_lib.sh not found next to $(readlink -f "${BASH_SOURCE[0]}")" >&2
    exit 1
fi

# The whole header, up to its closing rule: a fixed line range silently cut
# the options off as the header grew.
usage(){ awk 'NR == 1 { next } /^#####/ { if (++n == 2) exit; next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# vasp-scf-loop only. vasp-relax-loop is vasp_relax_loop.sh.
MODE="scf"

ACTION="start"
for a in "$@"; do
    case "$a" in
        -h|--help) usage; exit 0 ;;
    esac
done
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        [[ ${2:-} == scf ]] || die "vasp_chain.sh is vasp-scf-loop only; a relaxation is vasp-relax-loop." 2
                       shift 2 ;;
        --chunk-body)  ACTION="chunk"; shift ;;
        --status)      ACTION="status"; shift ;;
        --stop)        ACTION="stop"; shift ;;
        --resume)      ACTION="resume"; shift ;;
        --fresh)       OPT_FRESH=1; shift ;;
        --now)         STOP_NOW=1; shift ;;
        --walltime)    OPT_WALLTIME="${2:?}"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1  (try --help)" 2 ;;
    esac
done
STOP_NOW="${STOP_NOW:-0}"; OPT_FRESH="${OPT_FRESH:-0}"
CMD="vasp-scf-loop"

# VASP's own graceful stop: LABORT leaves the ELECTRONIC loop and still writes
# the WAVECAR, which is what the next chunk restarts from.
stop_tag(){ printf 'LABORT'; }

# --------------------------------------------------------------------------- #
# Cluster profile.  Required, not optional: these describe THIS cluster and a
# built-in guess would size a job for someone else's hardware.
# --------------------------------------------------------------------------- #
# The INCAR layout library sits next to this script; readlink follows the
# ~/.local/bin symlink back to the toolkit. Pure awk, no python -- see the note
# on contcar_ok() for why that matters inside a compute job.
_wp_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wolfpack_incar.sh"
# shellcheck source=/dev/null
if [[ -r "$_wp_lib" ]]; then source "$_wp_lib"; else
    echo "ERROR: wolfpack_incar.sh not found next to $(readlink -f "${BASH_SOURCE[0]}")" >&2
    exit 1
fi

_wp_conf="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
# shellcheck source=/dev/null
[[ -f "$_wp_conf" ]] && source "$_wp_conf"

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
NELM_FLOOR=8                  # a chunk holding fewer steps than this is pointless
NELM_CEIL=500
SAFETY=1.15                   # per-step time is a prediction; leave room
SIGNAL_LEAD=120               # seconds of warning before the walltime kill
# Memory. MEM_SAFETY is headroom over what the previous chunk MEASURED; it is not
# a guess at a requirement, which is measured. OOM_FACTOR is how far the request
# is raised after an OOM kill -- a retry policy, like a back-off, because a kill
# says only that the need was ABOVE the grant, never by how much.
MEM_SAFETY="${WP_CHAIN_MEM_SAFETY:-1.25}"
OOM_FACTOR="${WP_CHAIN_OOM_FACTOR:-1.5}"
MEM_FLOOR_MB=256
SACCT_POLL_S=45               # accounting lags a finished step by a few seconds

log_line(){    # append-only; this is what the user reads after waking up
    # peakMB is the heaviest rank this chunk measured; reqMB the --mem-per-cpu it
    # RAN with. Side by side, because the gap between them is how close the chunk
    # came to being killed.
    mkdir -p "$CHDIR"
    [[ -f "$CH_LOG" ]] || printf '# %-4s %-10s %-6s %5s %5s %9s %8s %5s %7s %6s %-10s %s\n' \
        idx jobid kind cap used t_step elapsed frac peakMB reqMB verdict detail > "$CH_LOG"
    printf '  %-4s %-10s %-6s %5s %5s %9s %8s %5s %7s %6s %-10s %s\n' "$@" >> "$CH_LOG"
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
# Thin wrappers over wolfpack_incar.sh, which also puts a tag the INCAR did not
# already carry under the right section header instead of at the bottom.
incar_set(){
    [[ -f INCAR.chain.bak ]] || cp -f INCAR INCAR.chain.bak 2>/dev/null
    wp_incar_set INCAR "$1" "$2" "${3:-}"
}
incar_get(){ wp_incar_get INCAR "$1"; }
# What VASP ACTUALLY used, from its own echo. Closes the loop on a failed sed or
# a value VASP silently overrode.
outcar_tag(){ grep -m1 -aoE "$1[[:space:]]*=[[:space:]]*-?[0-9]+" "${2:-OUTCAR}" 2>/dev/null \
      | grep -oE -- '-?[0-9]+$'; }

# --------------------------------------------------------------------------- #
# Control verbs
# --------------------------------------------------------------------------- #
if [[ $ACTION == status ]]; then
    [[ -f "$CH_ENV" ]] || die "no chain here ($CH_ENV not found)." 3
    state_load
    hdr "Chunked run -- ${chain_kind:-?}"
    kv "state"           "${chain_state:-?}${stop_reason:+  (${stop_reason})}"
    kv "chunks done"     "${chunk_index:-0}"
    kv "per-step time"   "${t_elec_s:-?} s"
    kv "last cap"        "${last_nelm_cap:-?} electronic steps"
    kv "electronic steps" "${nelm_total:-0} of ${nelm_target:-?}"
    kv "chunk walltime"  "${chain_wall_min:-?} min, fixed  (${chain_wall_source:-?})"
    kv "allocation now"  "${chain_nodes:-?} node(s) x ${chain_ntpn:-?} ranks, ${chain_mem_per_cpu:-?} MB/cpu"
    kv "memory measured" "last ${last_mem_peak_mb:-?} MB/rank (${last_mem_src:-?}), largest ${mem_peak_max_mb:-?}"
    (( $(int "${oom_count:-0}") > 0 )) && kv "OOM kills survived" "${oom_count} (last job ${last_oom_jid:-?})"
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
    note "successor. Nothing is lost. Continue later with: ${CMD} --resume"
    if (( STOP_NOW )); then
        # VASP's own graceful stop. LABORT leaves the electronic loop and still
        # writes the WAVECAR, so the chain stays resumable -- unlike scancel.
        printf '%s = .TRUE.\n' "$(stop_tag)" > STOPCAR
        say "STOPCAR written (LABORT): VASP will leave the electronic loop at the next"
        note "opportunity and still write its WAVECAR."
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

    (( cap < NELM_FLOOR )) && cap=$NELM_FLOOR
    incar_set NELM   "$cap"                "chunk ${idx} cap (vasp-scf-loop)"
    nelmin=$(int "$(incar_get NELMIN)"); (( nelmin < 1 )) && nelmin=2
    (( nelmin > cap )) && nelmin=$cap
    incar_set NELMIN "$nelmin"             "must not exceed the chunk cap"
    incar_set NSW    "0"                   "static: the SCF chain never moves ions"
    incar_set IBRION "-1"                  "static"

    incar_set LWAVE  ".TRUE."                  "the restart object between chunks"
    incar_set LCHARG ".TRUE."
    if [[ ${next_cold_start:-0} == 1 ]]; then
        # --resume set the dead chunk's WAVECAR aside because it could not be
        # verified complete. One cold start costs a few electronic steps; reading
        # a truncated WAVECAR costs the chunk.
        incar_set ISTART "0"                   "cold start: the last WAVECAR was not trustworthy"
        incar_set ICHARG "2"                   "cold start: atomic charge densities"
        # The chain pinned NELMDL=0 for warm restarts. A cold start wants the delay
        # back: the user's own value if the backup has one, else VASP's default for
        # ISTART=0, which is -5.
        _nd=$(grep -m1 -oiE "^[[:space:]]*NELMDL[[:space:]]*=[[:space:]]*-?[0-9]+" INCAR.chain.bak 2>/dev/null \
              | grep -oE -- '-?[0-9]+$')
        incar_set NELMDL "${_nd:--5}"         "cold start: delay the charge update again"
        [[ -n "${nbands:-}" ]] && incar_set NBANDS "$nbands" "pinned from chunk 1"
        say "cold start for this chunk (the previous WAVECAR was set aside by --resume)"
    elif (( idx > 1 )); then
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

    # ---- memory: what this chunk actually used --------------------------------
    # sacct first: its MaxRSS is the HEAVIEST task of the step and its AveRSS the
    # mean, which is what the node-total rule needs. VASP's own footer is the
    # fallback -- rank 0 only, but rank 0 is normally the heaviest. The poll is
    # short when the walltime warning already fired: what is left of the job
    # belongs to the archive and the successor, not to waiting on a database.
    _poll=$SACCT_POLL_S; (( _hit_walltime )) && _poll=5
    read -r mem_state mem_max mem_ave < <(job_mem_evidence "${SLURM_JOB_ID:-}" "$_poll")
    mem_max=$(int "${mem_max:-0}"); mem_ave=$(int "${mem_ave:-0}"); mem_src="sacct"
    if (( mem_max <= 0 )); then
        mem_max=$(int "$(outcar_maxmem_mb OUTCAR)"); mem_ave=0; mem_src="OUTCAR (rank 0)"
        (( mem_max <= 0 )) && mem_src="not measured"
    fi
    mem_granted=$(int "${SLURM_MEM_PER_CPU:-${chain_mem_per_cpu:-0}}")

    # ---- decide -------------------------------------------------------------
    # verdict starts at STOP. CONTINUE is reached only by an explicit positive
    # test, which is what makes "never resubmit into a failure" structural.
    verdict="STOP"; reason=""; detail=""

    # Shared branches first: these end a chain whatever it is computing.
    if [[ -f "$CH_STOP" ]]; then
        reason="user"; detail="stop requested"
    elif (( rc != 0 )) || (( footer == 0 )); then
        # An OOM kill is the one failure --resume can fix by itself, so it is told
        # apart from the rest: by sacct's state, or by slurmstepd's own words in
        # this job's stderr.
        if [[ ${mem_state:-} == OUT_OF_MEMORY ]] || err_mentions "${SLURM_JOB_ID:-x}" "$OOM_RX"; then
            reason="oom"
            detail="killed for memory at ${mem_granted} MB/cpu$( (( mem_max > 0 )) && echo ", peak ${mem_max} MB/rank measured")"
        else
            reason="failed"; detail="rc=${rc} footer=${footer}"
        fi
    elif grep -qaE 'NaN|\*\*\*\*\*' OSZICAR 2>/dev/null; then
        reason="numerical"; detail="NaN or overflow in OSZICAR"
    elif [[ ! -s WAVECAR ]] || [[ $(stat -c %Y WAVECAR 2>/dev/null || echo 0) -lt $chunk_start ]]; then
        # Without a fresh WAVECAR every later chunk restarts cold and the chain
        # can never converge -- this is the rail that prevents an endless run.
        reason="no_restart_object"; detail="WAVECAR missing, empty or not rewritten"
    elif (( ediff_hit )); then
        verdict="CONVERGED"; detail="EDIFF reached in ${steps} steps"
    elif (( steps < nelm_eff )) && (( ! _hit_walltime )); then
        reason="stopped_early"
        detail="${steps} of ${nelm_eff} steps, no EDIFF marker and no cap reached"
    else
        verdict="CONTINUE"; detail="${steps}/${nelm_eff} steps"
    fi

    # --- no longer making progress -------------------------------------------
    if [[ $verdict == CONTINUE && -n "$de" && -n "${last_de:-}" ]]; then
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
    fi

    # ---- archive ------------------------------------------------------------
    cdir="$CHDIR/chunk-$(printf '%03d' "$idx")"
    mkdir -p "$cdir"
    for f in OUTCAR OSZICAR vasprun.xml; do
        [[ -s $f ]] || continue
        cp -f "$f" "$cdir/"; gzip -f "$cdir/$f" 2>/dev/null
    done

    wall_used=$(( $(int "${wall_used_s:-0}") + elapsed ))
    ranks=$(int "${chain_ranks:-1}")
    ch=$(awk -v r="$ranks" -v e="$wall_used" 'BEGIN{printf "%.1f", r*e/3600}')
    state_set chunk_index "$idx" nelm_total "$(( $(int "${nelm_total:-0}") + steps ))" \
              wall_used_s "$wall_used" corehours "$ch" t_elec_s "$t_step" \
              t_startup_s "$startup" last_nelm_cap "$cap" last_de "${de:-}" \
              last_elapsed_s "$elapsed" next_cold_start 0
    # A complete WAVECAR's size, for --resume: a later chunk that dies while
    # writing leaves one of a different size, and that is how it is recognised.
    if [[ -s WAVECAR ]] && (( $(stat -c %Y WAVECAR 2>/dev/null || echo 0) >= chunk_start )) \
       && (( rc == 0 )) && (( footer == 1 )); then
        state_set wavecar_bytes "$(stat -c %s WAVECAR 2>/dev/null || echo 0)"
    fi
    (( idx == 1 )) && [[ -z "${nbands:-}" ]] && \
        state_set nbands "$(int "$(outcar_tag NBANDS)")"

    # ---- finalise the verdict BEFORE logging --------------------------------
    # The budget rails below can turn a CONTINUE into a STOP, so the log line has
    # to come after them: chain.log is what the user reads to find out why the
    # chain ended, and a line claiming CONTINUE on the chunk that stopped it
    # would send them looking in the wrong place.
    newcap=""; _floor=$NELM_FLOOR
    if [[ $verdict == CONTINUE ]]; then
        budget=$(int "${t_work_s:-0}")
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
        if [[ $verdict == CONTINUE ]] && (( _hit_walltime )); then
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
        # The ONLY budget is the user's own NELM: no cap on chunks, accumulated
        # compute or calendar days.
        if (( steps == 0 )); then
            verdict="STOP"; reason="no_progress"; detail="the chunk produced no electronic step"
        elif (( target > 0 && remain <= 0 )); then
            # The same outcome a single job with this cap would have had.
            verdict="STOP"; reason="nelm_budget"
            detail="spent all ${target} electronic steps of NELM without converging"
        fi
    fi

    # ---- memory for the NEXT chunk --------------------------------------------
    # Measured, not assumed. The largest peak ever seen is never forgotten, so
    # one quiet chunk cannot talk the request down below what an earlier one
    # needed.
    mem_next="$(int "${chain_mem_per_cpu:-$mem_granted}")"
    if (( mem_max > 0 )); then
        _pk=$(( mem_max > $(int "${mem_peak_max_mb:-0}") ? mem_max : $(int "${mem_peak_max_mb:-0}") ))
        _av=$(( mem_ave > $(int "${mem_ave_max_mb:-0}") ? mem_ave : $(int "${mem_ave_max_mb:-0}") ))
        state_set mem_peak_max_mb "$_pk" mem_ave_max_mb "$_av" \
                  last_mem_peak_mb "$mem_max" last_mem_src "$mem_src"
        if [[ $verdict == CONTINUE ]]; then
            _vr=1
            _R=$(int "${chain_ranks:-1}")
            if ! settle_memory "$_pk" "$_av" "$_R" "$(int "${chain_ntpn:-1}")" "$_vr" 0; then
                verdict="STOP"; reason="memory_does_not_fit"
                detail="the next chunk needs ${SM_NEED} MB/cpu: ${SM_WHY}"
            else
                _need=$SM_NEED; _ln=$SM_NODES; _lt=$SM_NTPN; _le=$SM_EXACT
                if (( _need != mem_next || _ln != $(int "${chain_nodes:-1}") || _lt != $(int "${chain_ntpn:-1}") )); then
                    rewrite_allocation "$_need" "$_ln" "$_lt" "$_le" "$_R"
                    say "memory for chunk $((idx+1)): ${mem_next} -> ${_need} MB/cpu (peak ${_pk} MB/rank, ${mem_src})"
                    (( _ln != $(int "${chain_nodes:-1}") )) && \
                        say "  spread over ${_ln} node(s), ${_lt} rank(s) per node; the rank count is unchanged"
                fi
                state_set chain_mem_per_cpu "$_need" chain_nodes "$_ln" chain_ntpn "$_lt" chain_ntpn_exact "$_le"
                mem_next=$_need
            fi
        fi
    fi

    _sig=""; (( _hit_walltime )) && _sig=" [signalled]"
    log_line "$idx" "${SLURM_JOB_ID:-?}" "SCF" "$cap" "$steps" "$t_step" "$elapsed" \
             "$frac" "$mem_max" "$mem_granted" "$verdict" "${detail}${_sig}"

    # ---- act ----------------------------------------------------------------
    if [[ $verdict == CONVERGED ]]; then
        state_set chain_state converged stop_reason ""
        {
            echo "converged at chunk ${idx} on $(date -Iseconds)"
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
        # The physics verdict, so it is waiting when the user wakes up.
        command -v vasp-check >/dev/null 2>&1 && { echo; vasp-check 2>&1 | tail -40; }
        # One 'finished' mail from the last chunk only.
        scontrol update "JobId=${SLURM_JOB_ID:-0}" MailType=END,FAIL >/dev/null 2>&1
        exit 0
    fi

    if [[ $verdict == CONTINUE ]]; then
        state_set next_cap "$newcap" chain_state running
        say "not converged yet (${steps}/${nelm_eff} electronic steps); submitting chunk $((idx+1)) with cap ${newcap}"
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
        log_line "$idx" "${SLURM_JOB_ID:-?}" "SCF" \
                 "$cap" "$steps" "$t_step" "$elapsed" "$frac" "$mem_max" "$mem_granted" \
                 "STOP" "sbatch failed: ${out}"
    fi

    # ---- stop ---------------------------------------------------------------
    state_set chain_state stopped stop_reason "$reason"
    rm -f "$CH_RUN"
    {
        echo "stopped at chunk ${idx} on $(date -Iseconds)"
        echo "reason  : ${reason}"
        echo "detail  : ${detail}"
        echo
        if [[ $reason == memory_does_not_fit ]]; then
            echo "--resume cannot continue this chain on this partition: ${detail}."
            echo "What frees memory, in order: a lower KPAR in the INCAR (each k-point group"
            echo "keeps its own copy of the charge density and grids), fewer ranks, LREAL = Auto."
            echo "Then:   ${CMD} --fresh"
        else
            echo "Resume with:   ${CMD} --resume"
        fi
        if [[ $reason == oom ]]; then
            _nx=$(awk -v g="$mem_granted" -v f="$OOM_FACTOR" 'BEGIN{ printf "%d", int((g*f+49)/50)*50 }')
            echo "               --resume raises the memory by itself: at least ${mem_granted} -> ${_nx} MB/cpu,"
            echo "               more if the measurements say so, spreading over more nodes if a"
            echo "               node cannot hold it."
        fi
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

hdr "Chunked SCF -- setup"

# ---- prerequisites --------------------------------------------------------
[[ -f "$SRC_SLURM" ]] || die "no ${SRC_SLURM} here. Run the pipeline first:
     vasp-dry-run  ->  vasp-recommend-slurm  ->  vasp-test
   ${SRC_SLURM} carries the MEASURED memory and geometry; it cannot be guessed." 3

# ---- an earlier chain in this folder ----------------------------------------
# A chunk still queued or running blocks BOTH start and resume. This used to be
# checked for a start only, so --resume on a live chain submitted a second
# chunk into the same folder: two VASPs over one WAVECAR and one CONTCAR.
_prev_state=""; _prev_jid=""
if [[ -f "$CH_ENV" ]]; then
    state_load
    _prev_state="${chain_state:-}"
    _prev_jid=$(tr -dc '0-9' 2>/dev/null < "$CH_RUN")
    if [[ -n $_prev_jid ]] && [[ -n "$(squeue -h -j "$_prev_jid" 2>/dev/null)" ]]; then
        die "a chunk of this chain is still queued or running (job ${_prev_jid}). Use --status, or --stop first." 3
    fi
fi
if [[ $ACTION == resume ]] && [[ ! -f "$CH_ENV" ]]; then
    die "nothing to resume: there is no chain here ($CH_ENV not found)." 3
fi
if [[ $ACTION == start ]] && [[ -f "$CH_ENV" ]]; then
    # A NEW chain must not inherit the old one's state. state_set carries
    # forward every key it is not given, so the last chain's NBANDS, NKPTS,
    # force history and measured memory would silently steer this one.
    _submitted=$(printf '%s' "${jobids:-}" | tr -s ' ' '\n' | grep -cE '^[0-9]+$')
    if [[ $_prev_state == converged ]] || (( OPT_FRESH )) || (( _submitted == 0 )); then
        _arch="${CHDIR}.prev-$(date +%Y%m%d-%H%M%S)"
        mv "$CHDIR" "$_arch"
        while IFS='=' read -r _k _; do
            [[ $_k =~ ^[a-z_][a-z0-9_]*$ ]] && unset "$_k"
        done < "$_arch/chain.env"
        note "the previous chain here was archived to ${_arch}/ -- this is a NEW chain."
    else
        die "an unfinished chain is here (${_prev_state:-?}${stop_reason:+: ${stop_reason}}).
   Continue it:        ${CMD} --resume
   Or start over:      ${CMD} --fresh     (the old chain is archived, not deleted)" 3
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

(( nsw > 1 )) && die "this INCAR has NSW=${nsw}: it is a relaxation, not a static SCF.
   Use vasp-relax-loop for that." 2

# ---- measured inputs ------------------------------------------------------
# shellcheck source=/dev/null
[[ -f .wolfpack/state.env ]] && source .wolfpack/state.env
t_e="${test_avg_loop:-0}"
awk -v t="$t_e" 'BEGIN{exit !(t>0)}' || die "no measured per-step time in .wolfpack/state.env.
   Re-run vasp-test here: the chunk size is derived from it and cannot be guessed." 3

RANKS=$(sb_num ntasks);        RANKS=$(int "${RANKS:-0}")
NODES=$(sb_num nodes);         NODES=$(int "${NODES:-1}")
# --ntasks-per-node is ABSENT from the source script whenever the rank count
# does not divide evenly over the nodes (vasp-recommend-slurm leaves it out
# rather than write a claim SLURM has to correct). Defaulting to $RANKS there
# would put every rank on one node -- 190 tasks on a 48-core node -- so derive
# the even fill instead, and remember that it was derived.
NTPN=$(sb_num ntasks-per-node)
if [[ -z "${NTPN:-}" ]]; then
    NTPN=$(( (RANKS + NODES - 1) / NODES ))
    NTPN_EXACT=0
else
    NTPN=$(int "$NTPN"); NTPN_EXACT=1
fi
NTPN=$(int "${NTPN:-1}"); (( NTPN < 1 )) && NTPN=1
MEMCPU=$(sb_num mem-per-cpu);  MEMCPU=$(int "${MEMCPU:-0}")
PART=$(sb_str partition);      PART="${PART:-${WP_MAIN_PARTITION}}"
EXE=$(grep -m1 -E '^/usr/bin/time -v srun ' "$SRC_SLURM" 2>/dev/null | awk '{print $NF}')
EXE="${EXE:-${exe:-${WP_VASP_STD}}}"
(( RANKS > 0 ))  || die "${SRC_SLURM} has no --ntasks." 3
(( MEMCPU > 0 )) || die "${SRC_SLURM} has no --mem-per-cpu." 3
ALLOC_SRC="${SRC_SLURM}"

# On --resume the allocation is the CHAIN's own, not slurm_vasptest.sh's. The
# chain rewrites its memory and layout after every chunk; re-reading the
# source script here threw all of that away, so a resume after an OOM kill
# went straight back to the allocation that had just been killed.
if [[ $ACTION == resume ]]; then
    [[ ${chain_state:-} == converged ]] && \
        die "this chain already converged -- see $CH_DONE. Use --fresh to start a new one." 3
    [[ -n ${chain_mem_per_cpu:-} ]] && MEMCPU=$(int "$chain_mem_per_cpu")
    [[ -n ${chain_nodes:-} ]]       && NODES=$(int "$chain_nodes")
    [[ -n ${chain_ntpn:-} ]]        && NTPN=$(int "$chain_ntpn")
    [[ -n ${chain_ntpn_exact:-} ]]  && NTPN_EXACT=$(int "$chain_ntpn_exact")
    [[ -n ${chain_ranks:-} ]]       && RANKS=$(int "$chain_ranks")
    [[ -n ${chain_exe:-} ]]         && EXE="$chain_exe"
    [[ -n ${chain_partition:-} ]]   && PART="$chain_partition"
    [[ -n ${chain_mem_per_cpu:-} ]] && ALLOC_SRC="the chain's own record (${CH_ENV})"
fi

# The node the chunks land on, and what the account may be charged. Kept in
# the state: a chunk rewrites its successor's allocation from a compute node,
# where the cluster profile may not be readable at all.
if [[ $PART == "${WP_DEBUG_PARTITION:-}" && $PART != "${WP_MAIN_PARTITION:-}" ]]; then
    NODE_MEM=$(int "${WP_DEBUG_MEM_PER_NODE_MB:-0}"); NODE_CPN=$(int "${WP_DEBUG_CPUS_PER_NODE:-1}")
    NODE_MARGIN="${WP_DEBUG_MEM_MARGIN:-0.05}"
else
    NODE_MEM=$(int "${WP_MAIN_MEM_PER_NODE_MB:-0}"); NODE_CPN=$(int "${WP_MAIN_CPUS_PER_NODE:-1}")
    NODE_MARGIN="${WP_MAIN_MEM_MARGIN:-0.02}"
fi
chain_node_mem_mb="$NODE_MEM"; chain_mem_margin="$NODE_MARGIN"; chain_cpn="$NODE_CPN"
chain_max_cores="$(int "${WP_MAX_CORES:-0}")"; chain_profile="${WP_ALLOC_PROFILE:-whole-nodes}"
chain_nodes0="${chain_nodes0:-$NODES}"
MAXT=$(part_maxtime_min "$PART")

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

# ---- what one step costs ------------------------------------------------------
# The benchmark may have run on the debug partition, at a different rank count, with
# LWAVE/LCHARG off -- so its rate is a starting estimate, not a measurement of
# this job. Chunk 1 is deliberately conservative and recalibrates from reality.
CAL=$(awk -v t="$t_e" -v tr="${test_ranks:-0}" -v pr="$RANKS" -v eff="${test_cpu_eff:-100}" \
      'BEGIN{ r=(tr>0&&pr>0? tr/pr : 1); e=eff/100; if(e<0.3)e=0.3; if(e>1)e=1;
              printf "%.3f", t*r/e }')
# ---- the chunk walltime: chosen ONCE, then fixed for the whole chain ---------
MARGIN_CFG=$(int "${WP_CHUNK_MARGIN_MIN:-$DEF_MARGIN_MIN}")
STARTUP=$(secs "${test_startup_s:-120}")
DEFAULT_WALL=$(int "${WP_CHUNK_WALLTIME_MIN:-$DEF_WALLTIME_MIN}")
WALL_SRC=""
if [[ $ACTION == resume ]] && [[ -n ${chain_wall_min:-} ]]; then
    WALL=$(int "$chain_wall_min"); WALL_SRC="fixed at launch (${chain_wall_source:-?})"
    [[ -n ${OPT_WALLTIME:-} ]] && warn "--walltime is ignored on --resume: a chain keeps the chunk walltime it
     started with (${WALL} min). Use --fresh to start a new chain with a different one."
elif [[ -n ${OPT_WALLTIME:-} ]]; then
    # Whole minutes only: int() would read "1:30" as 130 and "90.5" as 905.
    [[ $OPT_WALLTIME =~ ^[0-9]+$ ]] && (( OPT_WALLTIME > 0 )) || \
        die "--walltime takes whole minutes (e.g. --walltime 90), not '${OPT_WALLTIME}'." 2
    WALL=$(int "$OPT_WALLTIME"); WALL_SRC="--walltime"
else
    WALL=$DEFAULT_WALL; WALL_SRC="profile default (WP_CHUNK_WALLTIME_MIN)"
fi
# The partition's MaxTime is a hard ceiling. A walltime above it is a chunk the
# scheduler rejects at submit -- inside a running chain, a chain that dies at a
# boundary. An explicit --walltime over it is refused rather than overridden.
if [[ -n $MAXT ]] && (( WALL > MAXT )); then
    [[ $WALL_SRC == --walltime ]] && die "--walltime ${WALL} min is above the partition's MaxTime of ${MAXT} min:
   the scheduler would reject every chunk. Ask for ${MAXT} or less." 2
    note "chunk walltime ${WALL} min capped at the partition's MaxTime (${MAXT} min)"
    WALL=$MAXT
fi

# ---- budget ---------------------------------------------------------------
MARGIN=$MARGIN_CFG
m2=$(awk -v w="$WALL" 'BEGIN{printf "%d", w*0.08}'); (( m2 > MARGIN )) && MARGIN=$m2
T_VASP=$(( WALL*60 - MARGIN*60 ))
T_WORK=$(( T_VASP - STARTUP ))
(( T_WORK < 60 )) && die "the walltime budget leaves no room to compute (${WALL} min minus
   ${MARGIN} min margin minus ${STARTUP}s start-up). Raise --walltime." 2

# ---- chunk 1 -------------------------------------------------------------------
CAP1=$(awk -v b="$T_WORK" -v t="$CAL" -v s="$SAFETY" -v c="$NELM_CEIL" -v f="$NELM_FLOOR" \
       -v o="$NELM_ORIG" 'BEGIN{ if(t<=0){print f; exit}
             n=int(b/(t*s*1.5)); if(n>c)n=c; if(n>o)n=o; print n }')
(( CAP1 < NELM_FLOOR )) && die "one chunk cannot hold ${NELM_FLOOR} SCF steps at
   ${CAL}s per step within ${WALL} min. Raise --walltime or the rank count." 2

# ---- --resume: settle whatever the last chunk left behind -------------------
RESUME_CAUSE=""
if [[ $ACTION == resume ]]; then
    last_jid=$(tr -dc '0-9' 2>/dev/null < "$CH_RUN")
    [[ -z $last_jid ]] && last_jid=$(printf '%s' "${jobids:-}" | tr -s ' ' '\n' | grep -E '^[0-9]+$' | tail -1)
    unfinished=0; [[ ${chain_state:-} == running ]] && unfinished=1
    read -r _mstate _mmax _mave < <(job_mem_evidence "$last_jid" 0)
    _mmax=$(int "${_mmax:-0}"); _mave=$(int "${_mave:-0}")
    RESUME_CAUSE="${stop_reason:-}"
    if [[ $RESUME_CAUSE == oom || ${_mstate:-} == OUT_OF_MEMORY ]] \
       || { [[ -n $last_jid ]] && err_mentions "$last_jid" "$OOM_RX"; }; then
        RESUME_CAUSE="oom"
    elif [[ ${_mstate:-} == TIMEOUT ]] || { [[ -n $last_jid ]] && err_mentions "$last_jid" "$TIMEOUT_RX"; }; then
        RESUME_CAUSE="timeout"
    elif (( unfinished )); then
        RESUME_CAUSE="died (${_mstate:-UNKNOWN})"
    fi

    # Some stops cannot be resumed by rerunning: the thing that stopped them is
    # still there. Saying so beats a chunk that fails the same way.
    case "${stop_reason:-}" in
        numerical)
            die "the last chunk produced NaN or overflow in OSZICAR. That is the calculation,
   not the chain: fix the INCAR (mixing, ALGO, POTIM), then --fresh." 3 ;;
    esac

    hdr "Resuming -- what the last chunk left behind"
    kv "last chunk"      "job ${last_jid:-?}"
    kv "how it ended"    "${RESUME_CAUSE:-stopped cleanly}$( (( _mmax > 0 )) && echo "  (peak ${_mmax} MB/rank measured)")"

    # (1) A chunk that died WITH its job never ran its own bookkeeping: nothing
    #     was archived. Do what it would have done. "Fresh" means written by
    #     that chunk, i.e. after it was submitted -- an older OSZICAR belongs to
    #     the chunk before.
    _ref="$CH_RUN"; [[ -f $_ref ]] || _ref="$CH_ENV"
    _fresh(){ [[ -s $1 && $1 -nt $_ref ]]; }
    if (( unfinished )); then
        idx_dead=$(( $(int "${chunk_index:-0}") + 1 ))
        cdir="$CHDIR/chunk-$(printf '%03d' "$idx_dead")"; mkdir -p "$cdir"
        for f in OUTCAR OSZICAR vasprun.xml; do
            _fresh "$f" && { cp -f "$f" "$cdir/"; gzip -f "$cdir/$f" 2>/dev/null; }
        done
        for f in "VASP-chain-${last_jid}.out" "VASP-chain-${last_jid}.err"; do
            [[ -e $f ]] && mv -f "$f" "$cdir/" 2>/dev/null
        done
        state_set chunk_index "$idx_dead"
        log_line "$idx_dead" "${last_jid:-?}" "SCF" \
                 "${next_cap:-?}" "-" "-" "-" "-" "$(( _mmax > 0 ? _mmax : 0 ))" \
                 "${chain_mem_per_cpu:-$MEMCPU}" "DIED" "${RESUME_CAUSE}; settled by --resume"
        kv "settled"         "chunk ${idx_dead}: archived in ${cdir}/"
        # Settled, and recorded as such: a second --resume must not archive
        # this chunk again as the next one.
        case $RESUME_CAUSE in oom|timeout) _sk=$RESUME_CAUSE ;; *) _sk=died ;; esac
        state_set chain_state stopped stop_reason "$_sk"
    fi

    # (3) The restart object. VASP writes WAVECAR once, at the end of a run, so a
    #     chunk killed mid-run left the previous chunk's -- intact, and right for
    #     a restart. A WAVECAR written by the dead chunk itself was cut off
    #     WHILE being written unless its size matches the last good one; a
    #     truncated WAVECAR makes the next chunk die reading it, and then every
    #     resume after it. Set it aside and start that one chunk cold.
    COLD_NEXT=0
    if [[ $RESUME_CAUSE != "" ]] && [[ -s WAVECAR ]] && [[ WAVECAR -nt $_ref ]]; then
        _wsz=$(stat -c %s WAVECAR 2>/dev/null || echo 0)
        if [[ -z ${wavecar_bytes:-} ]] || (( _wsz != $(int "${wavecar_bytes:-0}") )); then
            mv -f WAVECAR WAVECAR.partial
            COLD_NEXT=1
            warn "WAVECAR was written by the chunk that died and cannot be verified complete;"
            warn "set aside as WAVECAR.partial. The next chunk starts cold (ISTART=0, ICHARG=2)."
        fi
    fi

    # (4) What killed it decides what changes.
    case $RESUME_CAUSE in
        memory_does_not_fit)
            # The last chunk measured more than a node holds. Resubmitting at the
            # old size would be a chunk sized below what was measured -- an OOM
            # waiting to happen. Recompute from the measurements: if the profile
            # has changed (bigger nodes, another partition) it may fit now.
            if ! settle_memory "$(int "${mem_peak_max_mb:-0}")" "$(int "${mem_ave_max_mb:-0}")" "$RANKS" "$NTPN" 1 0; then
                die "the memory this chain measured still does not fit: ${SM_WHY}.
   What frees memory, in order: a lower KPAR in the INCAR (each k-point group
   keeps its own copy of the charge density and grids), fewer ranks, LREAL = Auto.
   POSCAR holds the geometry reached. Then start over with --fresh." 3
            fi
            ok "the measured memory fits now: ${SM_NEED} MB/cpu, ${SM_NODES} node(s) x ${SM_NTPN} rank(s)"
            MEMCPU=$SM_NEED; NODES=$SM_NODES; NTPN=$SM_NTPN; NTPN_EXACT=$SM_EXACT
            ;;
        oom)
            # A kill says the need was ABOVE the grant, never by how much. Take the
            # larger of: the grant raised by OOM_FACTOR, and what the measurements
            # say the heaviest node needs.
            _granted=$(int "${chain_mem_per_cpu:-$MEMCPU}")
            _esc=$(awk -v g="$_granted" -v f="$OOM_FACTOR" 'BEGIN{ printf "%d", int((g*f + 49)/50)*50 }')
            _pk=$(( _mmax > $(int "${mem_peak_max_mb:-0}") ? _mmax : $(int "${mem_peak_max_mb:-0}") ))
            _av=$(( _mave > $(int "${mem_ave_max_mb:-0}") ? _mave : $(int "${mem_ave_max_mb:-0}") ))
            if ! settle_memory "$_pk" "$_av" "$RANKS" "$NTPN" 1 "$_esc"; then
                die "the memory cannot be raised enough to continue: ${SM_WHY}.
   The last chunk was killed at ${_granted} MB/cpu; the next needs at least ${SM_NEED}.
   What frees memory, in order: a lower KPAR in the INCAR (each k-point group
   keeps its own copy of the charge density and grids), fewer ranks, LREAL = Auto.
   Then start over with --fresh." 3
            fi
            _new=$SM_NEED; _ln=$SM_NODES; _lt=$SM_NTPN; _le=$SM_EXACT
            ok "memory raised ${_granted} -> ${_new} MB/cpu (the last chunk was OOM-killed at ${_granted})"
            if (( _ln != NODES )); then
                ok "at that size the ranks no longer fit ${NODES} node(s): spread over ${_ln} node(s), ${_lt} per node"
                note "the rank count is unchanged (${RANKS}), so KPAR/NCORE in the INCAR still hold"
            fi
            MEMCPU=$_new; NODES=$_ln; NTPN=$_lt; NTPN_EXACT=$_le
            state_set oom_count "$(( $(int "${oom_count:-0}") + 1 ))" \
                      last_oom_jid "${last_jid:-}" last_oom_granted_mb "$_granted" \
                      mem_peak_max_mb "$_pk" mem_ave_max_mb "$_av"
            ;;
        timeout)
            # The walltime killed the job despite the LABORT warning: the steps
            # took longer than the chain's rate said. The walltime stays fixed;
            # the next chunk is given fewer steps, as a signalled chunk would.
            _nc=$(awk -v n="$(int "${next_cap:-$NELM_FLOOR}")" -v f="$NELM_FLOOR" \
                  'BEGIN{ v = int(n * 0.7); print (v < f ? f : v) }')
            state_set next_cap "$_nc"
            ok "electronic steps per chunk lowered to ${_nc} after the walltime kill"
            ;;
    esac

    # (5) Clear the dead chunk's markers and record what was decided.
    if [[ -f $CH_DEAD ]]; then
        _lastdir="$CHDIR/chunk-$(printf '%03d' "$(int "${chunk_index:-0}")")"
        mkdir -p "$_lastdir"; mv -f "$CH_DEAD" "$_lastdir/STOPPED.txt" 2>/dev/null
    fi
    rm -f "$CH_RUN" STOPCAR
    state_set chain_state running stop_reason "" next_cold_start "$COLD_NEXT" \
              last_resume "$(date -Iseconds)" last_resume_cause "${RESUME_CAUSE:-clean}"
    say "resuming at chunk $(( $(int "${chunk_index:-0}") + 1 ))"
fi

kv "VASP executable"    "$EXE"
kv "geometry"           "${NODES} node(s) x ${NTPN} ranks, ${MEMCPU} MB/cpu on '${PART}'"
kv "  from"             "$ALLOC_SRC"
kv "node"               "${NODE_CPN} cores, ${NODE_MEM} MB$( [[ -n $MAXT ]] && echo ", MaxTime ${MAXT} min" )"
kv "measured rate"      "${t_e} s/step (benchmark) -> ${CAL} s/step (scaled estimate)"
kv "chunk walltime"     "${WALL} min  (margin ${MARGIN} min, start-up ${STARTUP}s)"
kv "  chosen by"        "$WALL_SRC"
kv "first chunk cap"    "${CAP1} electronic steps  (calibration; later chunks resize)"
kv "original NELM"      "$NELM_ORIG"
kv "memory"             "measured after every chunk; the next one's --mem-per-cpu is rewritten from it"

if (( NTPN * NODES > NODE_CPN )) && [[ $ACTION != resume ]]; then
    warn "this job spans more than one node. Short jobs backfill well only when they"
    warn "are also small; at this size chunking may not shorten the queue wait, and"
    warn "you pay the start-up and WAVECAR I/O once per chunk."
fi

# ---- render the job ----------------------------------------------------------
# Re-rendered on every launch AND every resume, from the chain's own record.
# Between those, each chunk rewrites its successor's --mem-per-cpu, --nodes and
# --ntasks-per-node in place (rewrite_allocation) from what it measured. Editing
# THIS file by hand is therefore undone at the next boundary -- change memory
# in slurm_vasptest.sh before a --fresh chain, or let the chain measure it.
mkdir -p "$CHDIR"
SELF=$(readlink -f "$0")
tt=$(printf '%02d:%02d:00' $((WALL/60)) $((WALL%60)))
{
    echo "#!/bin/bash"
    echo "#SBATCH --job-name=vasp-chain-${MODE}"
    echo "#SBATCH --partition=${PART}"
    echo "#SBATCH --nodes=${NODES}"
    echo "#SBATCH --ntasks=${RANKS}"
    # Only when it is arithmetically true -- see the note where NTPN is read.
    if (( NTPN_EXACT == 1 && NODES * NTPN == RANKS )); then
        echo "#SBATCH --ntasks-per-node=${NTPN}"
    else
        echo "# no --ntasks-per-node: ${RANKS} ranks do not divide evenly over ${NODES} node(s)"
    fi
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
    echo "# Generated by vasp-${MODE}-loop on $(date -Iseconds)."
    echo "# Submitted once per chunk. The #SBATCH allocation above is REWRITTEN by each"
    echo "# chunk from the memory it measured, and this whole file is re-rendered on"
    echo "# --resume: hand edits here do not survive a chunk boundary."
    echo "#   walltime : ${WALL} min, fixed for the chain -- ${WALL_SRC}"
    echo "#   memory   : starts from ${ALLOC_SRC}, then measured chunk by chunk"
    echo 'cd "$SLURM_SUBMIT_DIR" || exit 1'
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        [[ "${WP_MODULE_PURGE:-1}" == "1" ]] && echo "${WP_MODULE_CMD:-ml} purge"
        echo "${WP_MODULE_CMD:-ml} ${WP_VASP_MODULES}"
    fi
    echo "export OMP_NUM_THREADS=1"
    echo "export MKL_NUM_THREADS=1"
    [[ -n "${WP_EXTRA_ENV:-}" ]] && echo "${WP_EXTRA_ENV}"
    echo ""
    # Every chunk re-execs this script on a COMPUTE node, where it re-reads the
    # cluster profile. That profile need not be reachable from there: on Santos
    # Dumont $HOME is /prj, which compute nodes do not mount, so each chunk
    # would exit 2 on arrival and the chain would die one chunk at a time. Point
    # it at the copy staged in the chain directory, which sits on the same
    # filesystem as the calculation and is therefore visible by construction.
    echo "_wp_staged=\"\$SLURM_SUBMIT_DIR/${CHDIR}/cluster.conf\""
    echo '[[ -f "$_wp_staged" ]] && export WOLFPACK_CLUSTER_CONF="$_wp_staged"'
    echo ""
    # --mode explicitly: the job invokes the real file path, where the symlink
    # name the user typed -- and with it the mode -- is no longer visible.
    echo "exec '${SELF}' --mode ${MODE} --chunk-body"
} > "$CH_JOB"
chmod +x "$CH_JOB"
[[ -f "$_wp_conf" ]] && cp -f "$_wp_conf" "$CHDIR/cluster.conf"

# ---- state ----------------------------------------------------------------
# The allocation and the layout context go into the state on every launch and
# resume: the chunk that rewrites its successor reads them from here.
_alloc_keys=(chain_mem_per_cpu "$MEMCPU" chain_nodes "$NODES" chain_ntpn "$NTPN"
             chain_ntpn_exact "$NTPN_EXACT" chain_partition "$PART"
             chain_node_mem_mb "$chain_node_mem_mb" chain_mem_margin "$chain_mem_margin"
             chain_cpn "$chain_cpn" chain_max_cores "$chain_max_cores"
             chain_profile "$chain_profile" chain_nodes0 "$chain_nodes0")
if [[ $ACTION == resume ]]; then
    state_set "${_alloc_keys[@]}"
else
    rm -f "$CH_DONE" "$CH_DEAD"
    state_set chain_kind "$MODE" chain_state running chain_started "$(date -Iseconds)" \
              chain_self "$SELF" chain_exe "$EXE" chain_ranks "$RANKS" \
              chain_ediff "$(incar_get EDIFF)" nelm_target "$NELM_ORIG" \
              chunk_index 0 nelm_total 0 wall_used_s 0 corehours 0 \
              next_cap "$CAP1" t_elec_s "$CAL" t_startup_s "$STARTUP" \
              t_work_s "$T_WORK" t_vasp_budget_s "$T_VASP" \
              chain_wall_min "$WALL" chain_wall_source "$WALL_SRC" chain_margin_cfg_min "$MARGIN_CFG" \
              stall_streak 0 tight_streak 0 mem_peak_max_mb 0 mem_ave_max_mb 0 \
              oom_count 0 next_cold_start 0 \
              "${_alloc_keys[@]}"
fi

# ---- go -------------------------------------------------------------------
if out=$(sbatch "$CH_JOB" 2>&1); then
    jid="${out##* }"
    echo "$jid" > "$CH_RUN"
    state_set jobids "${jobids:-} ${jid}"
    echo
    ok "chain $([[ $ACTION == resume ]] && echo resumed || echo started): $out"
    note "It will keep submitting chunks until it converges."
    note "  watch:  ${CMD} --status"
    note "  stop :  ${CMD} --stop        (finishes the current chunk first)"
else
    die "sbatch failed: $out"
fi
