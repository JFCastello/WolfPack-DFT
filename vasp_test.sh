#!/usr/bin/env bash
###############################################################################
# vasp_test.sh   (invoked on PATH as: vasp-test)
#
# STAGE 3/3 of the pipeline: VALIDATE the recommended config + set final memory.
#
# CLUSTER PROFILE
#   The debug partition name, cores/node, memory/node, notification email and
#   the VASP module(s) to load all come from the profile written by
#   `vasp-configure` (~/.config/wolfpack-dft/cluster.conf). Built-in example
#   defaults are used if no profile exists.
#
# PIPELINE (run these three, in order, with NO arguments and NO manual steps):
#   vasp-dry-run            # STAGE 1: dry run -> .wolfpack/dryrun_OUTCAR
#   vasp-recommend-slurm    # STAGE 2: FIXED KPAR/NCORE/NSIM + ranks -> slurm.sh
#   vasp-test               # STAGE 3: THIS SCRIPT
#
# WHAT IT DOES
#   Reads the FIXED parallel config vasp-recommend chose (from .wolfpack/state.env)
#   and benchmarks THAT EXACT config -- not your raw INCAR. Because the recommended
#   rank count (e.g. 120) will not fit on the debug partition, it runs the same
#   KPAR/NCORE at the largest rank count that DOES fit (up to both debug nodes),
#   at the maximum debug memory (node RAM minus the WP_DEBUG_MEM_MARGIN fraction).
#   The SLURM job is capped at WP_TEST_WALLTIME_MIN; VASP runs that minus a short
#   analysis margin so the in-job sacct/scaling step fits. When the budget is up it:
#
#     1. Reads the SLURM metrics (MaxRSS, CPU efficiency) of the FIXED config.
#     2. SCALES the measured per-rank memory from the test rank count up to the
#        production rank count (VASP component-distribution rules).
#     3. Sizes the production memory to your cluster's >=80% utilisation rule and
#        WRITES the DEFINITIVE job slurm_vasptest.sh (recommend's slurm.sh refined
#        with the real measured memory + node split); slurm.sh is kept as-is.
#     4. Prints a VERDICT on whether the recommended config is adequate and
#        appends STAGE 3 to report.out.
#
#   The benchmark runs inside a throwaway sub-directory, so your existing
#   OUTCAR/WAVECAR/etc. are never touched and the folder stays clean. (The FIXED
#   KPAR/NCORE/NPAR were already written into your INCAR by vasp-recommend-slurm.)
#
# USAGE
#   cd <dir with INCAR / POSCAR / POTCAR / KPOINTS>      # after dry-run + recommend
#   vasp-test                        # renders ./slurm_benchmark.sh, submits it,
#                                    # then writes the DEFINITIVE ./slurm_vasptest.sh + report.out
#   vasp-test -n 3                   # benchmark row 3 of vasp-recommend-slurm's
#                                    #   [TOP CANDIDATES] table instead of the best
#
#   -n N, --candidate N, or just a bare number: which row of the
#   [TOP CANDIDATES] table to benchmark. Default: whatever the pipeline is
#   currently set to, which is row 1 (the best) unless you asked for another.
#   Choosing N re-runs vasp-recommend-slurm with --pick N -- with the SAME
#   arguments as the first time, recorded in state.env -- so it rewrites
#   INCAR + slurm.sh + state.env for candidate N and then benchmarks THAT.
#   The score ranks candidates; only a benchmark measures them.
#
#   Tunables (export before running; defaults come from the cluster profile):
#     VASP_TEST_WALLTIME_MIN=30     # SLURM job walltime cap (profile WP_TEST_WALLTIME_MIN);
#                                   #   VASP itself runs ANALYSIS_MARGIN_MIN minutes less
#     VASP_TEST_ANALYSIS_MARGIN_MIN    # whole-minute override of the margin below
#     VASP_TEST_KILL_GRACE_SEC=30      # SIGTERM -> SIGKILL window for VASP
#     VASP_TEST_SACCT_BUDGET_SEC=45    # how long to wait for accounting to appear
#     VASP_TEST_ANALYSIS_SLACK_SEC=15  # the scaling helper + writing report.out
#                                      #   VASP gets the walltime minus their sum
#                                      #   (90s by default: 18:30 of a 20-min slot)
#     VASP_TEST_MAX_CORES=96        # cap on debug ranks (default: 2 x cores/node)
#     VASP_EXE=vasp_std             # vasp_std | vasp_gam | vasp_ncl
#     VASP_TEST_MEM_UTIL=0.81       # request memory so usage >= this (profile WP_MEM_UTIL)
#     VASP_TEST_DEBUG_MEM_MARGIN    # fraction of a debug node left free (default WP_DEBUG_MEM_MARGIN)
#     VASP_TEST_DEBUG_MARGIN_MB     # absolute override of the above, in MB
#     VASP_TEST_MAX_CORES           # core cap for the benchmark (default WP_DEBUG_MAX_CORES)
#
# REQUIREMENTS
#   - Run vasp-dry-run + vasp-recommend-slurm first (this needs slurm.sh + state).
#   - SLURM job accounting (sacct/MaxRSS) enabled -> the memory is anchored to
#     the measured peak. If it is off, it falls back to VASP's own memory table.
###############################################################################

# --- Allow `vasp-test --help` to work outside of SLURM (handled in the parser
#     below too; this early check keeps --help working before set -u) ---------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,55p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'
    exit 0
fi

#----------------------- SBATCH fallback defaults -----------------------------
# These apply ONLY if you run `sbatch vasp-test` directly. The normal entry
# point `vasp-test` re-submits with cores/memory/partition/email taken from
# your cluster profile (vasp-configure) instead.
#SBATCH --job-name=vasp_test
#SBATCH --nodes=1
#SBATCH --time=00:18:00
#SBATCH --output=vasp_test-%j.out
#SBATCH --error=vasp_test-%j.err
#------------------------------------------------------------------------------

set -uo pipefail

# --- Load the cluster profile (vasp-configure) ----------------------------- #
# The INCAR layout library sits next to this script; readlink follows the
# ~/.local/bin symlink back to the toolkit.
_wp_lib="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/wolfpack_incar.sh"
# shellcheck source=/dev/null
if [[ -r "$_wp_lib" ]]; then source "$_wp_lib"; else
    echo "ERROR: wolfpack_incar.sh not found next to $(readlink -f "${BASH_SOURCE[0]}")" >&2
    exit 1
fi

_wp_conf="${WOLFPACK_CLUSTER_CONF:-$HOME/.config/wolfpack-dft/cluster.conf}"
# shellcheck source=/dev/null
[[ -f "$_wp_conf" ]] && source "$_wp_conf"

# --- The profile is REQUIRED, not optional --------------------------------- #
# Every value below is a FACT ABOUT THIS CLUSTER that vasp-configure asks the
# user for: partition names, cores per node, RAM per node, the debug walltime
# cap. Falling back to a built-in number means silently running with someone
# else's hardware -- and the numbers disagreed between tools (cores/node
# defaulted to 256 here and 128 in another script), so the "safe default" was
# not even self-consistent. A wrong guess does not fail fast either: SLURM
# accepts the job and the sizing is quietly wrong. So: if the answer is not in
# the profile, stop and say which answer is missing.
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
        if [[ -f "$_wp_conf" ]]; then
            echo " A profile exists at"
            echo "     ${_wp_conf}"
            echo " but does not define them. Re-run the wizard to fill them in:"
        else
            echo " No profile found at"
            echo "     ${_wp_conf}"
            echo " Create one (asks a handful of questions, once per cluster):"
        fi
        echo "     vasp-configure"
        echo "=============================================================================="
        echo
    } >&2
    exit 2
}

_wp_require WP_MAIN_PARTITION WP_MAIN_CPUS_PER_NODE WP_MAIN_MEM_PER_NODE_MB WP_DEBUG_PARTITION WP_DEBUG_CPUS_PER_NODE WP_DEBUG_MEM_PER_NODE_MB WP_TEST_WALLTIME_MIN WP_VASP_STD


# Debug/test partition WALLTIME cap = the SLURM job walltime, from the profile
# (vasp-configure: WP_TEST_WALLTIME_MIN), overridable per-run. VASP itself runs for
# WALLTIME minus the analysis margin so the in-job sacct + scaling step finishes
# inside the same allocation (debug partitions cap walltime hard).
WALLTIME_MIN="${VASP_TEST_WALLTIME_MIN:-${WP_TEST_WALLTIME_MIN:-30}}"
# How much of the allocation VASP gets.
#
# The margin used to be a flat 4 minutes, which on a 20-minute debug slot threw
# away a fifth of it: the benchmark ran 16 minutes and the analysis that the
# margin exists for took THREE SECONDS. So derive it from what it actually has
# to absorb, worst case:
#
#   KILL_GRACE   VASP is stopped with SIGTERM at the limit and gets this long
#                to exit at a safe point before SIGKILL. A real cost: it is the
#                one part of the margin that can always be spent.
#   SACCT_BUDGET job accounting can lag a finished step, so MaxRSS is polled.
#                This is the poll's whole budget, not its usual cost.
#   ANALYSIS     the scaling helper and writing report.out.
#
# On a 20-minute slot that is 18:30 of VASP instead of 16:00. Going further is
# a bad trade: at 19:30 the remaining 30s is exactly the SIGKILL window, so a
# VASP that does not exit promptly takes the whole job down with it and the
# benchmark -- the entire 20 minutes of queue -- produces nothing.
KILL_GRACE_SEC="${VASP_TEST_KILL_GRACE_SEC:-30}"
SACCT_BUDGET_SEC="${VASP_TEST_SACCT_BUDGET_SEC:-45}"
ANALYSIS_SLACK_SEC="${VASP_TEST_ANALYSIS_SLACK_SEC:-15}"
JOB_MINUTES=$WALLTIME_MIN                                # SLURM allocation = the walltime cap
if [[ -n "${VASP_TEST_ANALYSIS_MARGIN_MIN:-}" ]]; then   # legacy override, still honoured
    ANALYSIS_MARGIN_SEC=$(( VASP_TEST_ANALYSIS_MARGIN_MIN * 60 ))
else
    ANALYSIS_MARGIN_SEC=$(( KILL_GRACE_SEC + SACCT_BUDGET_SEC + ANALYSIS_SLACK_SEC ))
fi
RUN_SECONDS=$(( JOB_MINUTES * 60 - ANALYSIS_MARGIN_SEC ))
(( RUN_SECONDS < 60 )) && RUN_SECONDS=$(( JOB_MINUTES * 60 / 2 ))
(( RUN_SECONDS < 30 )) && RUN_SECONDS=30
RUN_MINUTES=$(( RUN_SECONDS / 60 ))                      # for the messages only
RUN_CLOCK=$(printf '%d:%02d' $(( RUN_SECONDS / 60 )) $(( RUN_SECONDS % 60 )))
# RAM left free per DEBUG node, as a FRACTION of the node (profile:
# WP_DEBUG_MEM_MARGIN; 0.05 => 95% usable).  A legacy absolute WP_DEBUG_RESERVE_GB is
# still honoured if the profile predates the fraction.  The absolute MB is resolved
# later, once the debug node's memory is known.
DEBUG_MEM_MARGIN="${VASP_TEST_DEBUG_MEM_MARGIN:-${WP_DEBUG_MEM_MARGIN:-}}"
DEBUG_RESERVE_GB_LEGACY="${WP_DEBUG_RESERVE_GB:-}"

WANT_PICK=""          # empty = use whatever the pipeline is already set to
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) sed -n '2,66p' "${BASH_SOURCE[0]}" | grep -v '^#####' | sed 's/^# \{0,1\}//'; exit 0 ;;
        -n|--candidate)
            [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "vasp-test: $1 needs a row number, e.g. $1 3" >&2; exit 2; }
            WANT_PICK="$2"; shift 2 ;;
        -n*)  WANT_PICK="${1#-n}"
              [[ "$WANT_PICK" =~ ^[0-9]+$ ]] || { echo "vasp-test: '$1' is not a row number" >&2; exit 2; }
              shift ;;
        --candidate=*) WANT_PICK="${1#*=}"
              [[ "$WANT_PICK" =~ ^[0-9]+$ ]] || { echo "vasp-test: '$1' is not a row number" >&2; exit 2; }
              shift ;;
        [0-9]*) WANT_PICK="$1"; shift ;;
        *) echo "vasp-test: unknown option '$1' (try --help)" >&2; shift ;;
    esac
done
if [[ -n "$WANT_PICK" && "$WANT_PICK" -lt 1 ]]; then
    echo "vasp-test: candidate numbers start at 1 (1 = the best)." >&2; exit 2
fi

# --- Read the FIXED config from vasp-recommend (STAGE 2 of the pipeline) ---- #
_wp_state="${WOLFPACK_STATE:-.wolfpack/state.env}"
# shellcheck source=/dev/null
[[ -f "$_wp_state" ]] && source "$_wp_state"

# --- -n N: benchmark row N of the recommendation table ---------------------- #
# Re-run vasp-recommend-slurm with --pick N rather than reinterpreting its
# table here. It owns the rules; duplicating the selection is how the two
# would drift apart. The arguments it was first run with are in state.env
# (rec_args), so row N is a row of the SAME table the user read.
# Never inside the benchmark job: there state.env is already the truth.
if [[ -n "$WANT_PICK" && -z "${WP_VASPTEST_JOB:-}" ]]; then
    if [[ "$WANT_PICK" == "${pick:-1}" ]]; then
        echo "vasp-test: already set to candidate ${WANT_PICK}${pick_of:+ of $pick_of}; nothing to re-pick." >&2
    else
        _rec=""
        for _c in "${VASP_RECOMMEND:-}" "$(command -v vasp-recommend-slurm 2>/dev/null)" \
                  "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vasp_recommend_slurm.py"; do
            [[ -n "$_c" && -f "$_c" ]] && { _rec="$_c"; break; }
        done
        if [[ -z "$_rec" ]]; then
            echo "vasp-test: -n needs vasp-recommend-slurm on PATH (or \$VASP_RECOMMEND)." >&2
            exit 2
        fi
        echo "STAGE 3: re-selecting candidate ${WANT_PICK} (was ${pick:-1}) -- rewriting INCAR + slurm.sh" >&2
        # rec_args is a shell-quoted argument list written by the recommender.
        eval "set -- ${rec_args:-}"
        _py="$(command -v python3 || command -v python || echo python3)"
        if ! "$_py" "$_rec" "$@" --pick "$WANT_PICK"; then
            echo "vasp-test: vasp-recommend-slurm --pick $WANT_PICK failed; nothing was benchmarked." >&2
            exit 2
        fi
        # shellcheck source=/dev/null
        [[ -f "$_wp_state" ]] && source "$_wp_state"
    fi
fi

FIX_KPAR="${kpar:-1}"; FIX_NCORE="${ncore:-1}"; FIX_NPAR="${npar:-1}"
FIX_NSIM="${nsim:-4}"; PROD_RANKS="${ranks:-0}"
PROD_PARTITION="${prod_partition:-${WP_MAIN_PARTITION:-main}}"
PROD_CPN="${prod_cpn:-${WP_MAIN_CPUS_PER_NODE:-256}}"
PROD_NODE_MEM="${node_mem_mb:-${WP_MAIN_MEM_PER_NODE_MB:-256000}}"
MEM_UTIL="${mem_util:-${VASP_TEST_MEM_UTIL:-0.80}}"

# Detect GW/RPA from the INCAR ALGO. The benchmark only reaches the FLAT (DFT-setup)
# phase and CANNOT measure the GW floor, so for GW the helper sizes from the per-rank
# FLOOR (VASP's own reported requirement when present, else an anchored NOMEGA-
# independent ~ENCUTGW^3 floor) -- it does NOT extrapolate the MaxRSS.
_algo="$(grep -m1 -oiE '^[[:space:]]*ALGO[[:space:]]*=[[:space:]]*[A-Za-z0-9_]+' INCAR 2>/dev/null | sed -E 's/.*=[[:space:]]*//')"
IS_GW=0
case "${_algo^^}" in GW*|EVGW*|QPGW*|SCGW*|G0W0*|ACFDT*|RPA*|CHI*|BSE*) IS_GW=1 ;; esac

# Emit the resolved module-load command lines (baked into the rendered job).
_wp_module_block() {
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        local cmd="${WP_MODULE_CMD:-ml}"
        if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
            [[ "$cmd" == "module" ]] && echo "module purge" || echo "ml purge"
        fi
        if [[ "$cmd" == "module" ]]; then echo "module load ${WP_VASP_MODULES}"
        else echo "ml ${WP_VASP_MODULES}"; fi
    else
        # No modules configured. Emit none.
        #
        # This used to fall back to the modules of the machine this toolkit
        # was first written on (gcc/14.2.0-zen4-y, vasp/6.4.3-...). On a
        # cluster where WP_VASP_MODULES is empty ON PURPOSE -- because
        # WP_VASP_STD is an absolute path, or because the site has no module
        # system at all -- that loaded a STRANGER'S VASP over the one that
        # was benchmarked, silently, and the run measured one binary while
        # production used another.
        echo "# (no modules configured in your cluster profile)"
    fi
}

# --- Submit side: fit the FIXED config into the debug partition + submit --- #
#
# WHICH SIDE ARE WE ON?  The test is "did I launch this job myself", and the
# only honest answer is a mark this script writes into its own job script
# (WP_VASPTEST_JOB, set just before the exec below).
#
# Asking "is SLURM_JOB_ID set" instead is a different question, and a dangerous
# one: that variable is set inside ANY job, including one somebody wrapped
# around this script.  A wrapper job is typically small and short -- one task,
# twenty minutes -- so this script would conclude it was already inside its own
# benchmark and run VASP with the WRAPPER's resources: one rank instead of the
# hundreds it had sized, and a walltime that cuts the run off.  The benchmark it
# chose would never be submitted, and nothing would say so.
if [[ -z "${WP_VASPTEST_JOB:-}" ]]; then
    if ! command -v sbatch >/dev/null 2>&1; then
        echo "ERROR: sbatch not found. Run on a cluster login node." >&2; exit 1
    fi
    if [[ -n "${SLURM_JOB_ID:-}" ]]; then
        echo "STAGE 3: running inside job ${SLURM_JOB_ID}, which is NOT a vasp-test" >&2
        echo "         benchmark. Submitting the benchmark as its own job rather than" >&2
        echo "         running VASP with this job's resources." >&2
    fi
    if [[ "${stage:-}" != "recommend" || ! -f slurm.sh ]]; then
        echo "ERROR: no recommendation found. Run the pipeline IN ORDER:" >&2
        echo "         vasp-dry-run  ->  vasp-recommend-slurm  ->  vasp-test" >&2
        exit 2
    fi
    # The benchmark ALWAYS runs on the DEBUG configuration -- its partition, its core
    # cap and its memory margin.  When the user answered the DEBUG-partition prompt
    # with the MAIN partition (a cluster with no separate debug queue) the test simply
    # runs there, but it is still sized by the DEBUG limits below, so a "test" can
    # never grow into a production-sized job.
    part="${WP_DEBUG_PARTITION:-debug}"
    cpn="${WP_DEBUG_CPUS_PER_NODE:-48}"
    memnode="${WP_DEBUG_MEM_PER_NODE_MB:-360000}"
    if [[ "$part" == "${WP_MAIN_PARTITION:-}" ]]; then
        echo "STAGE 3: DEBUG partition == MAIN ('$part') -- the test runs there but is" >&2
        echo "         sized by the DEBUG limits (cores + memory margin)." >&2
    fi

    # Resolve the DEBUG memory margin (fraction of the node left FREE) into MB.
    if [[ -n "$DEBUG_MEM_MARGIN" ]]; then
        DEBUG_MARGIN_MB=$(awk -v m="$memnode" -v f="$DEBUG_MEM_MARGIN" \
            'BEGIN{ f=f+0; if(f<0)f=0; if(f>0.5)f=0.5; printf "%d", m*f }')
    elif [[ -n "$DEBUG_RESERVE_GB_LEGACY" ]]; then
        DEBUG_MARGIN_MB=$(( DEBUG_RESERVE_GB_LEGACY * 1024 ))     # legacy profile
    else
        DEBUG_MARGIN_MB=$(awk -v m="$memnode" 'BEGIN{ printf "%d", m*0.05 }')
    fi
    DEBUG_MARGIN_MB="${VASP_TEST_DEBUG_MARGIN_MB:-$DEBUG_MARGIN_MB}"

    # Largest rank count that (a) keeps KPAR x NCORE fixed, (b) is within the DEBUG
    # core cap (profile WP_DEBUG_MAX_CORES; else two debug nodes), and (c) does not
    # exceed the production rank count.
    max_test="${VASP_TEST_MAX_CORES:-${WP_DEBUG_MAX_CORES:-$(( cpn * 2 ))}}"
    (( max_test < 1 )) && max_test=$cpn
    unit=$(( FIX_KPAR * FIX_NCORE )); (( unit < 1 )) && unit=1

    # ---------------------------------------------------------------------- #
    # PRE-FLIGHT: can this benchmark run on this partition AT ALL?
    #
    # The benchmark must reproduce the RECOMMENDED config exactly, so its rank
    # count is an indivisible multiple of KPAR x NCORE and every rank needs the
    # memory recommend predicted. Any site limit below those is a hard stop --
    # rounding up to make it "fit" would just hand SLURM a job it rejects. Every
    # blocking limit is collected and reported TOGETHER, so one run tells the
    # user everything that is wrong instead of one thing per attempt.
    #
    # NOTE: no node COUNT is configured anywhere (vasp-configure asks for cores
    # and memory PER NODE, not how many nodes a partition has), so the node
    # limit is inferred from the core cap: nodes = ceil(cap / cores-per-node).
    # ---------------------------------------------------------------------- #
    _need_mem="${pred_mem_per_rank:-0}"; _need_mem="${_need_mem%%.*}"
    _need_mem="${_need_mem//[!0-9]/}"; _need_mem="${_need_mem:-0}"
    _usable=$(( memnode - DEBUG_MARGIN_MB )); (( _usable < 1 )) && _usable=$memnode
    _probe_ntpn=$(( unit < cpn ? unit : cpn ))
    (( _probe_ntpn < 1 )) && _probe_ntpn=1
    _probe_mem=$(( _usable / _probe_ntpn ))
    _need_nodes=$(( (unit + cpn - 1) / cpn ))
    _cap_nodes=$(( (max_test + cpn - 1) / cpn ))

    _why=()
    (( max_test < unit )) && _why+=(
        "cores      | ${max_test} allowed | ${unit} needed | WP_DEBUG_MAX_CORES (or the site QOS)")
    (( _need_mem > 0 && _probe_mem < _need_mem )) && _why+=(
        "memory/rank| ${_probe_mem} MB free | ${_need_mem} MB needed | WP_DEBUG_MEM_PER_NODE_MB, WP_DEBUG_MEM_MARGIN")
    (( _need_nodes > _cap_nodes )) && _why+=(
        "nodes      | ${_cap_nodes} within cap | ${_need_nodes} needed | inferred from WP_DEBUG_MAX_CORES / WP_DEBUG_CPUS_PER_NODE")

    if (( ${#_why[@]} > 0 )); then
        {
        echo
        echo "=============================================================================="
        echo " CANNOT RUN THE BENCHMARK (STAGE 3) on partition '${part}'"
        echo "=============================================================================="
        echo " The recommended config is KPAR=${FIX_KPAR} NCORE=${FIX_NCORE} -> ${unit} ranks is the"
        echo " smallest indivisible unit, and recommend predicts ~${_need_mem} MB per rank."
        echo
        echo " WHY IT CANNOT RUN:"
        printf '   %-11s %-16s %-18s %s\n' "limit" "available" "required" "set by"
        printf '   %s\n' "---------------------------------------------------------------------------"
        for r in "${_why[@]}"; do
            IFS='|' read -r a b c d <<<"$r"
            printf '   %-11s %-16s %-18s %s\n' "$a" "$(echo $b)" "$(echo $c)" "$(echo $d)"
        done
        echo
        echo " WHAT YOU CAN DO:"
        echo "   * benchmark on the production partition instead:"
        echo "       vasp-configure --debug-partition ${PROD_PARTITION} --debug-max-cores ${PROD_RANKS:-$unit}"
        echo "   * raise the limits, if the site's QOS actually allows it:"
        echo "       vasp-configure --debug-max-cores ${unit}"
        echo "   * or re-run vasp-recommend-slurm and choose a candidate with a smaller"
        echo "     KPAR x NCORE from the [TOP CANDIDATES] table."
        echo "   * one-off override for this run only:"
        echo "       VASP_TEST_MAX_CORES=${unit} vasp-test"
        echo
        echo " STAGE 3 SKIPPED. Nothing was submitted. slurm.sh (recommend's first pass,"
        echo " unvalidated memory) is still there if you want to submit it as-is."
        echo "=============================================================================="
        } >&2
        exit 2
    fi

    tr=$(( (max_test / unit) * unit )); (( tr < unit )) && tr=$unit
    if (( PROD_RANKS > 0 && tr > PROD_RANKS )); then
        tr=$(( (PROD_RANKS / unit) * unit )); (( tr < unit )) && tr=$unit
    fi
    tnodes=$(( (tr + cpn - 1) / cpn )); (( tnodes < 1 )) && tnodes=1
    tntpn=$(( (tr + tnodes - 1) / tnodes ))
    usable=$(( memnode - DEBUG_MARGIN_MB )); (( usable < 1 )) && usable=$memnode
    mempc=$(( usable / tntpn )); (( mempc < 100 )) && mempc=100
    ttime=$(printf '%02d:%02d:00' $((JOB_MINUTES/60)) $((JOB_MINUTES%60)))
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    mkdir -p .wolfpack
    job="$PWD/slurm_benchmark.sh"
    {
        echo "#!/bin/bash"
        echo "#SBATCH --job-name=vasp_bench"
        echo "#SBATCH --partition=${part}"
        echo "#SBATCH --nodes=${tnodes}"
        echo "#SBATCH --ntasks=${tr}"
        # Only when nodes x ntasks-per-node is exactly the rank count. This is
        # the line that produced "srun: warning: can't honor --ntasks-per-node
        # set to 48 which doesn't match the requested tasks 190 with the number
        # of requested nodes 4. Ignoring --ntasks-per-node." -- and SLURM then
        # allocated 192 CPUs for 190 ranks. The recommender was taught this;
        # the benchmark script, written here, was not.
        if (( tnodes * tntpn == tr )); then
            echo "#SBATCH --ntasks-per-node=${tntpn}"
        else
            echo "# no --ntasks-per-node: ${tr} ranks do not divide evenly over ${tnodes} node(s)"
        fi
        echo "#SBATCH --cpus-per-task=1"
        echo "#SBATCH --mem-per-cpu=${mempc}"
        echo "#SBATCH --time=${ttime}"
        if [[ -n "${WP_EMAIL:-}" ]]; then
            echo "#SBATCH --mail-user=${WP_EMAIL}"
            echo "#SBATCH --mail-type=ALL"
        fi
        echo "#SBATCH --output=.wolfpack/benchmark-%j.out"
        echo "#SBATCH --error=.wolfpack/benchmark-%j.err"
        echo ""
        echo "# Generated by vasp-test on $(date -Iseconds) -- STAGE 3/3 (exact job)."
        echo 'cd "$SLURM_SUBMIT_DIR" || exit 1'
        echo ""
        echo "# --- modules (resolved from your cluster profile) ---"
        _wp_module_block
        echo ""
        echo "export VASP_TEST_WALLTIME_MIN='${WALLTIME_MIN}'"
        echo "export WP_MODULES_PRELOADED=1"
        # The job re-execs this script on a COMPUTE node, where it re-reads the
        # cluster profile -- so the profile has to be reachable from there. It
        # need not be: on Santos Dumont $HOME is /prj, which compute nodes do
        # not mount, so the re-exec'd script found no profile and exited 2 after
        # ten seconds. Point it at the copy staged beside the job instead, on
        # the same filesystem as the calculation and therefore visible by
        # construction. Copying rather than exporting each value keeps the
        # quoting honest (WP_EXTRA_ENV carries semicolons and quotes) and pins
        # the job to the profile it was submitted with.
        echo '_wp_staged="$SLURM_SUBMIT_DIR/.wolfpack/cluster.conf"'
        echo '[[ -f "$_wp_staged" ]] && export WOLFPACK_CLUSTER_CONF="$_wp_staged"'
        # The mark that tells the re-exec'd copy it is inside the benchmark THIS
        # script submitted, and not inside somebody else's wrapper job.
        echo "export WP_VASPTEST_JOB=1"
        echo "exec '${self}'"
    } > "$job"
    [[ -f "$_wp_conf" ]] && cp -f "$_wp_conf" .wolfpack/cluster.conf
    chmod +x "$job"
    echo "STAGE 3: benchmarking the FIXED config (KPAR=${FIX_KPAR} NCORE=${FIX_NCORE} NSIM=${FIX_NSIM})" >&2
    if [[ "${pick:-1}" != "1" ]]; then
        echo "         this is candidate ${pick}${pick_of:+ of $pick_of} of the table, not the best (you asked: -n ${pick})" >&2
    fi
    echo "         at ${tr} ranks on '${part}' (${tnodes} node(s) x ${tntpn}, ${mempc} MB/cpu," >&2
    echo "         ${DEBUG_MARGIN_MB} MB/node held back = $(awk -v m=$memnode -v r=$DEBUG_MARGIN_MB 'BEGIN{printf "%.0f", 100.0*(1-r/m)}')% usable," >&2
    echo "         cap ${max_test} cores; ${RUN_CLOCK} VASP run in a ${JOB_MINUTES}-min job); production target ${PROD_RANKS} ranks." >&2
    exec sbatch "$job"
fi

# --------------------------------------------------------------------------- #
# Job side: configuration (overridable via environment / cluster profile)
# --------------------------------------------------------------------------- #
VASP_EXE="${VASP_EXE:-${WP_VASP_STD:-vasp_std}}"
EMAIL="${VASP_TEST_EMAIL:-${WP_EMAIL:-}}"
JOBNAME="${VASP_TEST_JOBNAME:-VASP}"
NTASKS="${SLURM_NTASKS:-48}"
NTPN="${SLURM_NTASKS_PER_NODE:-$NTASKS}"
PARTITION="${SLURM_JOB_PARTITION:-${WP_DEBUG_PARTITION:-debug}}"
NODE_MEM_MB="${WP_DEBUG_MEM_PER_NODE_MB:-$(( NTPN * 7500 ))}"

SUBMIT_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
cd "$SUBMIT_DIR" || { echo "Cannot cd to submit dir $SUBMIT_DIR" >&2; exit 1; }

rule() { printf '%.0s-' {1..78}; echo; }
hdr()  { echo; rule; echo " $*"; rule; }
posq() { awk -v v="${1:-0}" 'BEGIN{exit !(v>0)}'; }   # true if $1 is a positive number

# Record an INCOMPLETE analysis in report.out, not only on stdout.
#
# When a step of the write-up could not run, the section it would have written
# simply did not appear -- and a missing section is indistinguishable from a
# section that had nothing to report. report.out is what gets read days later,
# often by someone who never saw the job's stdout, so the gap has to be IN it.
_wp_report_gap() {
    local title="$1"; shift
    { echo ""
      echo "################################################################################"
      echo "#  INCOMPLETE -- ${title}"
      echo "################################################################################"
      echo ""
      printf '  %s\n' "$@"
      echo ""
    } >> "$SUBMIT_DIR/report.out" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# 1. Validate inputs and build an isolated run directory
# --------------------------------------------------------------------------- #
need=(INCAR POSCAR POTCAR KPOINTS)
missing=0
for f in "${need[@]}"; do
    [[ -s "$SUBMIT_DIR/$f" ]] || { echo "ERROR: missing or empty $f in $SUBMIT_DIR" >&2; missing=1; }
done
[[ $missing -eq 0 ]] || { echo "Aborting: provide INCAR/POSCAR/POTCAR/KPOINTS." >&2; exit 1; }

# The benchmark's scratch lives UNDER .wolfpack/, not beside your inputs. It
# used to be "$SUBMIT_DIR/vasp_test_$JOBID", which left a directory in the
# calculation folder for every benchmark that ever failed -- each one still
# holding a CHGCAR and a WAVECAR.
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    echo "ERROR: WP_VASPTEST_JOB is set but SLURM_JOB_ID is not." >&2
    echo "       That variable is written by vasp-test into its own job script;" >&2
    echo "       do not set it by hand." >&2
    exit 2
fi
mkdir -p "$SUBMIT_DIR/.wolfpack"
RUNDIR="$SUBMIT_DIR/.wolfpack/vasp_test_${SLURM_JOB_ID}"
mkdir -p "$RUNDIR"

# On any exit other than the clean one below, the run dir SURVIVES -- it is the
# evidence of what went wrong -- but its heavy files do not. A failed benchmark
# needs OUTCAR, OSZICAR and stdout to be diagnosable; CHGCAR and WAVECAR only
# pile up, one set per failure, in a folder the user has to keep. The trap also
# covers the time-limit kill, which is exactly the case that used to leave them.
_wp_strip_heavy() {
    [[ -d "$RUNDIR" ]] || return 0
    rm -f "$RUNDIR"/WAVECAR "$RUNDIR"/CHGCAR "$RUNDIR"/CHG \
          "$RUNDIR"/vaspout.h5 "$RUNDIR"/WAVEDER "$RUNDIR"/PROCAR \
          "$RUNDIR"/TMPCAR "$RUNDIR"/LOCPOT "$RUNDIR"/ELFCAR 2>/dev/null || true
}
trap _wp_strip_heavy EXIT TERM INT
cp -f "$SUBMIT_DIR"/INCAR "$SUBMIT_DIR"/POSCAR "$SUBMIT_DIR"/POTCAR "$SUBMIT_DIR"/KPOINTS "$RUNDIR/"
cd "$RUNDIR" || { echo "Cannot enter run dir $RUNDIR" >&2; exit 1; }

# Pin the benchmark to the EXACT parallel config vasp-recommend chose (so we
# validate that fixed layout), and skip WAVECAR/CHGCAR I/O. This edits only the
# THROWAWAY copy; the real INCAR's physics is never touched here (on success the
# FIXED KPAR/NCORE/NSIM are applied to it -- see the end of this script).
TEST_NPAR=$(( NTASKS / (FIX_KPAR * FIX_NCORE) )); (( TEST_NPAR < 1 )) && TEST_NPAR=1
# Set in place, each tag under its own section header. This used to append a
# banner and a block of duplicates, leaning on VASP honouring the LAST
# occurrence of a repeated tag -- which works, but leaves a file nobody can read
# and which no longer resembles the INCAR it came from.
for _kv in "KPAR=${FIX_KPAR}" "NCORE=${FIX_NCORE}" "NSIM=${FIX_NSIM}" \
           "LWAVE=.FALSE." "LCHARG=.FALSE."; do
    wp_incar_set INCAR "${_kv%%=*}" "${_kv#*=}" "benchmark (vasp-test)"
done

hdr "VASP RESOURCE BENCHMARK  (${PARTITION}, ${NTASKS} ranks, ${RUN_CLOCK} of ${JOB_MINUTES} min)"
echo "  job id        : $SLURM_JOB_ID"
echo "  run directory : $RUNDIR"
echo "  executable    : $VASP_EXE"
echo "  testing config: KPAR=${FIX_KPAR} NCORE=${FIX_NCORE} NPAR=${TEST_NPAR} NSIM=${FIX_NSIM}  (FIXED by vasp-recommend)"
echo "  production goal: ${PROD_RANKS} ranks on '${PROD_PARTITION}'"
echo "  start         : $(date)"

# --------------------------------------------------------------------------- #
# 2. Modules / environment (from the cluster profile; same build you will use
#    on the main partition, so the benchmark is representative). The rendered
#    slurm_benchmark.sh wrapper normally loads these already (WP_MODULES_PRELOADED).
# --------------------------------------------------------------------------- #
if [[ -z "${WP_MODULES_PRELOADED:-}" ]]; then
    if [[ -n "${WP_VASP_MODULES:-}" ]]; then
        _wpcmd="${WP_MODULE_CMD:-ml}"
        if [[ "${WP_MODULE_PURGE:-1}" == "1" ]]; then
            { [[ "$_wpcmd" == "module" ]] && module purge || ml purge; } 2>/dev/null || true
        fi
        # shellcheck disable=SC2086
        if [[ "$_wpcmd" == "module" ]]; then module load $WP_VASP_MODULES
        else ml $WP_VASP_MODULES; fi
    else
        : # no modules configured -- load none (see the note in _wp_module_block)
    fi
fi
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
# extra environment exports from the cluster profile (e.g. OMPI/MKL pinning)
if [[ -n "${WP_EXTRA_ENV:-}" ]]; then
    IFS=';' read -r -a _wpenv <<< "$WP_EXTRA_ENV"
    for _e in "${_wpenv[@]}"; do [[ -n "${_e// }" ]] && eval "$_e" 2>/dev/null || true; done
fi

# --------------------------------------------------------------------------- #
# 3. Run VASP for at most RUN_MINUTES (< the SLURM allocation), then stop it so
#    the analysis below still finishes inside the requested walltime.
# --------------------------------------------------------------------------- #
hdr "RUNNING VASP (timed)"
run_start=$(date +%s)
# --signal=TERM lets VASP exit at the next safe point; --kill-after forces it.
timeout --signal=TERM --kill-after="${KILL_GRACE_SEC}s" "${RUN_SECONDS}s" \
    srun --cpu-bind=cores "$VASP_EXE"
rc=$?
run_end=$(date +%s)
wall=$(( run_end - run_start ))
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "  VASP reached the ${RUN_CLOCK} benchmark limit and was stopped (expected)."
elif [[ $rc -eq 0 ]]; then
    echo "  VASP finished on its own before the limit (small system) -- metrics still valid."
else
    echo "  VASP exited with code $rc -- metrics below may be partial."
fi
echo "  measured wall time: ${wall}s"

OUTCAR="$RUNDIR/OUTCAR"
[[ -s "$OUTCAR" ]] || { echo "ERROR: no OUTCAR produced -- cannot analyse." >&2; exit 1; }

# --------------------------------------------------------------------------- #
# 4. Gather SLURM accounting metrics (poll: accounting can lag a few seconds)
# --------------------------------------------------------------------------- #
hdr "MEASURED RESOURCE USAGE"
RAW=""
if command -v sacct >/dev/null 2>&1; then
    # Poll against a DEADLINE, not a fixed count. The walltime arithmetic above
    # reserves SACCT_BUDGET_SEC for exactly this, so the loop has to honour that
    # number rather than spend 15 x 3s whatever is left of the allocation.
    _sacct_deadline=$(( $(date +%s) + SACCT_BUDGET_SEC ))
    while :; do
        # --units=M forces EVERY memory field into MB, so the parser never has to
        # guess whether a suffix-less number is bytes or KB (this cluster reports
        # MaxRSS as "576512K" but AveRSS as raw bytes -> a 1024x error). Older
        # SLURM lacks the flag, so fall back to the unit-suffixed form.
        RAW=$(sacct -j "$SLURM_JOB_ID" -n -P --units=M \
                -o JobID,State,Elapsed,TotalCPU,NCPUS,MaxRSS,AveRSS 2>/dev/null)
        [[ -z "$RAW" ]] && RAW=$(sacct -j "$SLURM_JOB_ID" -n -P \
                -o JobID,State,Elapsed,TotalCPU,NCPUS,MaxRSS,AveRSS 2>/dev/null)
        if printf '%s\n' "$RAW" | awk -F'|' '$6!="" && $6!~/^0?$/{f=1} END{exit !f}'; then
            break
        fi
        (( $(date +%s) >= _sacct_deadline )) && {
            echo "  (sacct still had no MaxRSS after ${SACCT_BUDGET_SEC}s -- not waiting longer)" >&2
            break
        }
        sleep 3
    done
fi

# Parse: MaxRSS AND AveRSS (MB) across all steps; CPU efficiency from the VASP step.
#
# WHY BOTH: MaxRSS is the memory of the single HEAVIEST rank, AveRSS the mean over
# ranks. What SLURM actually enforces is the NODE TOTAL (mem-per-cpu x ranks-per-node),
# and that total is AveRSS x ranks -- NOT MaxRSS x ranks. On k-point-parallel jobs rank 0
# is a huge outlier (it holds the gathered all-k-point arrays), so sizing from MaxRSS
# over-reserves by the imbalance factor. Measured 2026-08-05 on a KPAR=63 DOS run:
# MaxRSS 7822 MB but AveRSS 1214 MB (6.4x imbalance) -> 611 GB reserved for 76 GB used
# (12.5% utilisation). AveRSS is what the sizing must use; MaxRSS stays for diagnostics.
read -r maxrss_mb averss_mb step_elapsed_s step_cpu_s step_ncpus <<<"$(
    printf '%s\n' "$RAW" | awk -F'|' '
    function to_mb(x,  u,n){ if(x==""||x=="0")return 0;
        u=substr(x,length(x),1);
        if(u ~ /[KMGT]/){ n=substr(x,1,length(x)-1)+0 } else { n=x+0; u="K" }
        if(u=="K")return n/1024.0; if(u=="M")return n;
        if(u=="G")return n*1024.0; if(u=="T")return n*1048576.0; return n/1024.0 }
    function to_s(t,  d,a,n,s){ if(t=="")return 0; s=0;
        n=split(t,d,"-"); if(n==2){ s+=d[1]*86400; t=d[2] }
        n=split(t,a,":"); if(n==3)s+=a[1]*3600+a[2]*60+a[3];
        else if(n==2)s+=a[1]*60+a[2]; else s+=a[1]+0; return s }
    { rss=to_mb($6); ave=to_mb($7)
      # keep the AveRSS reported on the SAME step that carries the peak MaxRSS
      if(rss>maxrss){ maxrss=rss; maxave=ave }
      if(ave>anyave) anyave=ave
      jid=$1
      if(jid ~ /\.0$/){ el=to_s($3); cpu=to_s($4); nc=$5+0 }
      if(jid !~ /\./){ jel=to_s($3); jcpu=to_s($4); jnc=$5+0 } }
    END{ if(el==0||el==""){ el=jel; cpu=jcpu; nc=jnc }
         ave=(maxave>0?maxave:anyave)
         printf "%.1f %.1f %.1f %.1f %d", maxrss+0, ave+0, el+0, cpu+0, nc+0 }'
)"
maxrss_mb="${maxrss_mb:-0}"; averss_mb="${averss_mb:-0}"
step_elapsed_s="${step_elapsed_s:-0}"
step_cpu_s="${step_cpu_s:-0}"; step_ncpus="${step_ncpus:-0}"

# SANITY: AveRSS is a mean over the same ranks MaxRSS is a max over, so
# AveRSS <= MaxRSS ALWAYS. A violation means sacct reported the two fields in
# different units (seen 2026-08-12: MaxRSS "576512K" but AveRSS in raw bytes ->
# AveRSS parsed 1024x too large). Sizing the job from that number asks SLURM for
# ~1024x the memory the run actually needs, which is exactly the failure this
# guard exists to stop. Distrust AveRSS and fall back to MaxRSS (an upper bound,
# so conservative but never wrong).
averss_bad=0
if posq "$averss_mb" && posq "$maxrss_mb"; then
    awk -v a="$averss_mb" -v m="$maxrss_mb" 'BEGIN{ exit !(a > m*1.001) }' && averss_bad=1
fi
if (( averss_bad )); then
    printf '  !! AveRSS (%s MB) exceeds MaxRSS (%s MB) -- impossible for a mean.\n' \
        "$averss_mb" "$maxrss_mb" >&2
    printf '     sacct reported the two in different units; ignoring AveRSS and\n' >&2
    printf '     sizing from MaxRSS instead (upper bound, so safe).\n' >&2
    averss_mb=0
fi

cpu_eff=$(awk -v c="$step_cpu_s" -v e="$step_elapsed_s" -v n="$step_ncpus" \
    'BEGIN{ if(e>0 && n>0) printf "%.1f", 100.0*c/(e*n); else printf "0" }')
# The node total is what SLURM enforces: sum over ranks = AveRSS x ranks-per-node.
# Fall back to MaxRSS only when accounting gives no AveRSS (then it is an upper bound).
rss_for_node="$averss_mb"; posq "$rss_for_node" || rss_for_node="$maxrss_mb"
peak_node_gb=$(awk -v r="$rss_for_node" -v n="$NTPN" 'BEGIN{ printf "%.1f", r*n/1024.0 }')
# Rank imbalance: >1.5x means one rank (usually rank 0, holding the gathered
# all-k-point arrays) dominates and MaxRSS must NOT be used for sizing.
rss_imbalance=$(awk -v m="$maxrss_mb" -v a="$averss_mb" \
    'BEGIN{ if(a>0) printf "%.1f", m/a; else printf "0" }')

# VASP's own per-rank memory table from the OUTCAR (independent cross-check).
vasp_tbl_mb=$(awk '/total amount of memory used by VASP MPI-rank0/{
        for(i=1;i<=NF;i++) if($i ~ /[kK][bB]ytes/){ printf "%.1f", $(i-1)/1024.0; exit } }' "$OUTCAR")
vasp_tbl_mb="${vasp_tbl_mb:-0}"

# Per-electronic-step wall time and step count from the OUTCAR.
# NB: `grep -c` prints "0" AND exits 1 on zero matches, so `|| echo 0` would
# append a second line ("0\n0"). Capture it plain and sanitise to one integer.
nscf=$(grep -c 'LOOP:' "$OUTCAR" 2>/dev/null); nscf="${nscf//[^0-9]/}"; nscf="${nscf:-0}"
avg_loop=$(awk '/LOOP:/{ k=split($0,a,"real time"); if(k>1){ s+=a[2]+0; c++ } }
                END{ if(c>0) printf "%.2f", s/c; else printf "0" }' "$OUTCAR")
avg_loop="${avg_loop:-0}"

# Ionic-step timing and the fixed setup cost, for anything that has to budget a
# walltime from this benchmark.
#
# 'LOOP:' is the ELECTRONIC step and 'LOOP+:' the IONIC one. They are distinct
# literals -- "LOOP:" is not a substring of "LOOP+:" -- so the greps do not
# overlap and neither needs to exclude the other (verified: 38 vs 1 on a real
# OUTCAR, zero overlap).
#
# The residual  Elapsed - sum(LOOP:) - sum(LOOP+:)  is everything that is NOT a
# step: process start-up, FFT planning, POTCAR/WAVECAR I/O. A chunked run pays
# that once per chunk, so it has to be budgeted separately from the per-step
# rate rather than smeared into it.
sum_loop=$(awk '/LOOP:/{ k=split($0,a,"real time"); if(k>1) s+=a[2]+0 }
                END{ printf "%.2f", s+0 }' "$OUTCAR")
sum_loopplus=$(awk '/LOOP\+:/{ k=split($0,a,"real time"); if(k>1) s+=a[2]+0 }
                    END{ printf "%.2f", s+0 }' "$OUTCAR")
nionic=$(grep -c 'LOOP+:' "$OUTCAR" 2>/dev/null); nionic="${nionic//[^0-9]/}"; nionic="${nionic:-0}"
# Mean electronic steps per ionic step -- 0 when the benchmark never completed an
# ionic step, which callers must read as "no estimate available".
scf_per_ionic=$(awk -v n="$nscf" -v i="$nionic" \
    'BEGIN{ if(i>0) printf "%.2f", n/i; else printf "0" }')
startup_s=$(awk -v w="$wall" -v e="$sum_loop" -v p="$sum_loopplus" \
    'BEGIN{ r=w-e-p; if(r<0) r=0; printf "%.1f", r }')

if posq "$maxrss_mb" && [[ -n "$RAW" ]]; then
    node_avail_gb=$(awk -v m="$NODE_MEM_MB" 'BEGIN{printf "%.0f", m/1024.0}')
    printf "  peak RAM / rank (MaxRSS) : %s MB   (heaviest single rank)\n" "$maxrss_mb"
    if posq "$averss_mb"; then
        printf "  mean RAM / rank (AveRSS) : %s MB   <- this is what sizes the request\n" "$averss_mb"
        awk -v i="$rss_imbalance" 'BEGIN{ if(i+0 >= 1.5)
            printf "  rank imbalance           : x%s  (one rank dominates; sizing from MaxRSS\n                             would over-reserve by this factor)\n", i }'
    else
        echo "  mean RAM / rank (AveRSS) : (unavailable -- sizing falls back to MaxRSS, conservative)"
    fi
    printf "  peak RAM / node (%s rk)  : %s GB   (of ~%s GB available)\n" \
        "$NTPN" "$peak_node_gb" "$node_avail_gb"
else
    echo "  SLURM MaxRSS    : (unavailable -- job accounting may be off)"
    echo "                    Falling back to VASP's own memory table for sizing."
    _wp_report_gap "memory was NOT measured; sizing fell back to VASP's own table" \
        "sacct returned no MaxRSS for job ${SLURM_JOB_ID}, so the real per-rank RSS" \
        "is unknown. The fallback is VASP's table, which is RANK-0's memory --" \
        "and rank 0 is the outlier on k-point-parallel layouts (it holds the" \
        "gathered all-k-point arrays), so this over-reserves." \
        "" \
        "Check that job accounting is enabled on this cluster:  sacct -j ${SLURM_JOB_ID}"
fi
printf "  VASP memory table / rank : %s MB   (rank-0, from OUTCAR)\n" "$vasp_tbl_mb"
if posq "$cpu_eff"; then
    printf "  CPU efficiency           : %s %%   (TotalCPU / (Elapsed x %s cores))\n" \
        "$cpu_eff" "$step_ncpus"
fi
printf "  SCF electronic steps     : %s in %ss\n" "$nscf" "$wall"
posq "$avg_loop" && printf "  avg wall / SCF step      : %s s\n" "$avg_loop"

# Quick human-readable verdict on the parallel efficiency.
echo
if posq "$cpu_eff"; then
    awk -v e="$cpu_eff" 'BEGIN{
        if(e>=85) print "  Verdict: parallel efficiency is GOOD (>=85%).";
        else if(e>=70) print "  Verdict: parallel efficiency is OK (70-85%); a different KPAR/NCORE may help.";
        else print "  Verdict: parallel efficiency is LOW (<70%); try the KPAR/NCORE below or fewer ranks." }'
fi

# --------------------------------------------------------------------------- #
# 5. Scale the MEASUREMENT to the production config, write slurm_vasptest.sh, report
#    (memory anchored to measured MaxRSS at the test scale, then projected to
#    the FIXED production rank count; cluster 80% rule applied.)
# --------------------------------------------------------------------------- #
PY="$(command -v python3 || command -v python || true)"
SELF_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
HELPER=""
for cand in "${VASP_TEST_RECOMMEND:-}" \
            "$SELF_DIR/vasp_test_recommend.py" \
            "$HOME/.local/bin/vasp_test_recommend.py" \
            "$HOME/Useful_scripts/vasp_test_recommend.py"; do
    [[ -n "$cand" && -f "$cand" ]] && { HELPER="$cand"; break; }
done

# Sanitise the numeric metrics (argparse needs clean ints/floats; a stray
# newline here would abort the whole STAGE 3 step).
maxrss_mb="${maxrss_mb//[!0-9.]/}"; maxrss_mb="${maxrss_mb:-0}"
averss_mb="${averss_mb//[!0-9.]/}"; averss_mb="${averss_mb:-0}"
cpu_eff="${cpu_eff//[!0-9.]/}"; cpu_eff="${cpu_eff:-0}"
avg_loop="${avg_loop//[!0-9.]/}"; avg_loop="${avg_loop:-0}"
nscf="${nscf//[!0-9]/}"; nscf="${nscf:-0}"
wall="${wall//[!0-9]/}"; wall="${wall:-0}"
NTASKS="${NTASKS//[!0-9]/}"; NTASKS="${NTASKS:-1}"

if [[ -z "$PY" || -z "$HELPER" ]]; then
    hdr "DONE (could not write slurm_vasptest.sh)"
    echo "  python3 and/or vasp_test_recommend.py were not found."
    echo "  MEASURED peak memory: ${maxrss_mb} MB/rank at ${NTASKS} ranks."
    echo "  Size production by hand: at ${PROD_RANKS} ranks request about"
    echo "  (measured x ${NTASKS}/${PROD_RANKS}) / ${MEM_UTIL} MB per rank."
    echo "  Benchmark outputs kept in: $RUNDIR"
    _wp_report_gap "no PREDICTED vs MEASURED comparison, and no slurm_vasptest.sh" \
        "The benchmark RAN and the measurement is good:" \
        "  peak RAM / rank : ${maxrss_mb} MB at ${NTASKS} ranks" \
        "  mean RAM / rank : ${averss_mb} MB" \
        "" \
        "What is missing is the write-up: python3 and/or vasp_test_recommend.py" \
        "could not be found, so nothing scaled the measurement to production and" \
        "no definitive job script was written." \
        "" \
        "Size production by hand: at ${PROD_RANKS} ranks request about" \
        "(measured x ${NTASKS}/${PROD_RANKS}) / ${MEM_UTIL} MB per rank." \
        "Benchmark outputs kept in: $RUNDIR"
    exit 4
fi

# --------------------------------------------------------------------------- #
# DID THE BENCHMARK ACTUALLY RUN?
#
# Three ways it can fail while still producing numbers that look like a
# measurement, and all three were being reported as ADEQUATE:
#
#   OOM       slurmstepd kills a task for exceeding --mem-per-cpu. VASP dies
#             during FFT planning, BEFORE it allocates the wavefunctions, so
#             the RSS recorded is a FLOOR the real run passes immediately.
#   exit code anything outside {0, 124, 137}. 124/137 are the benchmark's own
#             timeout stopping VASP on purpose, which is the normal path.
#   no steps  zero 'LOOP:' lines means not one electronic step completed, so
#             whatever was measured is the setup, not the calculation.
#
# The OOM signal comes from two places because either can be missing: sacct's
# State (OUT_OF_MEMORY) needs accounting to have caught up, and slurmstepd's
# message lands in the job's stderr whether it did or not.
bench_oom=0
if [[ -n "${RAW:-}" ]] && printf '%s\n' "$RAW" | awk -F'|' '$2 ~ /OUT_OF_ME/ {f=1} END{exit !f}'; then
    bench_oom=1
fi
for _e in "$SUBMIT_DIR"/.wolfpack/benchmark-*.err "$SUBMIT_DIR"/.wolfpack/vasptest-*.err; do
    [[ -s "$_e" ]] || continue
    grep -qiE 'oom[-_]kill|Out Of Memory' "$_e" 2>/dev/null && { bench_oom=1; break; }
done

bench_why=""
if (( bench_oom )); then
    # SLURM_MEM_PER_CPU is what the job was actually granted, set by SLURM
    # inside the allocation. The mempc computed when the script was rendered
    # lives on the login node and is not in scope here.
    bench_why="the benchmark was OOM-killed (a task exceeded --mem-per-cpu=${SLURM_MEM_PER_CPU:-?} MB)"
elif [[ $rc -ne 0 && $rc -ne 124 && $rc -ne 137 ]]; then
    bench_why="VASP exited with code $rc"
elif (( nscf == 0 )); then
    bench_why="VASP completed no electronic step in ${wall}s"
fi

# vasp-test OUTPUTS a NEW production job (slurm_vasptest.sh) that REFINES recommend's
# slurm.sh with the REAL measured memory; slurm.sh is left as the first-pass record.
# On a failed benchmark it is NOT created: a file that looks validated and is not
# is worse than no file.
DEFINITIVE="$SUBMIT_DIR/slurm_vasptest.sh"
if [[ -z "$bench_why" ]]; then
    cp -f "$SUBMIT_DIR/slurm.sh" "$DEFINITIVE" 2>/dev/null || true
fi
mkdir -p "$SUBMIT_DIR/.wolfpack"
HOUT="$SUBMIT_DIR/.wolfpack/helper.out"
"$PY" "$HELPER" "$OUTCAR" \
    --maxrss-mb "$maxrss_mb" --averss-mb "$averss_mb" --ntasks-test "$NTASKS" \
    --test-kpar "$FIX_KPAR" --test-ncore "$FIX_NCORE" --test-npar "$TEST_NPAR" \
    --prod-ranks "$PROD_RANKS" --prod-kpar "$FIX_KPAR" --prod-ncore "$FIX_NCORE" \
    --prod-npar "$FIX_NPAR" --prod-nsim "$FIX_NSIM" \
    --prod-partition "$PROD_PARTITION" --cpus-per-node "$PROD_CPN" \
    --max-cores "${WP_MAX_CORES:-0}" \
    --alloc-profile "${WP_ALLOC_PROFILE:-whole-nodes}" \
    --node-mem-mb "$PROD_NODE_MEM" --mem-util "$MEM_UTIL" \
    --pred-peak-mb "${pred_mem_per_rank:-0}" --pred-flat-mb "${pred_flat_mb:-0}" \
    --pred-mem-per-cpu "${mem_per_cpu:-0}" --pred-nodes "${pred_nodes:-0}" --pred-ntpn "${pred_ntpn:-0}" \
    --cpu-eff "$cpu_eff" --avg-loop "$avg_loop" --nscf "$nscf" --wall "$wall" \
    --bench-failed "$bench_why" \
    $( ((IS_GW)) && printf -- '--gw --gw-node-frac %s --incar %s' "${WP_GW_NODE_FRAC:-0.67}" "$SUBMIT_DIR/INCAR" ) \
    $( [[ -z "$bench_why" ]] && printf -- '--update-slurm %s' "$DEFINITIVE" ) \
    --report "$SUBMIT_DIR/report.out" 2>&1 | tee "$HOUT"
_rc=${PIPESTATUS[0]}

if (( _rc == 7 )); then
    # AUTO-RECOVERY: the MEASURED memory makes the chosen k-group too big for a node.
    # Re-invoke recommend CALIBRATED to that measurement so it re-picks a feasible
    # config (rewrites slurm.sh + INCAR + state.env); the user then re-runs vasp-test.
    rm -f "$DEFINITIVE"
    _ln=$(grep -m1 '^WP_REPICK ' "$HOUT")
    _mb=$(sed -nE 's/.*measured_mb=([0-9.]+).*/\1/p' <<<"$_ln")
    _rr=$(sed -nE 's/.*ref_ranks=([0-9]+).*/\1/p' <<<"$_ln")
    _rk=$(sed -nE 's/.*ref_kpar=([0-9]+).*/\1/p' <<<"$_ln")
    REC=""
    for c in "${VASP_RECOMMEND:-}" "$(command -v vasp-recommend-slurm 2>/dev/null)" \
             "$SELF_DIR/vasp_recommend_slurm.py"; do
        [[ -n "$c" && -f "$c" ]] && { REC="$c"; break; }
    done
    hdr "RE-SELECTING -- measured memory makes KPAR=${_rk} infeasible on this cluster"
    # Replay the arguments the recommendation was first made with, or the
    # re-pick silently uses the profile defaults and answers a different
    # question than the one the user asked (a different --max-cores gives a
    # different table). Same reason `-n N` replays them.
    eval "set -- ${rec_args:-}"
    if [[ -n "$REC" ]] && ( cd "$SUBMIT_DIR" && "$PY" "$REC" "$@" \
            --gw-mem-per-rank "$_mb" --gw-ref-ranks "$_rr" --gw-ref-kpar "$_rk" ); then
        { echo 'stage="recommend"'; } >> "$SUBMIT_DIR/.wolfpack/state.env" 2>/dev/null || true
        echo "  Re-picked a FEASIBLE config (INCAR + slurm.sh + state.env updated)."
        if [[ "${pick:-1}" != "1" ]]; then
            echo "  NOTE: you had asked for candidate ${pick}; it does not fit at the"
            echo "        MEASURED memory, so this is the best one that does."
        fi
        echo "  RE-RUN to benchmark the new config:   vasp-test"
    else
        hdr "CANNOT RECOVER -- no parallelization fits this cluster at the measured memory"
        echo "  See recommend's message above: lower ENCUTGW/NOMEGA/NBANDS, or use a"
        echo "  higher-memory partition. The benchmark outputs are in: $RUNDIR"
        echo "  end: $(date)"; exit 3
    fi
elif (( _rc == 0 )); then
    # Tidy: keep the folder clean -- the benchmark run dir lives under .wolfpack.
    if [[ -d "$RUNDIR" ]]; then
        cp -f "$OUTCAR" "$SUBMIT_DIR/.wolfpack/vasptest_OUTCAR" 2>/dev/null || true
        rm -rf "$RUNDIR"
    fi
    # Persist what the benchmark MEASURED, not just that it ran. These numbers are
    # the only per-step rate the pipeline ever obtains, and until now they reached
    # report.out as prose and nothing else -- unreadable to any later stage.
    #
    # Health warning for consumers, encoded in test_lwave: the benchmark runs with
    # LWAVE/LCHARG force-appended as .FALSE. on a throwaway INCAR, on the DEBUG
    # partition, at test_ranks rather than the production count. So test_avg_loop
    # contains NO WAVECAR I/O and is not a production per-step time. Treat it as a
    # first estimate to be replaced by a real measurement, never as ground truth.
    #
    # stage= stays LAST: consumers `source` this file, so the last assignment wins.
    {
        echo "test_avg_loop=\"${avg_loop}\""
        echo "test_nscf=\"${nscf}\""
        echo "test_nionic=\"${nionic}\""
        echo "test_scf_per_ionic=\"${scf_per_ionic}\""
        echo "test_wall=\"${wall}\""
        echo "test_startup_s=\"${startup_s}\""
        echo "test_cpu_eff=\"${cpu_eff}\""
        echo "test_ranks=\"${NTASKS}\""
        # NOT $part: that is set in the launcher branch, which ends at `exec sbatch`
        # and never reaches this code. Inside the job it is unset, and with `set -u`
        # referencing it would abort the job outright. SLURM exports the real one.
        echo "test_partition=\"${SLURM_JOB_PARTITION:-}\""
        echo "test_lwave=\"F\""
        echo 'stage="test"'
    } >> "$SUBMIT_DIR/.wolfpack/state.env" 2>/dev/null || true
    hdr "DONE -- pipeline complete"
    echo "  DEFINITIVE job (measured memory): $DEFINITIVE   <- submit this"
    echo "  recommend's first pass kept as  : $SUBMIT_DIR/slurm.sh"
    echo "  (KPAR/NCORE were applied to INCAR by vasp-recommend-slurm; backup INCAR.bak)"
    echo "  Full report        : $SUBMIT_DIR/report.out"
else
    rm -f "$DEFINITIVE"
    hdr "DONE (scaling step failed -- see the error above)"
    echo "  The benchmark succeeded; only the scaling/update step failed."
    echo "  MEASURED peak memory: ${maxrss_mb} MB/rank at ${NTASKS} ranks."
    echo "  Benchmark outputs kept in: $RUNDIR"
fi
echo "  end: $(date)"
