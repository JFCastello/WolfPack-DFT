#!/usr/bin/env bash
###############################################################################
# vasp_relax_loop.sh   (on PATH as: vasp-relax-loop)
#
# A relaxation as a chain of short jobs. Every job (chunk) runs the same NSW
# ionic steps from the geometry the last one reached, and asks for the
# walltime ITS steps are estimated to need -- no more.
#
# HOW
#   chunk 1   NSW ionic steps from your POSCAR. Its walltime comes from what
#             vasp-test --full-size measured at the production rank count.
#   chunk n   NSW ionic steps from chunk n-1's CONTCAR. Its walltime comes
#             from chunk n-1's measured times.
#   ...until VASP reports "reached required accuracy", --max-ionic geometries
#   have been computed, or the --steps list is used up.
#
# WHAT ONE CHUNK ADVANCES
#   VASP's CONTCAR is the last geometry it COMPUTED: after the last ionic step
#   it does not move the ions (checked with VASP 6.5.1, IBRION 1, 2 and 3). So
#   NSW = 1 would compute the same geometry forever, and is refused. A chunk
#   of NSW = N advances N-1 geometries; its first step recomputes the
#   geometry the chunk before ended at.
#
#   Each chunk also starts a new optimisation: IBRION = 1 and 2 choose their
#   next step from the history of earlier ones (vasp.at/wiki: Structure
#   optimization), and a new VASP run has none. A chained relaxation can
#   therefore take more ionic steps than a single run.
#
# THE WALLTIME OF A CHUNK
#     estimate x --safety (1.15) + --margin-min (5 min), in whole minutes
#   The estimate is the start-up, plus the first ionic step, plus NSW-1 later
#   ones. See wolfpack_steptime.sh for how each is measured or extrapolated.
#
# A CHUNK THAT RUNS OUT OF WALLTIME OR MEMORY is run again -- in a new,
# clean directory, from the same inputs as before (the last SUCCESSFUL
# chunk's CONTCAR, never the failed attempt's files), with a longer walltime
# (re-estimated from what it measured, and at least 1.5x) or 1.5x the memory.
# At most --max-retries times per chunk.
#
# USAGE
#   cd <calc folder>        # after vasp-dry-run, vasp-recommend-slurm, vasp-test --full-size
#   vasp-relax-loop [options]
#     --nsw N           NSW of every chunk when the INCAR has none (default 2)
#     --steps 2,5,7     one job per entry, with that NSW (instead of the INCAR's)
#     --max-ionic N     stop after N distinct geometries (default 100)
#     --max-retries N   retries of one chunk after a walltime or memory kill (default 2)
#     --carry-wavecar   also carry WAVECAR and CHGCAR to the next chunk
#     --safety F        the walltime factor (default 1.15)
#     --margin-min M    minutes added to every walltime (default 5, at least 3)
#   vasp-relax-loop --status | --stop [--now] | --resume | --fresh
#
#   Progress, chunk by chunk:  relax_progress.txt
#   The latest geometry and outputs are copied to this folder after every
#   chunk (CONTCAR, OUTCAR, OSZICAR, vasprun.xml); POSCAR stays yours.
#
# REQUIREMENTS
#   vasp-test --full-size here (slurm_vasptest.sh, and its OUTCAR and OSZICAR
#   in .wolfpack/). EDIFFG < 0 in the INCAR: with NSW steps per run, VASP can
#   only compare energies within a run, never across chunks. IBRION 1, 2 or 3.
###############################################################################
set -uo pipefail

_wp_here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
for _l in wolfpack_chain_lib.sh wolfpack_steptime.sh wolfpack_incar.sh; do
    # shellcheck source=/dev/null
    if [[ -r "$_wp_here/$_l" ]]; then source "$_wp_here/$_l"; else
        echo "ERROR: $_l not found next to $(readlink -f "${BASH_SOURCE[0]}")" >&2; exit 1
    fi
done
# The cluster profile: partitions, node sizes, the VASP modules.
_wp_conf="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
# shellcheck source=/dev/null
[[ -f "$_wp_conf" ]] && source "$_wp_conf"
usage(){ awk 'NR == 1 { next } /^#####/ { if (++n == 2) exit; next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

CMD="vasp-relax-loop"
ACTION="start"
OPT_NSW=""; OPT_STEPS=""; OPT_MAXION=""; OPT_RETRIES=""; OPT_CARRY=""
OPT_SAFETY=""; OPT_MARGIN=""; OPT_FRESH=0; STOP_NOW=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --chunk-body)   ACTION="chunk"; shift ;;
        --status)       ACTION="status"; shift ;;
        --stop)         ACTION="stop"; shift ;;
        --now)          STOP_NOW=1; shift ;;
        --resume)       ACTION="resume"; shift ;;
        --fresh)        OPT_FRESH=1; shift ;;
        --nsw)          OPT_NSW="${2:-}"; shift 2 ;;
        --steps)        OPT_STEPS="${2:-}"; shift 2 ;;
        --max-ionic)    OPT_MAXION="${2:-}"; shift 2 ;;
        --max-retries)  OPT_RETRIES="${2:-}"; shift 2 ;;
        --carry-wavecar) OPT_CARRY=1; shift ;;
        --no-carry-wavecar) OPT_CARRY=0; shift ;;
        --safety)       OPT_SAFETY="${2:-}"; shift 2 ;;
        --margin-min)   OPT_MARGIN="${2:-}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown option: $1  (try --help)" 2 ;;
    esac
done

# ---- the chain's files -------------------------------------------------------
# Visible, and not under .wolfpack/: vasp-clean removes that by default.
CHDIR="wolfpack_chain"
CH_ENV="$CHDIR/chain.env"
CH_JOB="$CHDIR/slurm_chunk.sh"
CH_RUN="$CHDIR/RUNNING"
CH_STOP="$CHDIR/STOP"
CH_DONE="$CHDIR/FINISHED"
CH_DEAD="$CHDIR/STOPPED"
CH_ROWS="$CHDIR/progress.rows"
PROGRESS="relax_progress.txt"
SIGNAL_LEAD=120              # the job's warning before the walltime kill, seconds
MEM_SAFETY=1.25              # headroom over the measured memory
OOM_FACTOR=1.5               # after an OOM kill
RETRY_WALL_FACTOR=1.5        # at least this much more walltime after a walltime kill
MEM_FLOOR_MB=256
SACCT_POLL_S=45
OOM_RX='oom[-_]kill|Out Of Memory|exceeded memory limit'
TIMEOUT_RX='DUE TO TIME LIMIT'
# Inputs a chunk takes besides INCAR, KPOINTS and POTCAR, when present.
EXTRA_INPUTS=(vdw_kernel.bindat ICONST PENALTYPOT GAMMA)

posint(){ [[ ${1:-} =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }
posnum(){ [[ ${1:-} =~ ^[0-9]*\.?[0-9]+$ ]] && awk -v v="$1" 'BEGIN{exit !(v>0)}'; }
dname(){ printf '%03d' "$(( 10#$1 ))"; }                 # 7 -> 007
fmt_min(){ printf '%d:%02d' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; }                  # minutes -> h:mm
fmt_s(){ local s; s=$(secs "$1"); printf '%d:%02d:%02d' "$(( s/3600 ))" "$(( s%3600/60 ))" "$(( s%60 ))"; }
# A tag's value as VASP reads it: several tags may share a line, separated by
# ';', and '!' or '#' starts a comment. The last occurrence wins.
incar_val(){
    awk -v K="$1" '{ sub(/[!#].*/, ""); n = split($0, p, ";")
        for (i = 1; i <= n; i++) { s = p[i]; sub(/^[ \t]+/, "", s)
            if (toupper(s) ~ "^" toupper(K) "[ \t]*=") {
                sub(/^[^=]*=[ \t]*/, "", s); split(s, w, /[ \t]+/); v = w[1] } } }
        END { if (v != "") print v }' "${2:-INCAR}" 2>/dev/null
}

# NSW of chunk I (1-based): the --steps entry, else the chain's NSW.
nsw_of(){
    local i="$1" list="${chain_steps:-}"
    if [[ -n $list ]]; then
        awk -v i="$i" -v l="$list" 'BEGIN{ n = split(l, a, ","); print (i <= n ? a[i] : 0) }'
    else
        echo "${chain_nsw:-2}"
    fi
}

# ---- progress file -----------------------------------------------------------
# One row per attempt in $CH_ROWS (tab-separated); relax_progress.txt is
# rebuilt from them and the state every time, so it is always whole.
row_add(){ printf '%s\n' "$(IFS=$'\t'; echo "$*")" >> "$CH_ROWS"; }
progress_write(){
    local tmp="$PROGRESS.new"
    {
        printf 'vasp-relax-loop -- %s          updated %s\n' "$(basename "$PWD")" "$(date '+%Y-%m-%d %H:%M')"
        printf '  NSW per chunk: %s   stop after %s geometries   retries: up to %s per chunk\n' \
            "${chain_nsw_words:-?}" "${chain_max_ionic:-?}" "${chain_max_retries:-?}"
        printf '  EDIFFG %s (forces)   WAVECAR carried: %s   walltime = estimate x %s + %s min\n' \
            "${chain_ediffg:-?}" "$( [[ ${chain_carry:-0} == 1 ]] && echo yes || echo no )" \
            "${chain_safety:-?}" "${chain_margin_min:-?}"
        echo
        printf '  %5s %3s %3s  %5s %5s  %-15s %6s  %9s %6s %9s  %14s %7s  %s\n' \
            chunk try NSW ionic geoms "e-steps/ionic" "est.e" "estimate" "asked" "used" "energy (eV)" "max|F|" result
        [[ -s $CH_ROWS ]] && awk -F'\t' '{ printf "  %5s %3s %3s  %5s %5s  %-15s %6s  %9s %6s %9s  %14s %7s  %s\n",
                                            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13 }' "$CH_ROWS"
        echo
        printf '  %s\n' "${chain_now:-}"
        printf '  columns: ionic = ionic steps VASP completed in the chunk; geoms = distinct\n'
        printf '  geometries so far (a chunk'"'"'s first step repeats the last one); e-steps/ionic =\n'
        printf '  electronic steps of each ionic step, [n] one cut off after n; est.e = what was\n'
        printf '  estimated for the first; estimate and used h:mm:ss; asked = the walltime h:mm\n'
        printf '  (estimate x %s + %s min); max|F| over all atoms.\n' "${chain_safety:-?}" "${chain_margin_min:-?}"
    } > "$tmp" && mv -f "$tmp" "$PROGRESS"
}

# The largest |F| on any atom in the last TOTAL-FORCE block.
outcar_fmax(){
    awk '/TOTAL-FORCE/{inb=1;st=0;cmax=0;next}
         inb&&/^[[:space:]]*-+[[:space:]]*$/{if(!st){st=1;next}else{fm=cmax;inb=0;st=0;next}}
         inb&&st{m=sqrt($4*$4+$5*$5+$6*$6); if(m>cmax)cmax=m}
         END{ if(fm!="") printf "%.4f", fm }' "${1:-OUTCAR}" 2>/dev/null
}
oszicar_energy(){ awk '/F=/{ for (i = 1; i <= NF; i++) if ($i == "F=") e = $(i+1) } END{ if (e != "") printf "%.6f", e }' "${1:-OSZICAR}" 2>/dev/null; }

# ---- staging a chunk's directory ----------------------------------------------
# stage_attempt IDX TRY NSW -> prints the directory
# Its inputs come from the last SUCCESSFUL chunk (or, for chunk 1, from this
# folder) -- never from a failed attempt, whose CONTCAR and WAVECAR may be
# partial.
stage_attempt(){
    local idx="$1" try="$2" nsw="$3" dir src geo
    dir="$CHDIR/$(dname "$idx").try${try}"
    rm -rf "${dir:?}"; mkdir -p "$dir"
    if (( idx == 1 )); then src="."; geo="POSCAR"
    else src="$CHDIR/$(dname $(( idx - 1 )))"; geo="$src/CONTCAR"; fi
    cp -f INCAR "$dir/INCAR"
    if [[ "$(incar_val NSW "$dir/INCAR")" != "$nsw" ]]; then
        wp_incar_set "$dir/INCAR" NSW "$nsw" "chunk ${idx} (vasp-relax-loop)"
    fi
    cp -f KPOINTS "$dir/KPOINTS"
    ln -sf ../../POTCAR "$dir/POTCAR"          # read only; one copy for every chunk
    local f
    for f in "${EXTRA_INPUTS[@]}"; do [[ -e $f ]] && cp -f "$f" "$dir/"; done
    cp -f "$geo" "$dir/POSCAR"
    if [[ ${chain_carry:-0} == 1 ]] && (( idx > 1 )); then
        for f in WAVECAR CHGCAR; do [[ -s "$src/$f" ]] && cp -f "$src/$f" "$dir/$f"; done
    fi
    echo "$dir"
}

# ---- rendering the chunk job ---------------------------------------------------
# rewrite_time MINUTES: the --time line of the job, in place.
rewrite_time(){
    local tt tmp="$CH_JOB.new"
    tt=$(printf '%02d:%02d:00' $(( $1 / 60 )) $(( $1 % 60 )))
    awk -v t="$tt" '/^#SBATCH --time=/{ print "#SBATCH --time=" t; next } { print }' "$CH_JOB" > "$tmp" \
        && mv -f "$tmp" "$CH_JOB" && chmod +x "$CH_JOB"
}
render_job(){   # render_job PART NODES RANKS NTPN EXACT MEMCPU WALL_MIN
    local part="$1" nodes="$2" ranks="$3" ntpn="$4" exact="$5" mem="$6" wall="$7" self
    self=$(readlink -f "${BASH_SOURCE[0]}")
    {
        echo "#!/bin/bash"
        echo "#SBATCH --job-name=vasp-relax-loop"
        echo "#SBATCH --partition=${part}"
        echo "#SBATCH --nodes=${nodes}"
        echo "#SBATCH --ntasks=${ranks}"
        if (( exact == 1 && nodes * ntpn == ranks )); then
            echo "#SBATCH --ntasks-per-node=${ntpn}"
        else
            echo "# no --ntasks-per-node: ${ranks} ranks do not divide evenly over ${nodes} node(s)"
        fi
        echo "#SBATCH --cpus-per-task=1"
        echo "#SBATCH --mem-per-cpu=${mem}"
        echo "#SBATCH --time=$(printf '%02d:%02d:00' $(( wall / 60 )) $(( wall % 60 )))"
        echo "#SBATCH --output=VASP-chain-%j.out"
        echo "#SBATCH --error=VASP-chain-%j.err"
        echo "#SBATCH --no-requeue"
        # A catchable warning before the walltime kill, so a chunk that runs
        # out of time can still file itself and submit its retry.
        echo "#SBATCH --signal=B:USR1@${SIGNAL_LEAD}"
        [[ -n "${WP_EMAIL:-}" ]] && { echo "#SBATCH --mail-user=${WP_EMAIL}"; echo "#SBATCH --mail-type=FAIL"; }
        echo ""
        echo "# Generated by vasp-relax-loop on $(date -Iseconds). Submitted once per chunk;"
        echo "# each chunk rewrites --time and the memory lines for the next one."
        echo 'cd "$SLURM_SUBMIT_DIR" || exit 1'
        if [[ -n "${WP_VASP_MODULES:-}" ]]; then
            [[ "${WP_MODULE_PURGE:-1}" == "1" ]] && echo "${WP_MODULE_CMD:-ml} purge"
            echo "${WP_MODULE_CMD:-ml} ${WP_VASP_MODULES}"
        fi
        echo "export OMP_NUM_THREADS=1"
        echo "export MKL_NUM_THREADS=1"
        [[ -n "${WP_EXTRA_ENV:-}" ]] && echo "${WP_EXTRA_ENV}"
        echo ""
        # The cluster profile staged beside the chain: a compute node may not
        # see $HOME (Santos Dumont's /prj).
        echo "_wp_staged=\"\$SLURM_SUBMIT_DIR/${CHDIR}/cluster.conf\""
        echo '[[ -f "$_wp_staged" ]] && export WOLFPACK_CLUSTER_CONF="$_wp_staged"'
        echo ""
        # Through bash, so the job does not depend on the file's execute bit.
        echo "exec bash '${self}' --chunk-body"
    } > "$CH_JOB"
    chmod +x "$CH_JOB"
}

submit(){   # submit -> sets JID; returns 1 on failure (message in SUBMIT_OUT)
    SUBMIT_OUT=$(sbatch "$CH_JOB" 2>&1) || return 1
    JID="${SUBMIT_OUT##* }"
    echo "$JID" > "$CH_RUN"
    state_set jobids "${jobids:-} ${JID}"
    return 0
}

# stop_chain REASON DETAIL [ADVICE] -- the chain ends here
stop_chain(){
    state_set chain_state stopped stop_reason "$1" chain_now "stopped: $1 -- $2"
    rm -f "$CH_RUN"
    {
        echo "stopped on $(date -Iseconds)"
        echo "reason : $1"
        echo "detail : $2"
        echo
        [[ -n "${3:-}" ]] && echo "$3"
        echo "Diagnose with: vasp-diagnose   (in ${cur_dir:-the directory of the last chunk})"
    } > "$CH_DEAD"
    progress_write
    warn "chain stopped: $1 -- $2"
    note "see $PROGRESS and $CH_DEAD"
}

# ---- walltime of an attempt --------------------------------------------------
# est_to_wall EST_S -> minutes, within MaxTime when there is one (empty if not)
est_to_wall(){ st_walltime_min "$1" "${chain_safety:-1.15}" "${chain_margin_min:-5}"; }

###############################################################################
# STATUS / STOP
###############################################################################
if [[ $ACTION == status ]]; then
    [[ -f "$CH_ENV" ]] || die "no chain here ($CH_ENV not found)." 3
    state_load
    [[ -f $PROGRESS ]] && cat "$PROGRESS" || progress_write
    exit 0
fi
if [[ $ACTION == stop ]]; then
    [[ -f "$CH_ENV" ]] || die "no chain here ($CH_ENV not found)." 3
    state_load
    printf 'stopped by %s at %s\n' "${USER:-?}" "$(date -Iseconds)" > "$CH_STOP"
    say "STOP requested: the running chunk finishes and no further chunk is submitted."
    if (( STOP_NOW )) && [[ -n "${cur_dir:-}" && -d "${cur_dir}" ]]; then
        # VASP's own clean stop: it finishes the ionic step it is in and exits,
        # with a consistent CONTCAR.
        printf 'LSTOP = .TRUE.\n' > "$cur_dir/STOPCAR"
        say "STOPCAR (LSTOP) written in ${cur_dir}: VASP ends after its current ionic step."
    fi
    note "Continue later with: ${CMD} --resume"
    exit 0
fi

_wp_require WP_MAIN_PARTITION WP_MAIN_CPUS_PER_NODE WP_MAIN_MEM_PER_NODE_MB WP_VASP_STD

###############################################################################
# THE CHUNK BODY -- inside the SLURM job
###############################################################################
if [[ $ACTION == chunk ]]; then
    state_load
    idx=$(int "${cur_chunk:-1}"); try=$(int "${cur_try:-1}"); nsw=$(int "${cur_nsw:-2}")
    dir="${cur_dir:?no current chunk directory in the state}"
    jid="${SLURM_JOB_ID:-?}"
    say "chunk ${idx}, try ${try}: NSW=${nsw} in ${dir} (job ${jid})"
    # The previous attempt's job logs, from this folder into its directory.
    if [[ -n "${prev_dir:-}" && -d "${prev_dir}" ]]; then
        for f in VASP-chain-*.out VASP-chain-*.err; do
            [[ -e $f ]] || continue
            case "$f" in *"-${jid}."*) continue ;; esac
            mv -f "$f" "$prev_dir/" 2>/dev/null
        done
    fi
    rm -f "$dir/STOPCAR"
    state_set chain_now "running: chunk ${idx}, try ${try}, job ${jid}, asked $(fmt_min "$(int "${cur_wall_min:-0}")")"
    progress_write

    _hit_walltime=0; _vpid=""
    # The walltime is near: stop VASP (srun ends its tasks on SIGTERM), so the
    # time left goes to filing this attempt and submitting its retry.
    _on_warning(){ _hit_walltime=1
        [[ -n $_vpid ]] || return 0
        pkill -TERM -P "$_vpid" 2>/dev/null; kill -TERM "$_vpid" 2>/dev/null; }
    trap _on_warning USR1
    t0=$(date +%s)
    ( cd "$dir" && exec /usr/bin/time -v srun --cpu-bind=cores "${chain_exe:-vasp_std}" ) &
    _vpid=$!
    wait "$_vpid"; rc=$?
    # A trapped signal makes `wait` return early; keep waiting for the real exit.
    while kill -0 "$_vpid" 2>/dev/null; do wait "$_vpid"; rc=$?; done
    wall_s=$(( $(date +%s) - t0 ))

    # ---- what the attempt did ------------------------------------------------
    footer=0; grep -qa 'General timing and accounting' "$dir/OUTCAR" 2>/dev/null && footer=1
    reached=0; grep -qa 'reached required accuracy' "$dir/OUTCAR" 2>/dev/null && reached=1
    ionic=$(grep -c 'LOOP+:' "$dir/OUTCAR" 2>/dev/null); ionic=$(int "$ionic")
    _fc=$(grep -c 'F=' "$dir/OSZICAR" 2>/dev/null); _fc=$(int "$_fc")
    (( _fc < ionic )) && ionic=$_fc
    # electronic steps of each ionic step; "[n]" for one cut off after n
    nel=$(awk '/^[ \t]*[A-Za-z]+[ \t]*:[ \t]+[0-9]+[ \t]/{ n++; next } /F=/{ printf "%s%d", (o++ ? " " : ""), n; n = 0 }
               END{ if (n > 0) printf "%s[%d]", (o ? " " : ""), n }' "$dir/OSZICAR" 2>/dev/null)
    energy=$(oszicar_energy "$dir/OSZICAR"); fmax=$(outcar_fmax "$dir/OUTCAR")
    # The time used: the job's own clock, or VASP's (every ionic step, and the
    # electronic steps of one cut off) when that is more.
    vasp_s=$(awk '/LOOP:/{ k = split($0, a, "real time"); if (k > 1) o += a[2] }
                  /LOOP\+:/{ k = split($0, a, "real time"); if (k > 1) s += a[2]; o = 0 }
                  END{ printf "%.0f", s + o }' "$dir/OUTCAR" 2>/dev/null)
    used_s=$(( wall_s > $(int "${vasp_s:-0}") ? wall_s : $(int "${vasp_s:-0}") ))

    _poll=$SACCT_POLL_S; (( _hit_walltime )) && _poll=5
    read -r mem_state mem_max mem_ave < <(job_mem_evidence "${SLURM_JOB_ID:-}" "$_poll")
    mem_max=$(int "${mem_max:-0}"); mem_ave=$(int "${mem_ave:-0}"); mem_src="sacct"
    if (( mem_max <= 0 )); then
        mem_max=$(int "$(outcar_maxmem_mb "$dir/OUTCAR")"); mem_ave=0; mem_src="OUTCAR (rank 0)"
    fi
    mem_granted=$(int "${SLURM_MEM_PER_CPU:-${chain_mem_per_cpu:-0}}")
    if (( mem_max > 0 )); then
        _pk=$(( mem_max > $(int "${mem_peak_max_mb:-0}") ? mem_max : $(int "${mem_peak_max_mb:-0}") ))
        _av=$(( mem_ave > $(int "${mem_ave_max_mb:-0}") ? mem_ave : $(int "${mem_ave_max_mb:-0}") ))
        state_set mem_peak_max_mb "$_pk" mem_ave_max_mb "$_av" last_mem_src "$mem_src"
    fi

    # ---- how it ended ----------------------------------------------------------
    user_stop=0; [[ -f $CH_STOP ]] && user_stop=1
    outcome="failed"
    if (( footer && rc == 0 )) && { (( ionic >= nsw )) || (( reached )); }; then
        outcome="ok"
    elif (( footer && user_stop && ionic >= 1 )); then
        outcome="ok"                                   # --stop --now: LSTOP ended it early
    elif [[ ${mem_state:-} == OUT_OF_MEMORY ]] || err_mentions "$jid" "$OOM_RX"; then
        outcome="oom"
    elif (( _hit_walltime )) || [[ ${mem_state:-} == TIMEOUT ]] || err_mentions "$jid" "$TIMEOUT_RX"; then
        outcome="timeout"
    fi

    _asked=$(fmt_min "$(int "${cur_wall_min:-0}")")
    _row_common=("$idx" "$try" "$nsw" "$ionic")

    if [[ $outcome == ok ]]; then
        # ---- a completed chunk ---------------------------------------------------
        if ! _why=$(contcar_ok "$dir/CONTCAR" "$dir/POSCAR"); then
            row_add "${_row_common[@]}" "${geoms_done:-0}" "${nel:--}" "${cur_nel_est:--}" "$(fmt_s "${cur_est_s:-0}")" "$_asked" \
                    "$(fmt_s "$used_s")" "${energy:--}" "${fmax:--}" "CONTCAR unusable"
            stop_chain bad_contcar "the chunk finished but its CONTCAR is unusable (${_why})" \
                "Nothing was advanced; the last good geometry is in $CHDIR/$(dname $(( idx - 1 )))."
            exit 1
        fi
        final="$CHDIR/$(dname "$idx")"
        rm -rf "${final:?}"; mv -f "$dir" "$final"; dir="$final"
        # Distinct geometries: a chunk's first step repeats where the last ended.
        _new=$ionic; (( idx > 1 && _new > 0 )) && _new=$(( _new - 1 ))
        geoms=$(( $(int "${geoms_done:-0}") + _new ))
        # The latest results, where the user and vasp-check look for them.
        for f in CONTCAR OUTCAR OSZICAR vasprun.xml; do
            [[ -s "$dir/$f" ]] && cp -f "$dir/$f" "./$f.new" && mv -f "./$f.new" "./$f"
        done
        # Only the latest completed chunk keeps its WAVECAR and CHGCAR.
        if (( idx > 1 )); then
            rm -f "$CHDIR/$(dname $(( idx - 1 )))"/{WAVECAR,CHGCAR,CHG} 2>/dev/null
        fi
        row_add "${_row_common[@]}" "$geoms" "${nel:--}" "${cur_nel_est:--}" "$(fmt_s "${cur_est_s:-0}")" "$_asked" \
                "$(fmt_s "$used_s")" "${energy:--}" "${fmax:--}" "$( (( reached )) && echo CONVERGED || echo ok )"
        # What the next chunk's estimate rests on.
        eval "$(st_estimate next "$dir/OUTCAR" "$dir/OSZICAR" 2 "$wall_s" | grep -E '^(startup_s|t1_s|tr_s)=')"
        state_set chunk_ok "$idx" geoms_done "$geoms" scf_total "$(( $(int "${scf_total:-0}") + ionic ))" \
                  last_startup_s "$startup_s" last_t1_s "$t1_s" last_tr_s "$tr_s" \
                  last_wall_s "$wall_s" prev_dir "$dir"

        if (( reached )); then
            state_set chain_state converged stop_reason "" \
                      chain_now "CONVERGED at chunk ${idx}: reached required accuracy (EDIFFG ${chain_ediffg}), ${geoms} geometries"
            rm -f "$CH_RUN"
            echo "converged at chunk ${idx} on $(date -Iseconds); ${geoms} geometries" > "$CH_DONE"
            progress_write
            { printf '\n#  vasp-relax-loop -- converged, %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"; cat "$PROGRESS"; } >> report.out 2>/dev/null
            say "CONVERGED after ${idx} chunk(s), ${geoms} geometries."
            scontrol update "JobId=${SLURM_JOB_ID:-0}" MailType=END,FAIL >/dev/null 2>&1
            exit 0
        fi
        if (( user_stop )); then
            stop_chain user "stop requested; chunk ${idx} completed" "Continue with: ${CMD} --resume"
            exit 0
        fi
        nidx=$(( idx + 1 ))
        nnsw=$(nsw_of "$nidx")
        if (( nnsw == 0 )); then
            stop_chain steps_done "the --steps list (${chain_steps}) is used up after chunk ${idx}, not converged" \
                "Continue with more steps:  ${CMD} --resume --steps N,N,..."
            exit 0
        fi
        _left=$(( $(int "${chain_max_ionic:-100}") - geoms ))
        if (( _left <= 0 )); then
            stop_chain max_ionic "${geoms} geometries computed (--max-ionic ${chain_max_ionic}), not converged" \
                "Continue with a higher limit:  ${CMD} --resume --max-ionic N"
            exit 0
        fi
        (( nnsw - 1 > _left )) && nnsw=$(( _left + 1 ))
        eval "$(st_estimate next "$dir/OUTCAR" "$dir/OSZICAR" "$nnsw" "$wall_s" | grep -E '^(est_s|nel_first)=')"
        nwall=$(est_to_wall "$est_s")
        if [[ -n ${chain_maxtime:-} ]] && (( nwall > $(int "$chain_maxtime") )); then
            stop_chain step_exceeds_maxtime "chunk ${nidx} needs ${nwall} min, above the partition's MaxTime of ${chain_maxtime} min" \
                "Fewer steps per chunk (--steps / NSW), or more ranks for a faster step. POSCAR of chunk ${nidx} would be $dir/CONTCAR."
            exit 0
        fi
        # memory for the next chunk, from what this one used
        if (( mem_max > 0 )); then
            if ! settle_memory "$(int "${mem_peak_max_mb:-0}")" "$(int "${mem_ave_max_mb:-0}")" \
                               "$(int "${chain_ranks:-1}")" "$(int "${chain_ntpn:-1}")" 1 0; then
                stop_chain memory_does_not_fit "the next chunk needs ${SM_NEED} MB/cpu: ${SM_WHY}"
                exit 0
            fi
            rewrite_allocation "$SM_NEED" "$SM_NODES" "$SM_NTPN" "$SM_EXACT" "$(int "${chain_ranks:-1}")"
            state_set chain_mem_per_cpu "$SM_NEED" chain_nodes "$SM_NODES" chain_ntpn "$SM_NTPN" chain_ntpn_exact "$SM_EXACT"
        fi
        ndir=$(stage_attempt "$nidx" 1 "$nnsw")
        rewrite_time "$nwall"
        state_set cur_chunk "$nidx" cur_try 1 cur_nsw "$nnsw" cur_dir "$ndir" cur_wall_min "$nwall" \
                  cur_est_s "$est_s" cur_nel_est "${nel_first:-}" chain_state running
        if submit; then
            state_set chain_now "queued: chunk ${nidx} (NSW ${nnsw}), job ${JID}, asks $(fmt_min "$nwall") (estimate $(fmt_s "$est_s") from chunk ${idx})"
            progress_write
            say "chunk ${idx} done (${ionic} ionic steps, ${geoms} geometries); chunk ${nidx} submitted: ${SUBMIT_OUT}"
            exit 0
        fi
        stop_chain sbatch_failed "$SUBMIT_OUT" "Continue with: ${CMD} --resume"
        exit 1
    fi

    # ---- a failed attempt ------------------------------------------------------
    # Its files stay, for diagnosis; the restart files it may have left half
    # written go, so nothing can pick them up by mistake.
    rm -f "$dir"/{WAVECAR,CHGCAR,CHG} 2>/dev/null
    printf 'outcome=%s rc=%s footer=%s ionic=%s wall_s=%s job=%s\n' "$outcome" "$rc" "$footer" "$ionic" "$wall_s" "$jid" > "$dir/ATTEMPT"
    _label=$(tr '[:lower:]' '[:upper:]' <<<"$outcome")
    row_add "${_row_common[@]}" "${geoms_done:-0}" "${nel:--}" "${cur_nel_est:--}" "$(fmt_s "${cur_est_s:-0}")" "$_asked" \
            "$(fmt_s "$used_s")" "-" "-" "$_label"
    state_set prev_dir "$dir"

    if [[ $outcome == failed ]]; then
        stop_chain failed "VASP ended without completing the chunk (rc=${rc}, ${ionic}/${nsw} ionic steps, footer=${footer})" \
            "Look at ${dir}/ and its VASP-chain-${jid}.err. Then:  ${CMD} --resume  (a new, clean attempt)"
        exit 1
    fi
    if (( user_stop )); then
        stop_chain user "stop requested; chunk ${idx} try ${try} did not complete (${outcome})" "Continue with: ${CMD} --resume"
        exit 0
    fi
    if (( try > $(int "${chain_max_retries:-2}") )); then
        stop_chain retries_exhausted "chunk ${idx} failed ${try} time(s), the last by ${outcome}" \
            "Continue with: ${CMD} --resume  (one more attempt; --max-retries raises the limit)"
        exit 1
    fi
    ntry=$(( try + 1 ))
    nwall=$(int "${cur_wall_min:-0}")
    if [[ $outcome == timeout ]]; then
        eval "$(st_estimate retry "$dir/OUTCAR" "$dir/OSZICAR" "$nsw" "${last_startup_s:-${chain_test_startup_s:-0}}" \
                "${last_tr_s:-0}" | grep -E '^(est_s|nel_first)=')"
        nwall=$(est_to_wall "$est_s")
        _floor=$(awk -v w="${cur_wall_min:-0}" -v f="$RETRY_WALL_FACTOR" 'BEGIN{ v = w * f; printf "%d", (v == int(v)) ? v : int(v) + 1 }')
        (( nwall < _floor )) && nwall=$_floor
        if [[ -n ${chain_maxtime:-} ]] && (( nwall > $(int "$chain_maxtime") )); then
            if (( $(int "${cur_wall_min:-0}") >= $(int "$chain_maxtime") )); then
                stop_chain step_exceeds_maxtime "chunk ${idx} ran out of the partition's whole MaxTime (${chain_maxtime} min)" \
                    "Fewer steps per chunk (--steps / NSW), or more ranks for a faster step."
                exit 1
            fi
            nwall=$(int "$chain_maxtime")
        fi
    else
        _granted=$(int "${chain_mem_per_cpu:-$mem_granted}")
        _esc=$(awk -v g="$_granted" -v f="$OOM_FACTOR" 'BEGIN{ printf "%d", int((g*f + 49)/50)*50 }')
        if ! settle_memory "$(int "${mem_peak_max_mb:-0}")" "$(int "${mem_ave_max_mb:-0}")" \
                           "$(int "${chain_ranks:-1}")" "$(int "${chain_ntpn:-1}")" 1 "$_esc"; then
            stop_chain memory_does_not_fit "after an OOM kill at ${_granted} MB/cpu the chunk needs ${SM_NEED}: ${SM_WHY}"
            exit 1
        fi
        rewrite_allocation "$SM_NEED" "$SM_NODES" "$SM_NTPN" "$SM_EXACT" "$(int "${chain_ranks:-1}")"
        state_set chain_mem_per_cpu "$SM_NEED" chain_nodes "$SM_NODES" chain_ntpn "$SM_NTPN" \
                  chain_ntpn_exact "$SM_EXACT" oom_count "$(( $(int "${oom_count:-0}") + 1 ))"
        est_s="${cur_est_s:-0}"; nel_first="${cur_nel_est:-}"
    fi
    ndir=$(stage_attempt "$idx" "$ntry" "$nsw")
    rewrite_time "$nwall"
    state_set cur_try "$ntry" cur_dir "$ndir" cur_wall_min "$nwall" cur_est_s "$est_s" \
              cur_nel_est "${nel_first:-}" retries_used "$(( $(int "${retries_used:-0}") + 1 ))"
    if submit; then
        state_set chain_now "queued: chunk ${idx} try ${ntry} after ${outcome}, job ${JID}, asks $(fmt_min "$nwall")"
        progress_write
        say "chunk ${idx} try ${try}: ${outcome}. Try ${ntry} submitted (${nwall} min): ${SUBMIT_OUT}"
        exit 0
    fi
    stop_chain sbatch_failed "$SUBMIT_OUT" "Continue with: ${CMD} --resume"
    exit 1
fi

###############################################################################
# THE LAUNCHER -- start, --resume, --fresh (login node)
###############################################################################
[[ -n "${SLURM_JOB_ID:-}" ]] && die "this is the launcher; inside a job it runs as --chunk-body." 2
hdr "Chunked relaxation -- setup"
[[ -s INCAR ]] || die "no INCAR here -- run this in a VASP calculation folder." 2
for f in POSCAR POTCAR KPOINTS; do [[ -s $f ]] || die "no ${f} here." 2; done
SRC_SLURM="slurm_vasptest.sh"
[[ -f $SRC_SLURM ]] || die "no ${SRC_SLURM} here. Run the pipeline first:
     vasp-dry-run  ->  vasp-recommend-slurm  ->  vasp-test --full-size" 3
sb_num(){ grep -m1 -oiE -- "--$1=[0-9]+" "$SRC_SLURM" | grep -oE '[0-9]+'; }
sb_str(){ grep -m1 -oiE -- "--$1=[^[:space:]]+" "$SRC_SLURM" | sed -E 's/.*=//'; }

# ---- an earlier chain ------------------------------------------------------------
if [[ -f "$CH_ENV" ]]; then
    state_load
    _jid=$(tr -dc '0-9' 2>/dev/null < "$CH_RUN")
    if [[ -n $_jid ]] && [[ -n "$(squeue -h -j "$_jid" 2>/dev/null)" ]]; then
        die "a chunk of this chain is queued or running (job ${_jid}). Use --status, or --stop first." 3
    fi
    if [[ $ACTION == start ]]; then
        if [[ ${chain_state:-} == converged ]] || (( OPT_FRESH )); then
            _arch="${CHDIR}.prev-$(date +%Y%m%d-%H%M%S)"
            mv "$CHDIR" "$_arch"
            [[ -f $PROGRESS ]] && mv -f "$PROGRESS" "$_arch/"
            while IFS='=' read -r _k _; do [[ $_k =~ ^[a-z_][a-z0-9_]*$ ]] && unset "$_k"; done < "$_arch/chain.env"
            note "the previous chain was archived to ${_arch}/ -- this is a NEW chain."
        else
            die "an unfinished chain is here (${chain_state:-?}${stop_reason:+: ${stop_reason}}).
   Continue it:        ${CMD} --resume
   Or start over:      ${CMD} --fresh     (the old chain is archived, not deleted)" 3
        fi
    fi
elif [[ $ACTION == resume ]]; then
    die "nothing to resume: there is no chain here." 3
fi
rm -f "$CH_STOP"

# ---- options -----------------------------------------------------------------------
[[ -z $OPT_NSW ]] || posint "$OPT_NSW" || die "--nsw takes a whole number, not '${OPT_NSW}'." 2
[[ -z $OPT_MAXION ]] || posint "$OPT_MAXION" || die "--max-ionic takes a whole number, not '${OPT_MAXION}'." 2
[[ -z $OPT_RETRIES ]] || [[ $OPT_RETRIES =~ ^[0-9]+$ ]] || die "--max-retries takes a whole number, not '${OPT_RETRIES}'." 2
[[ -z $OPT_SAFETY ]] || { posnum "$OPT_SAFETY" && awk -v v="$OPT_SAFETY" 'BEGIN{exit !(v>=1)}'; } \
    || die "--safety takes a factor of at least 1, not '${OPT_SAFETY}'." 2
[[ -z $OPT_MARGIN ]] || { posint "$OPT_MARGIN" && (( OPT_MARGIN >= 3 )); } \
    || die "--margin-min takes whole minutes, at least 3 (the job is warned ${SIGNAL_LEAD} s before its walltime), not '${OPT_MARGIN}'." 2
if [[ -n $OPT_STEPS ]]; then
    [[ $OPT_STEPS =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--steps takes a comma-separated list of whole numbers, e.g. 2,5,7 -- not '${OPT_STEPS}'." 2
fi

# ---- the INCAR: what the chain can and cannot run --------------------------------
_ib=$(incar_val IBRION)
case "$_ib" in
    1|2|3) ;;
    "") die "the INCAR sets no IBRION. With NSW > 0 VASP's default is IBRION = 0, molecular dynamics
   (vasp.at/wiki/index.php/IBRION), which this chain does not run. Set IBRION = 1, 2 or 3." 2 ;;
    *)  die "IBRION = ${_ib}: vasp-relax-loop runs relaxations, IBRION = 1, 2 or 3." 2 ;;
esac
_eg=$(incar_val EDIFFG)
if [[ -z $_eg ]] || ! awk -v g="$_eg" 'BEGIN{exit !(g+0 < 0)}'; then
    die "EDIFFG must be negative (a force criterion); the INCAR has ${_eg:-none, so VASP uses EDIFF x 10 > 0}.
   A positive EDIFFG stops on the energy change between two ionic steps of ONE
   run (vasp.at/wiki/index.php/EDIFFG). Each chunk is a separate run, so VASP
   could never apply it across chunks. Set, e.g., EDIFFG = -0.01." 2
fi
_nsw_incar=$(incar_val NSW)
_why_nsw1="With NSW = 1 VASP computes the forces and does not move the ions: its CONTCAR is
   the last geometry it COMPUTED (checked with VASP 6.5.1, IBRION 1, 2 and 3), so a
   chain of NSW = 1 chunks would compute the same geometry forever."
if [[ $ACTION == start || -n $OPT_STEPS || -n $OPT_NSW ]]; then
    if [[ -n $OPT_STEPS ]]; then
        for _n in ${OPT_STEPS//,/ }; do
            (( 10#$_n >= 2 )) || die "--steps ${OPT_STEPS}: every chunk needs NSW >= 2.
   ${_why_nsw1}" 2
        done
        chain_steps="$OPT_STEPS"; chain_nsw=0; chain_nsw_words="--steps ${OPT_STEPS}"
    elif [[ -n $_nsw_incar ]]; then
        (( 10#$(int "$_nsw_incar") >= 2 )) || die "the INCAR has NSW = ${_nsw_incar}; every chunk needs NSW >= 2.
   ${_why_nsw1}" 2
        [[ -n $OPT_NSW ]] && warn "--nsw ${OPT_NSW} is ignored: the INCAR sets NSW = ${_nsw_incar}."
        chain_steps=""; chain_nsw=$(int "$_nsw_incar"); chain_nsw_words="${chain_nsw} (INCAR)"
    else
        chain_nsw=$(int "${OPT_NSW:-2}")
        (( chain_nsw >= 2 )) || die "--nsw ${chain_nsw}: every chunk needs NSW >= 2.
   ${_why_nsw1}" 2
        chain_steps=""; chain_nsw_words="${chain_nsw} (--nsw; the INCAR has none)"
    fi
fi
_lw=$(incar_val LWAVE)
_carry="${OPT_CARRY:-${chain_carry:-0}}"
if [[ $_carry == 1 ]] && [[ ${_lw^^} == *F* ]]; then
    die "--carry-wavecar needs the WAVECAR, and the INCAR sets LWAVE = ${_lw}." 2
fi

# ---- the job, and vasp-test's measurements ---------------------------------------
RANKS=$(int "$(sb_num ntasks)"); NODES=$(int "$(sb_num nodes)"); (( NODES < 1 )) && NODES=1
NTPN=$(sb_num ntasks-per-node)
if [[ -z $NTPN ]]; then NTPN=$(( (RANKS + NODES - 1) / NODES )); NTPN_EXACT=0
else NTPN=$(int "$NTPN"); NTPN_EXACT=1; fi
MEMCPU=$(int "$(sb_num mem-per-cpu)")
PART=$(sb_str partition); PART="${PART:-${WP_MAIN_PARTITION}}"
EXE=$(grep -m1 -E '^/usr/bin/time -v srun ' "$SRC_SLURM" 2>/dev/null | awk '{print $NF}')
EXE="${EXE:-${WP_VASP_STD}}"
(( RANKS > 0 ))  || die "${SRC_SLURM} has no --ntasks." 3
(( MEMCPU > 0 )) || die "${SRC_SLURM} has no --mem-per-cpu." 3

# shellcheck source=/dev/null
[[ -f .wolfpack/state.env ]] && source .wolfpack/state.env
T_OUT=".wolfpack/vasptest_OUTCAR"; T_OSZ=".wolfpack/vasptest_OSZICAR"
if [[ $ACTION == start ]]; then
    [[ -s $T_OUT && -s $T_OSZ ]] || die "vasp-test's OUTCAR and OSZICAR are not in .wolfpack/.
   Run  vasp-test --full-size  here: the first chunk's walltime is estimated from them." 3
    if (( $(int "${test_ranks:-0}") != RANKS )); then
        die "vasp-test measured ${test_ranks:-?} ranks; this job runs ${RANKS}.
   The first chunk's walltime is estimated from those timings, so they must be the
   production job's own. Run:   vasp-test --full-size" 3
    fi
    [[ -n "${test_partition:-}" && "${test_partition}" != "$PART" ]] && \
        note "vasp-test ran on '${test_partition}', the chunks run on '${PART}': chunk 1's estimate assumes the same speed."
fi

# The node the chunks land on (fit_layout reads these from the state).
if [[ $PART == "${WP_DEBUG_PARTITION:-}" && $PART != "${WP_MAIN_PARTITION:-}" ]]; then
    NODE_MEM=$(int "${WP_DEBUG_MEM_PER_NODE_MB:-0}"); NODE_CPN=$(int "${WP_DEBUG_CPUS_PER_NODE:-1}")
    NODE_MARGIN="${WP_DEBUG_MEM_MARGIN:-0.05}"
else
    NODE_MEM=$(int "${WP_MAIN_MEM_PER_NODE_MB:-0}"); NODE_CPN=$(int "${WP_MAIN_CPUS_PER_NODE:-1}")
    NODE_MARGIN="${WP_MAIN_MEM_MARGIN:-0.02}"
fi
MAXT=$(part_maxtime_min "$PART")

###############################################################################
# START
###############################################################################
if [[ $ACTION == start ]]; then
    chain_safety="${OPT_SAFETY:-1.15}"; chain_margin_min="${OPT_MARGIN:-5}"
    chain_max_ionic="${OPT_MAXION:-100}"; chain_max_retries="${OPT_RETRIES:-2}"
    chain_carry="$_carry"; chain_maxtime="$MAXT"; chain_ediffg="$_eg"
    nsw1=$(nsw_of 1)
    _left=$(int "$chain_max_ionic"); (( nsw1 > _left )) && nsw1=$(( _left > 1 ? _left : 2 ))
    eval "$(st_estimate first "$T_OUT" "$T_OSZ" "$nsw1" "${test_startup_s:-0}" \
            | grep -E '^(est_s|t1_s|t1_basis|tr_s|tr_basis|startup_s|nel_first|t_e)=')"
    awk -v e="$est_s" 'BEGIN{exit !(e>0)}' || die "vasp-test's OUTCAR has no timed electronic step to estimate from. Re-run vasp-test --full-size." 3
    WALL=$(est_to_wall "$est_s")
    if [[ -n $MAXT ]] && (( WALL > MAXT )); then
        die "chunk 1 (NSW = ${nsw1}) is estimated at ${WALL} min, above the partition's MaxTime of ${MAXT} min.
   Fewer ionic steps per chunk (NSW, --steps), or more ranks for a faster step." 2
    fi

    kv "partition"          "${PART}$( [[ -n $MAXT ]] && echo "  (MaxTime ${MAXT} min)" )"
    kv "job"                "${NODES} node(s) x ${NTPN} ranks, ${MEMCPU} MB/cpu  (${SRC_SLURM})"
    kv "NSW per chunk"      "$chain_nsw_words"
    kv "stop after"         "${chain_max_ionic} geometries, or VASP's 'reached required accuracy' (EDIFFG ${_eg})"
    kv "WAVECAR carried"    "$( [[ $chain_carry == 1 ]] && echo yes || echo 'no (--carry-wavecar to carry it)' )"
    kv "electronic step"    "${t_e} s  (median of vasp-test's, at ${RANKS} ranks)"
    kv "first ionic step"   "${t1_s} s: ${t1_basis}"
    (( nsw1 > 1 )) && kv "later ionic steps" "${tr_s} s: ${tr_basis}"
    kv "start-up"           "${startup_s} s  (vasp-test)"
    kv "chunk 1"            "NSW = ${nsw1}: estimate $(fmt_s "$est_s") -> asks ${WALL} min (x ${chain_safety} + ${chain_margin_min} min)"

    mkdir -p "$CHDIR"; : > "$CH_ROWS"
    [[ -f "$_wp_conf" ]] && cp -f "$_wp_conf" "$CHDIR/cluster.conf"
    render_job "$PART" "$NODES" "$RANKS" "$NTPN" "$NTPN_EXACT" "$MEMCPU" "$WALL"
    rm -f "$CH_DONE" "$CH_DEAD"
    state_set chain_kind relax chain_state running stop_reason "" chain_started "$(date -Iseconds)" \
              chain_exe "$EXE" chain_ranks "$RANKS" chain_partition "$PART" \
              chain_nsw "$chain_nsw" chain_steps "$chain_steps" chain_nsw_words "$chain_nsw_words" \
              chain_max_ionic "$chain_max_ionic" chain_max_retries "$chain_max_retries" \
              chain_carry "$chain_carry" chain_safety "$chain_safety" chain_margin_min "$chain_margin_min" \
              chain_maxtime "$MAXT" chain_ediffg "$_eg" chain_test_startup_s "$startup_s" \
              chain_mem_per_cpu "$MEMCPU" chain_nodes "$NODES" chain_ntpn "$NTPN" chain_ntpn_exact "$NTPN_EXACT" \
              chain_node_mem_mb "$NODE_MEM" chain_mem_margin "$NODE_MARGIN" chain_cpn "$NODE_CPN" \
              chain_max_cores "$(int "${WP_MAX_CORES:-0}")" chain_profile "${WP_ALLOC_PROFILE:-whole-nodes}" \
              chain_nodes0 "$NODES" \
              chunk_ok 0 geoms_done 0 scf_total 0 retries_used 0 oom_count 0 \
              mem_peak_max_mb 0 mem_ave_max_mb 0 prev_dir "" jobids ""
    d1=$(stage_attempt 1 1 "$nsw1")
    state_set cur_chunk 1 cur_try 1 cur_nsw "$nsw1" cur_dir "$d1" cur_wall_min "$WALL" \
              cur_est_s "$est_s" cur_nel_est "${nel_first:-}"
    if submit; then
        state_set chain_now "queued: chunk 1 (NSW ${nsw1}), job ${JID}, asks $(fmt_min "$WALL") (estimate $(fmt_s "$est_s") from vasp-test)"
        progress_write
        echo
        ok "chain started: ${SUBMIT_OUT}"
        note "progress:  ${PROGRESS}   (or ${CMD} --status)"
        note "stop:      ${CMD} --stop"
        exit 0
    fi
    die "sbatch failed: ${SUBMIT_OUT}"
fi

###############################################################################
# RESUME -- a new, clean attempt at the chunk the chain stopped at
###############################################################################
[[ ${chain_state:-} == converged ]] && die "this chain already converged -- see $PROGRESS. Use --fresh to start a new one." 3
# Options given now replace the chain's.
[[ -n $OPT_MAXION ]]  && chain_max_ionic="$OPT_MAXION"
[[ -n $OPT_RETRIES ]] && chain_max_retries="$OPT_RETRIES"
[[ -n $OPT_SAFETY ]]  && chain_safety="$OPT_SAFETY"
[[ -n $OPT_MARGIN ]]  && chain_margin_min="$OPT_MARGIN"
[[ -n $OPT_CARRY ]]   && chain_carry="$OPT_CARRY"
if [[ -n $OPT_STEPS ]]; then
    # a new list, counted from the next chunk
    _pad=$(awk -v n="$(int "${chunk_ok:-0}")" 'BEGIN{ for (i = 1; i <= n; i++) printf "2," }')
    chain_steps="${_pad}${OPT_STEPS}"
fi
last_jid=$(tr -dc '0-9' 2>/dev/null < "$CH_RUN")
[[ -z $last_jid ]] && last_jid=$(printf '%s' "${jobids:-}" | tr -s ' ' '\n' | grep -E '^[0-9]+$' | tail -1)
cause="${stop_reason:-}"
if [[ ${chain_state:-} == running ]]; then
    # The last job died with the chain: nothing filed its attempt. Say how it
    # ended, and file it as failed -- its files are never used.
    read -r _ms _mm _ma < <(job_mem_evidence "$last_jid" 0)
    if [[ ${_ms:-} == OUT_OF_MEMORY ]] || { [[ -n $last_jid ]] && err_mentions "$last_jid" "$OOM_RX"; }; then cause="oom"
    elif [[ ${_ms:-} == TIMEOUT ]] || { [[ -n $last_jid ]] && err_mentions "$last_jid" "$TIMEOUT_RX"; }; then cause="timeout"
    else cause="died (${_ms:-UNKNOWN})"; fi
    if [[ -n ${cur_dir:-} && -d ${cur_dir} ]]; then
        rm -f "$cur_dir"/{WAVECAR,CHGCAR,CHG} 2>/dev/null
        printf 'outcome=%s job=%s (filed by --resume)\n' "$cause" "$last_jid" > "$cur_dir/ATTEMPT"
        for f in "VASP-chain-${last_jid}.out" "VASP-chain-${last_jid}.err"; do [[ -e $f ]] && mv -f "$f" "$cur_dir/"; done
        row_add "${cur_chunk:-?}" "${cur_try:-?}" "${cur_nsw:-?}" "-" "${geoms_done:-0}" "-" "${cur_nel_est:--}" "$(fmt_s "${cur_est_s:-0}")" \
                "$(fmt_min "$(int "${cur_wall_min:-0}")")" "-" "-" "-" "DIED: ${cause}"
    fi
fi
idx=$(( $(int "${chunk_ok:-0}") + 1 ))
nsw=$(nsw_of "$idx")
(( nsw == 0 )) && die "the --steps list is used up. Give more:  ${CMD} --resume --steps N,N,..." 3
_left=$(( $(int "${chain_max_ionic:-100}") - $(int "${geoms_done:-0}") ))
(( _left <= 0 )) && die "${geoms_done} geometries already computed (--max-ionic ${chain_max_ionic}).
   Raise it:  ${CMD} --resume --max-ionic N" 3
(( nsw - 1 > _left )) && nsw=$(( _left + 1 ))
try=1; [[ $(int "${cur_chunk:-0}") == "$idx" ]] && try=$(( $(int "${cur_try:-0}") + 1 ))
WALL=$(int "${cur_wall_min:-0}"); est_s="${cur_est_s:-0}"; nel_first="${cur_nel_est:-}"
case $cause in
    timeout*|retries_exhausted|step_exceeds_maxtime)
        if [[ -n ${cur_dir:-} && -s ${cur_dir}/OUTCAR ]]; then
            eval "$(st_estimate retry "$cur_dir/OUTCAR" "$cur_dir/OSZICAR" "$nsw" \
                    "${last_startup_s:-${chain_test_startup_s:-0}}" "${last_tr_s:-0}" | grep -E '^(est_s|nel_first)=')"
        fi
        WALL=$(est_to_wall "$est_s")
        _fl=$(awk -v w="${cur_wall_min:-0}" -v f="$RETRY_WALL_FACTOR" 'BEGIN{ v = w * f; printf "%d", (v == int(v)) ? v : int(v) + 1 }')
        (( WALL < _fl )) && WALL=$_fl ;;
    oom*)
        _granted=$(int "${chain_mem_per_cpu:-$MEMCPU}")
        _esc=$(awk -v g="$_granted" -v f="$OOM_FACTOR" 'BEGIN{ printf "%d", int((g*f + 49)/50)*50 }')
        settle_memory "$(int "${mem_peak_max_mb:-0}")" "$(int "${mem_ave_max_mb:-0}")" "$(int "${chain_ranks:-$RANKS}")" \
                      "$(int "${chain_ntpn:-$NTPN}")" 1 "$_esc" \
            || die "the memory cannot be raised enough: ${SM_WHY}. A lower KPAR or fewer ranks frees memory; then --fresh." 3
        chain_mem_per_cpu=$SM_NEED; chain_nodes=$SM_NODES; chain_ntpn=$SM_NTPN; chain_ntpn_exact=$SM_EXACT
        ok "memory raised ${_granted} -> ${SM_NEED} MB/cpu" ;;
    *)
        if (( idx != $(int "${cur_chunk:-0}") )) && [[ -n ${last_wall_s:-} ]]; then
            # a clean stop between chunks: the estimate from the last completed one
            eval "$(st_estimate next "$CHDIR/$(dname $(( idx - 1 )))/OUTCAR" "$CHDIR/$(dname $(( idx - 1 )))/OSZICAR" \
                    "$nsw" "$last_wall_s" | grep -E '^(est_s|nel_first)=')"
            WALL=$(est_to_wall "$est_s")
        fi ;;
esac
(( WALL > 0 )) || WALL=$(est_to_wall "${est_s:-0}")
if [[ -n $MAXT ]] && (( WALL > MAXT )); then
    (( $(int "${cur_wall_min:-0}") >= MAXT )) && die "chunk ${idx} needs more than the partition's MaxTime (${MAXT} min).
   Fewer ionic steps per chunk (NSW, --steps), or more ranks." 2
    WALL=$MAXT
fi
[[ -f $CH_DEAD ]] && mv -f "$CH_DEAD" "$CHDIR/STOPPED.$(date +%Y%m%d-%H%M%S)"
rm -f "$CH_RUN"
render_job "${chain_partition:-$PART}" "$(int "${chain_nodes:-$NODES}")" "$(int "${chain_ranks:-$RANKS}")" \
           "$(int "${chain_ntpn:-$NTPN}")" "$(int "${chain_ntpn_exact:-$NTPN_EXACT}")" \
           "$(int "${chain_mem_per_cpu:-$MEMCPU}")" "$WALL"
d=$(stage_attempt "$idx" "$try" "$nsw")
state_set chain_state running stop_reason "" chain_max_ionic "$chain_max_ionic" chain_max_retries "$chain_max_retries" \
          chain_safety "$chain_safety" chain_margin_min "$chain_margin_min" chain_carry "$chain_carry" \
          chain_steps "${chain_steps:-}" chain_mem_per_cpu "${chain_mem_per_cpu:-$MEMCPU}" \
          chain_nodes "${chain_nodes:-$NODES}" chain_ntpn "${chain_ntpn:-$NTPN}" chain_ntpn_exact "${chain_ntpn_exact:-$NTPN_EXACT}" \
          cur_chunk "$idx" cur_try "$try" cur_nsw "$nsw" cur_dir "$d" cur_wall_min "$WALL" \
          cur_est_s "$est_s" cur_nel_est "${nel_first:-}" prev_dir "${cur_dir:-}"
kv "resuming"   "chunk ${idx}, try ${try}${cause:+  (the last one: ${cause})}"
kv "walltime"   "${WALL} min"
if submit; then
    state_set chain_now "queued: chunk ${idx} try ${try} (resumed), job ${JID}, asks $(fmt_min "$WALL")"
    progress_write
    ok "chain resumed: ${SUBMIT_OUT}"
    exit 0
fi
die "sbatch failed: ${SUBMIT_OUT}"
