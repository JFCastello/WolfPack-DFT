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
#   ... --resume                # continue a stopped OR DEAD chain -- after an
#                               # OOM kill it raises the memory by itself
#   ... --fresh                 # archive an unfinished chain and start over
#   ... --walltime MIN          # force the chunk walltime (skips the study)
#   ... --no-queue-study        # use the profile's chunk walltime as is
#
# THE CHUNK WALLTIME is chosen once, at launch, and then fixed for the whole
# chain: from --walltime if given, else from `backfill-study` -- what this
# partition's queue has done to jobs shaped like this one -- else from
# WP_CHUNK_WALLTIME_MIN. Run `backfill-study` on its own to see that analysis
# without launching anything. If not even ONE ionic step fits in the chunk,
# the chain refuses to start -- and stops, rather than submit a chunk that
# cannot progress, if a step later grows past it.
#
# THE ONLY LIMIT is your own NSW (NELM for vasp-scf-loop): the whole chain
# spends at most that many steps. There is no cap on the number of chunks, on
# the compute accumulated, or on the days the chain has been running.
#
# MEMORY is measured after every chunk (sacct, or VASP's own OUTCAR footer)
# and the next chunk's --mem-per-cpu is rewritten from it. When the ranks no
# longer fit a node, they are spread over more nodes; the rank count, and so
# KPAR/NCORE, never changes under a running relaxation.
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

# The whole header, up to its closing rule: a fixed line range silently cut
# the options off as the header grew.
usage(){ awk 'NR == 1 { next } /^#####/ { if (++n == 2) exit; next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

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
        --study)       die "the queue study is its own command now: run  backfill-study  here." 2 ;;
        --fresh)       OPT_FRESH=1; shift ;;
        --no-queue-study) OPT_NOSTUDY=1; shift ;;
        --now)         STOP_NOW=1; shift ;;
        --walltime)    OPT_WALLTIME="${2:?}"; shift 2 ;;
        --force)       OPT_FORCE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1  (try --help)" 2 ;;
    esac
done
STOP_NOW="${STOP_NOW:-0}"; OPT_FORCE="${OPT_FORCE:-0}"
OPT_FRESH="${OPT_FRESH:-0}"; OPT_NOSTUDY="${OPT_NOSTUDY:-0}"
[[ -n $MODE ]] || die "cannot tell which mode to run: invoke as vasp-scf-loop or vasp-relax-loop" 2
[[ $MODE == scf || $MODE == relax ]] || die "unknown mode: $MODE" 2
# The name the user types. $0 is that only through the ~/.local/bin symlink;
# the rendered chunk job, and anyone calling the real path, see vasp_chain.sh.
CMD="vasp-${MODE}-loop"

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
NELM_FLOOR=8                  # a chunk holding fewer steps than this is pointless
NELM_CEIL=500
SAFETY=1.15                   # per-step time is a prediction; leave room
SIGNAL_LEAD=120               # seconds of warning before the walltime kill
COLD_FACTOR=1.5               # chunk 1 absorbs the cold start: size it with this
# Memory. MEM_SAFETY is headroom over what the previous chunk MEASURED; it is not
# a guess at a requirement, which is measured. OOM_FACTOR is how far the request
# is raised after an OOM kill -- a retry policy, like a back-off, because a kill
# says only that the need was ABOVE the grant, never by how much.
MEM_SAFETY="${WP_CHAIN_MEM_SAFETY:-1.25}"
OOM_FACTOR="${WP_CHAIN_OOM_FACTOR:-1.5}"
MEM_FLOOR_MB=256
SACCT_POLL_S=45               # accounting lags a finished step by a few seconds
QUEUE_DAYS="${WP_CHAIN_QUEUE_DAYS:-30}"

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

int(){ local v="${1//[^0-9-]/}"; echo "${v:-0}"; }
# Seconds that may carry a decimal, rounded. int() would strip the point:
# vasp-test writes its start-up time as "58.3", which int() reads as 583.
secs(){ awk -v v="$1" 'BEGIN{ v += 0; if (v < 0) v = 0; printf "%d", v + 0.5 }'; }
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
# Queue and memory helpers.  Pure bash/awk, like contcar_ok: they run inside
# the compute job too, where only VASP's modules are loaded.
# --------------------------------------------------------------------------- #
# The partition's MaxTime, in minutes; empty when unlimited or unknown. A chunk
# walltime above it is a job the scheduler rejects at submit -- which, inside a
# running chain, is a chain that dies at a chunk boundary.
part_maxtime_min(){
    local v
    v=$(scontrol show partition "$1" 2>/dev/null | grep -oE 'MaxTime=[^ ]+' | head -1 | cut -d= -f2)
    [[ -z $v || $v == UNLIMITED || $v == INFINITE || $v == NONE ]] && return 0
    awk -v t="$v" 'BEGIN{ d=0; if (split(t, a, "-") == 2) { d = a[1]; t = a[2] }
        m = split(t, b, ":")
        if (m == 3)      printf "%d", d*1440 + b[1]*60 + b[2]
        else if (m == 2) printf "%d", d*1440 + b[1]
        else             printf "%d", d*1440 + b[1] }'
}

# Rank 0's peak RSS in MB, from VASP's own timing footer
#     "Maximum memory used (kb):       48456."
# Rank 0 is normally the heaviest rank (it gathers the all-k-point arrays), so
# this is a fair stand-in for the peak when accounting has nothing.
outcar_maxmem_mb(){
    awk '/Maximum memory used \(kb\):/{ v = $5 + 0 }
         END{ if (v > 0) printf "%.0f", v/1024 }' "${1:-OUTCAR}" 2>/dev/null
}

# sacct's word on one job:  "STATE MAXRSS_MB AVERSS_MB"  (numbers 0 if unknown).
# --units=M everywhere, so nothing has to guess whether a bare number is KB.
# Polls up to $2 seconds, because a step that just ended reaches the database a
# few seconds later.
job_mem_evidence(){
    local jid="$1" poll="${2:-0}" deadline raw
    [[ -n $jid ]] && command -v sacct >/dev/null 2>&1 || { echo "UNKNOWN 0 0"; return 0; }
    deadline=$(( $(date +%s) + poll ))
    while :; do
        raw=$(sacct -j "$jid" --units=M -n -P -o JobID,State,MaxRSS,AveRSS 2>/dev/null)
        # sacct FAILING is not sacct LAGGING: a cluster with accounting disabled
        # answers the same way every time, and waiting on it would cost every
        # chunk the whole poll for nothing.
        (( $? != 0 )) && break
        printf '%s\n' "$raw" | awk -F'|' '$1 ~ /\.[0-9]+$/ && $3 ~ /[0-9]/ {f=1} END{exit !f}' && break
        # A step already recorded as FINISHED with no MaxRSS will never get one:
        # slurmctld sends a step's usage to the database WITH its completion, not
        # after. Where steps are recorded without RSS (this suite's testbed
        # does that), waiting cost every chunk the whole poll.
        printf '%s\n' "$raw" | awk -F'|' '
            $1 ~ /\.[0-9]+$/ { n++; if ($2 ~ /^(COMPLETED|FAILED|CANCELLED|OUT_OF_ME|TIMEOUT|NODE_FAIL|PREEMPTED|DEADLINE)/) t++ }
            END { exit !(n > 0 && t == n) }' && break
        (( $(date +%s) >= deadline )) && break
        sleep 3
    done
    printf '%s\n' "$raw" | awk -F'|' '
        function mb(x,   u, v) { gsub(/[^0-9.KMGT]/, "", x); if (x == "") return 0
            u = substr(x, length(x)); v = x + 0
            if (u == "K") return v/1024; if (u == "G") return v*1024
            if (u == "T") return v*1048576; return v }
        $1 !~ /\./ { st = $2; sub(/ .*/, "", st) }          # "CANCELLED by 1000" -> CANCELLED
        $2 ~ /OUT_OF_ME/ { oom = 1 }
        $1 ~ /\.[0-9]+$/ { m = mb($3); if (m > mx) mx = m; a = mb($4); if (a > av) av = a }
        END { if (oom) st = "OUT_OF_MEMORY"; if (st == "") st = "UNKNOWN"
              printf "%s %.0f %.0f\n", st, mx, av }'
}

# The job's own stderr, wherever the chain has filed it by now. slurmstepd
# writes its verdict there whether or not accounting caught up.
err_mentions(){   # err_mentions JID REGEX
    local f
    for f in "VASP-chain-$1.err" "$CHDIR"/chunk-*/"VASP-chain-$1.err"; do
        [[ -s $f ]] && grep -qiE "$2" "$f" 2>/dev/null && return 0
    done
    return 1
}
OOM_RX='oom[-_]kill|Out Of Memory|exceeded memory limit'
TIMEOUT_RX='DUE TO TIME LIMIT'

# MB per CPU the next chunk should be granted, from what a chunk USED.
#
# SLURM limits the TOTAL of a job's tasks on each node, not each task: with
# task/cgroup and ConstrainRAMSpace=yes the cgroup limit is "the allocated
# memory" of the job on that node -- see cgroup.conf(5). So the requirement is
# the heaviest NODE's total. The node holding rank 0, which carries the
# gathered all-k-point arrays and runs at about twice the mean, totals roughly
#     max_rss + (ntpn - 1) x ave_rss        spread over ntpn CPUs.
# With no mean (VASP's OUTCAR only knows rank 0) every rank is taken to be as
# heavy as rank 0: with rank 0 normally the heaviest, that errs toward more.
# For a cell relaxation the next cell can be larger, and the plane-wave count
# at fixed ENCUT grows with the volume, so the volume ratio scales it too.
need_mem_per_cpu(){   # need_mem_per_cpu MAXRSS AVERSS NTPN VOLRATIO
    awk -v mx="$1" -v av="$2" -v n="$3" -v vr="$4" -v s="$MEM_SAFETY" -v f="$MEM_FLOOR_MB" 'BEGIN{
        if (n < 1) n = 1; if (vr < 1) vr = 1
        if (av <= 0 || av > mx) av = mx
        v = (mx + (n - 1) * av) / n * vr * s
        if (v < f) v = f
        printf "%d", int((v + 49) / 50) * 50 }'
}

# Lay RANKS out so each gets MEMCPU MB.  Prints "nodes ntpn exact" or, when it
# cannot be done, a reason on stdout and returns 1.
#
# The RANK COUNT never changes: KPAR and NCORE in the INCAR were chosen for it,
# and changing it would change the parallel decomposition under a running
# calculation. What may change is how many nodes the ranks spread over --
# fewer ranks per node is exactly how each one gets more memory. The layout
# never shrinks below the node count the chain started with.
fit_layout(){   # fit_layout RANKS MEMCPU
    awk -v R="$1" -v M="$2" -v nm="${chain_node_mem_mb:-0}" -v mg="${chain_mem_margin:-0}" \
        -v cpn="${chain_cpn:-1}" -v cap="${chain_max_cores:-0}" \
        -v prof="${chain_profile:-whole-nodes}" -v n0="${chain_nodes0:-1}" 'BEGIN{
        usable = int(nm * (1 - mg))
        if (usable <= 0) { print "the profile gives no memory per node"; exit 1 }
        fit = int(usable / M); if (fit > cpn) fit = cpn
        if (fit < 1) {
            printf "one rank alone needs %d MB, and a node offers %d MB after its margin", M, usable
            exit 1 }
        n = int((R + fit - 1) / fit); if (n < n0) n = n0
        if (prof == "balanced") {
            # equal occupancy: n must divide R. Look a little further, then give up
            # on evenness rather than on the chain.
            for (k = n; k <= n + 8; k++) if (R % k == 0 && R / k <= fit) { n = k; break }
        }
        t = int((R + n - 1) / n); ex = (n * t == R ? 1 : 0)
        if (cap > 0) {
            cost = (prof == "balanced" ? R : n * cpn)
            if (cost > cap) {
                printf "%d rank(s) at %d MB each need %d node(s) (%d cores charged), over the %d-core cap", \
                       R, M, n, cost, cap
                exit 1 } }
        printf "%d %d %d", n, t, ex }'
}

# Settle the request and the layout together: the need depends on the ranks
# per node (rank 0's excess is shared by fewer CPUs when there are fewer of
# them) and the layout on the need. Fewer ranks per node only ever raises the
# need, so this converges in a step or two. FLOOR is a lower bound on the
# request (an OOM's escalation). Sets SM_NEED SM_NODES SM_NTPN SM_EXACT, or
# SM_NEED and SM_WHY and returns 1 when no layout holds it. Called directly,
# not in $( ), so that it can set them.
settle_memory(){   # settle_memory PEAK AVE RANKS NTPN VOLRATIO FLOOR
    local t="$4" lay i
    SM_WHY=""
    for i in 1 2 3 4 5; do
        SM_NEED=$(need_mem_per_cpu "$1" "$2" "$t" "$5")
        (( $(int "$6") > SM_NEED )) && SM_NEED=$(int "$6")
        if ! lay=$(fit_layout "$3" "$SM_NEED"); then SM_WHY=$lay; return 1; fi
        read -r SM_NODES SM_NTPN SM_EXACT <<<"$lay"
        (( SM_NTPN == t )) && break
        t=$SM_NTPN
    done
    return 0
}

# The shortest chunk walltime, in whole minutes, that leaves room for one ionic
# step of T seconds x FACTOR after the start-up and the chunk margin -- which
# is the larger of the configured one and 8 % of the walltime, as at launch.
walltime_for_step(){   # walltime_for_step T FACTOR STARTUP_S MARGIN_CFG_MIN
    awk -v t="$1" -v f="$2" -v s="$3" -v m="$4" 'BEGIN{
        for (w = 1; w <= 100000; w++) { mg = m; if (int(w * 0.08) > mg) mg = int(w * 0.08)
            if (w * 60 - mg * 60 - s >= t * f) { print w; exit } } }'
}

# Rewrite the rendered chunk's allocation in place: --mem-per-cpu, --nodes and
# the --ntasks-per-node line (or the comment that stands in for it when the
# split is uneven). Everything else in the job is left exactly as rendered.
rewrite_allocation(){   # rewrite_allocation MEMCPU NODES NTPN EXACT RANKS
    local tmp="$CH_JOB.new"
    awk -v m="$1" -v n="$2" -v t="$3" -v ex="$4" -v r="$5" '
        /^#SBATCH --mem-per-cpu=/        { print "#SBATCH --mem-per-cpu=" m; next }
        /^#SBATCH --nodes=/              { print "#SBATCH --nodes=" n; next }
        /^#SBATCH --ntasks-per-node=/ || /^# no --ntasks-per-node/ {
            if (ex == 1) print "#SBATCH --ntasks-per-node=" t
            else printf "# no --ntasks-per-node: %d ranks do not divide evenly over %d node(s)\n", r, n
            next }
        { print }' "$CH_JOB" > "$tmp" && mv -f "$tmp" "$CH_JOB" && chmod +x "$CH_JOB"
}

# --------------------------------------------------------------------------- #
# Control verbs
# --------------------------------------------------------------------------- #
if [[ $ACTION == status ]]; then
    [[ -f "$CH_ENV" ]] || die "no chain here ($CH_ENV not found)." 3
    state_load
    hdr "Chunked run -- ${chain_kind:-?}"
    kv "state"           "${chain_state:-?}${stop_reason:+  (${stop_reason})}"
    kv "chunks done"     "${chunk_index:-0}"
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
        _nelm_use=$(int "${nelm_target:-60}")
        if (( recovery )); then
            # The chain never caps NELM, so running out of it means the USER's own
            # NELM was not enough at that geometry -- a convergence problem, not
            # something the chunking caused. Taking one cautious step is therefore
            # not a fix on its own: with the same budget it would most likely run
            # out again. Raise it for this one step, which is the only change that
            # addresses the cause.
            _nelm_use=$(awk -v n="$_nelm_use" -v c="$NELM_CEIL" \
                        'BEGIN{ v=int(n*1.5); if(v>c)v=c; if(v<n)v=n; print v }')
            say "recovery chunk: one ionic step, NELM raised ${nelm_target} -> ${_nelm_use}"
            note "the previous chunk's last ionic step ran out of NELM, so its forces were"
            note "unreliable and VASP moved the ions with them. This converges the electrons"
            note "at the geometry actually reached before taking any further ionic step."
            state_set nelm_recovery "$_nelm_use"
        fi
        incar_set NELM "$_nelm_use" \
                       "full electronic budget: a truncated SCF gives wrong forces"
    fi

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
              last_elapsed_s "$elapsed" next_cold_start 0
    # A complete WAVECAR's size, for --resume: a later chunk that dies while
    # writing leaves one of a different size, and that is how it is recognised.
    if [[ -s WAVECAR ]] && (( $(stat -c %Y WAVECAR 2>/dev/null || echo 0) >= chunk_start )) \
       && (( rc == 0 )) && (( footer == 1 )); then
        state_set wavecar_bytes "$(stat -c %s WAVECAR 2>/dev/null || echo 0)"
    fi
    if [[ $MODE == relax ]]; then
        state_set nsw_done "$(( $(int "${nsw_done:-0}") + ionic ))" \
                  last_fmax "${fmax:-}" t_ionic_s "${t_ionic:-0}" \
                  t_ionic_measured "$(awk -v t="${t_ionic:-0}" 'BEGIN{ print (t > 0) ? 1 : 0 }')" \
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
            # Does ONE step still fit? The walltime is fixed for the whole chain,
            # and the cap above is clamped to at least 1 -- so without this, a step
            # that has grown past the chunk (a cell relaxation's basis grows with
            # the volume; a harder geometry needs more SCF steps) would be handed
            # a chunk it cannot complete, at the cost of a queue wait and a
            # walltime of core-hours, again and again.
            if awk -v t="${t_ionic:-0}" 'BEGIN{exit !(t>0)}'; then
                _nfit=$(awk -v b="$budget" -v t="$t_ionic" -v s="$SAFETY" 'BEGIN{ print int(b/(t*s)) }')
                if (( _nfit < 1 )); then
                    verdict="STOP"; reason="step_exceeds_chunk"
                    detail="one ionic step now takes ${t_ionic}s; the fixed ${chain_wall_min:-?}-min chunk leaves ${budget}s"
                fi
            fi
        fi
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
        # The ONLY budget is the user's own NSW (NELM for an SCF chain): no cap
        # on chunks, accumulated compute or calendar days. Those used to stop a
        # long relaxation part-way, and --resume could not renew them.
        if [[ $MODE == scf ]] && (( steps == 0 )); then
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

    # ---- memory for the NEXT chunk --------------------------------------------
    # Measured, not assumed. The largest peak ever seen is never forgotten, so
    # one quiet chunk cannot talk the request down below what an earlier one
    # needed. For a cell relaxation the next cell's volume scales it: at fixed
    # ENCUT the plane-wave count grows with the volume.
    mem_next="$(int "${chain_mem_per_cpu:-$mem_granted}")"
    if (( mem_max > 0 )); then
        _pk=$(( mem_max > $(int "${mem_peak_max_mb:-0}") ? mem_max : $(int "${mem_peak_max_mb:-0}") ))
        _av=$(( mem_ave > $(int "${mem_ave_max_mb:-0}") ? mem_ave : $(int "${mem_ave_max_mb:-0}") ))
        state_set mem_peak_max_mb "$_pk" mem_ave_max_mb "$_av" \
                  last_mem_peak_mb "$mem_max" last_mem_src "$mem_src"
        if [[ $verdict == CONTINUE ]]; then
            _vr=1
            if [[ $MODE == relax ]] && (( $(int "${chain_isif:-2}") >= 3 )) \
               && contcar_ok CONTCAR POSCAR >/dev/null 2>&1; then
                _vr=$(awk -v a="$(cell_volume POSCAR)" -v b="$(cell_volume CONTCAR)" \
                      'BEGIN{ printf "%.4f", (a>0 && b>a ? b/a : 1) }')
            fi
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

    # ---- advance the geometry (relax only) ----------------------------------
    # Ordering matters and is deliberate: the chunk is already archived, so this
    # runs AFTER the record is safe and BEFORE the successor is submitted. A
    # death before the sbatch leaves a folder that resumes; after it, a folder
    # with a successor already running. There is no moment where both are true.
    #
    # A static run never touches POSCAR, and its CONTCAR is 0 bytes by design.
    #
    # A stop decided about the NEXT chunk -- it would not fit the walltime, the
    # memory or the budget -- comes after THIS one ran to completion, and its
    # geometry is as good as a CONTINUE's. Leaving POSCAR a chunk behind meant
    # the way out of such a stop (a new chain, --fresh) silently redid it.
    _adv=0
    [[ $verdict == CONTINUE || $verdict == CONVERGED ]] && _adv=1
    [[ $verdict == STOP ]] && case $reason in
        step_exceeds_chunk|memory_does_not_fit|budget_drift|nsw_budget) _adv=1 ;;
    esac
    if [[ $MODE == relax ]] && (( _adv )); then
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
                 "$elapsed" "$frac" "$mem_max" "$mem_granted" "$verdict" "${detail}${_sig}"
    else
        log_line "$idx" "${SLURM_JOB_ID:-?}" "SCF" "$cap" "$steps" "$t_step" "$elapsed" \
                 "$frac" "$mem_max" "$mem_granted" "$verdict" "${detail}${_sig}"
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
            note "quoting energies. vasp-check's 'Forces and stress at this geometry' shows it."
        fi
        # The physics verdict, so it is waiting when the user wakes up.
        command -v vasp-check >/dev/null 2>&1 && { echo; vasp-check 2>&1 | tail -40; }
        # One 'finished' mail from the last chunk only.
        scontrol update "JobId=${SLURM_JOB_ID:-0}" MailType=END,FAIL >/dev/null 2>&1
        exit 0
    fi

    if [[ $verdict == CONTINUE ]]; then
        state_set next_cap "$newcap" chain_state running next_is_recovery "$next_recovery"
        # A relaxation counts IONIC steps: electronic steps over NELM read there as
        # "25/60 steps" of a 30-step NSW.
        if [[ $MODE == relax ]]; then
            say "not converged yet (${ionic} ionic step(s) in this chunk, $(int "${nsw_done:-0}") of ${nsw_target:-?} done); submitting chunk $((idx+1)) with cap ${newcap}"
        else
            say "not converged yet (${steps}/${nelm_eff} electronic steps); submitting chunk $((idx+1)) with cap ${newcap}"
        fi
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
        log_line "$idx" "${SLURM_JOB_ID:-?}" "$( [[ $MODE == relax ]] && echo RELAX || echo SCF)" \
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
        # Named by MODE: this used to map the script name to vasp-scf-loop, so a
        # stopped RELAXATION told the user to resume it with the SCF command.
        if [[ $reason == step_exceeds_chunk ]]; then
            _wn=$(walltime_for_step "$t_ionic" "$SAFETY" "$(secs "${t_startup_s:-120}")" \
                                    "$(int "${chain_margin_cfg_min:-$DEF_MARGIN_MIN}")")
            echo "--resume cannot continue this chain: its chunk walltime (${chain_wall_min:-?} min) is"
            echo "fixed, and one step no longer fits in it. POSCAR holds the geometry reached."
            echo "Start a new chain from there, with a chunk that holds one step:"
            echo "               vasp-${MODE}-loop --fresh --walltime ${_wn:-<min>}"
        elif [[ $reason == memory_does_not_fit ]]; then
            echo "--resume cannot continue this chain on this partition: ${detail}."
            echo "What frees memory, in order: a lower KPAR in the INCAR (each k-point group"
            echo "keeps its own copy of the charge density and grids), fewer ranks, LREAL = Auto."
            echo "POSCAR holds the geometry reached. Then:   vasp-${MODE}-loop --fresh"
        else
            echo "Resume with:   vasp-${MODE}-loop --resume"
        fi
        if [[ $reason == oom ]]; then
            _nx=$(awk -v g="$mem_granted" -v f="$OOM_FACTOR" 'BEGIN{ printf "%d", int((g*f+49)/50)*50 }')
            echo "               --resume raises the memory by itself: at least ${mem_granted} -> ${_nx} MB/cpu,"
            echo "               more if the measurements say so, spreading over more nodes if a"
            echo "               node cannot hold it. The geometry reached so far is kept."
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

hdr "Chunked $([[ $MODE == relax ]] && echo relaxation || echo SCF) -- setup"

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
# Estimated BEFORE the walltime is chosen: the walltime has to be able to hold
# a step, and the queue study weighs how many steps each candidate holds.
#
# The benchmark ran on the debug partition, at a different rank count, with
# LWAVE/LCHARG off -- so its rate is a starting estimate, not a measurement of
# this job. Chunk 1 is deliberately conservative and recalibrates from reality.
CAL=$(awk -v t="$t_e" -v tr="${test_ranks:-0}" -v pr="$RANKS" -v eff="${test_cpu_eff:-100}" \
      'BEGIN{ r=(tr>0&&pr>0? tr/pr : 1); e=eff/100; if(e<0.3)e=0.3; if(e>1)e=1;
              printf "%.3f", t*r/e }')
T_ION=0; SPI=0; SPI_SRC=""
if [[ $MODE == relax ]]; then
    # An IONIC step costs several electronic ones, and the benchmark rarely
    # completed even one -- so chunk 1 estimates, and only chunk 1. From chunk 2
    # the cost is read straight off VASP's own LOOP+ lines, one per ionic step.
    #
    # NELMIN is the floor, not a detail: VASP performs at least that many
    # electronic steps per ionic step however good the restart is.
    SPI=$(fnum "${test_scf_per_ionic:-0}")
    _nelmin=$(int "$(incar_get NELMIN)"); (( _nelmin < 2 )) && _nelmin=2
    SPI_SRC="measured by vasp-test"
    awk -v s="$SPI" 'BEGIN{exit !(s>0)}' || SPI_SRC="ASSUMED -- vasp-test never finished an ionic step"
    SPI=$(awk -v s="$SPI" -v nm="$_nelmin" 'BEGIN{
              if(s<=0) s=12;                  # no measurement: a common mid-range
              if(s<nm) s=nm; if(s>25) s=25;   # clamp: the estimate is weak either way
              printf "%.1f", s }')
    # +15% for the force/stress evaluation and the CONTCAR/XDATCAR writes.
    T_ION=$(awk -v t="$CAL" -v s="$SPI" 'BEGIN{printf "%.1f", t*s*1.15}')
fi
# Which step cost decides whether one step FITS. A fresh chain has only the
# estimate, and its first ionic step starts cold -- several times the steady
# state -- hence the cold-start factor. A resumed chain has measured its own
# steps, warm, and those are what the next chunk will actually take.
T_FIT="$T_ION"; FIT_FACTOR="$COLD_FACTOR"; FIT_SRC="estimated from the benchmark"
FIT_WHY="a first chunk starts cold, so it must hold ${COLD_FACTOR} x that"
# t_ionic_s starts as the launch ESTIMATE; only a chunk's own LOOP+ makes it a
# measurement. A chain from before that flag existed has measured once it has
# run a chunk.
if [[ -n ${t_ionic_measured+x} ]]; then _tmeas=$(int "$t_ionic_measured")
else _tmeas=$(( $(int "${chunk_index:-0}") >= 1 ? 1 : 0 )); fi
if [[ $ACTION == resume ]] && (( _tmeas )) && awk -v t="${t_ionic_s:-0}" 'BEGIN{exit !(t>0)}'; then
    T_FIT="${t_ionic_s}"; FIT_FACTOR="$SAFETY"; FIT_SRC="measured by the chain's own chunks"
    FIT_WHY="with the chain's ${SAFETY} x timing margin a chunk must hold"
fi

# ---- the chunk walltime: chosen ONCE, then fixed for the whole chain ---------
MARGIN_CFG=$(int "${WP_CHUNK_MARGIN_MIN:-$DEF_MARGIN_MIN}")
STARTUP=$(secs "${test_startup_s:-120}")
DEFAULT_WALL=$(int "${WP_CHUNK_WALLTIME_MIN:-$DEF_WALLTIME_MIN}")
_wp_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
STUDY_REPORT=""; WALL_SRC=""
_nsw_left=$(( nsw - $(int "${nsw_done:-0}") )); (( _nsw_left < 1 )) && _nsw_left=1
if [[ $ACTION == resume ]] && [[ -n ${chain_wall_min:-} ]]; then
    WALL=$(int "$chain_wall_min"); WALL_SRC="fixed at launch (${chain_wall_source:-?})"
    [[ -n ${OPT_WALLTIME:-} ]] && warn "--walltime is ignored on --resume: a chain keeps the chunk walltime it
     started with (${WALL} min). Use --fresh to start a new chain with a different one."
elif [[ -n ${OPT_WALLTIME:-} ]]; then
    # Whole minutes only: int() would read "1:30" as 130 and "90.5" as 905.
    [[ $OPT_WALLTIME =~ ^[0-9]+$ ]] && (( OPT_WALLTIME > 0 )) || \
        die "--walltime takes whole minutes (e.g. --walltime 90), not '${OPT_WALLTIME}'." 2
    WALL=$(int "$OPT_WALLTIME"); WALL_SRC="--walltime"
elif [[ $MODE == relax ]] && (( ! OPT_NOSTUDY )) && command -v python3 >/dev/null 2>&1 \
     && [[ -f "$_wp_dir/backfill_study.py" ]]; then
    # backfill-study: its own command, called here with THIS chain's numbers
    # rather than letting it re-derive them, so the walltime it proposes is
    # judged by the same arithmetic the chain then runs on. See backfill_study.py.
    STUDY_REPORT=$(python3 "$_wp_dir/backfill_study.py" --machine --partition "$PART" \
            --nodes "$NODES" --cpus "$RANKS" --mem-mb "$(( MEMCPU * RANKS ))" \
            --t-ion-s "$T_ION" --startup-s "$STARTUP" --margin-min "$MARGIN_CFG" \
            --steps "$_nsw_left" --max-time-min "${MAXT:-0}" \
            --default-wall-min "$DEFAULT_WALL" --days "$QUEUE_DAYS" 2>&1)
    _sline=$(printf '%s\n' "$STUDY_REPORT" | grep '^WP_BACKFILL_STUDY ' | tail -1)
    STUDY_REPORT=$(printf '%s\n' "$STUDY_REPORT" | grep -v '^WP_BACKFILL_STUDY ')
    _swall=$(sed -n 's/.* wall_min=\([0-9][0-9]*\).*/\1/p' <<<"$_sline")
    _ssrc=$(sed -n 's/.* source=\([a-z]*\).*/\1/p' <<<"$_sline")
    _sreason=$(sed -n 's/.* reason="\(.*\)"$/\1/p' <<<"$_sline")
    if [[ -n $_swall ]] && [[ $_ssrc == study ]]; then
        WALL=$_swall; WALL_SRC="backfill-study"
    else
        WALL=$DEFAULT_WALL
        WALL_SRC="profile default (WP_CHUNK_WALLTIME_MIN) -- backfill-study could not decide: ${_sreason:-no output}"
    fi
else
    WALL=$DEFAULT_WALL; WALL_SRC="profile default (WP_CHUNK_WALLTIME_MIN)"
    (( OPT_NOSTUDY )) && WALL_SRC="${WALL_SRC}, --no-queue-study"
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

# ---- does ONE ionic step fit? -----------------------------------------------
# If not, every chunk would be killed before it completed a step, and the chain
# would spend queue time and core-hours producing nothing. This used to be
# checked AFTER the cap had been clamped to at least 1 -- so it could never
# fire, and a chain that could not progress was submitted anyway.
if [[ $MODE == relax ]]; then
    _nfit=$(awk -v b="$T_WORK" -v t="$T_FIT" -v f="$FIT_FACTOR" \
            'BEGIN{ if(t<=0){ print 1; exit } print int(b/(t*f)) }')
    if (( _nfit < 1 )); then
        # the shortest walltime that WOULD hold one step, by the same arithmetic
        _wneed=$(walltime_for_step "$T_FIT" "$FIT_FACTOR" "$STARTUP" "$MARGIN_CFG")
        _hold=$(awk -v t="$T_FIT" -v f="$FIT_FACTOR" 'BEGIN{ printf "%d", t*f + 0.999 }')
        if [[ -n $MAXT ]] && (( ${_wneed:-0} > MAXT )); then
            _way="   The partition allows at most ${MAXT} min, so no chunk on '${PART}' can hold one step.
   The ways out: more ranks (a faster step), or a partition with a longer MaxTime."
        elif [[ $ACTION == resume ]]; then
            _way="   A chain keeps the chunk walltime it started with. Start a new one from where
   this one got to (POSCAR):   vasp-${MODE}-loop --fresh --walltime ${_wneed}"
        else
            _way="   Launch with:   --walltime ${_wneed}      (or more ranks, for a faster step)"
        fi
        die "not even ONE ionic step fits in a ${WALL}-min chunk.
   One step is ~${T_FIT}s (${FIT_SRC}); ${FIT_WHY}: ${_hold}s.
   The chunk leaves ${T_WORK}s to compute after its ${MARGIN}-min margin and ${STARTUP}s
   start-up, so every chunk would be killed before completing a step.
   The shortest chunk that holds one: ${_wneed:-?} min.
${_way}" 2
    fi
fi

# ---- chunk 1 -------------------------------------------------------------------
if [[ $MODE == scf ]]; then
    CAP1=$(awk -v b="$T_WORK" -v t="$CAL" -v s="$SAFETY" -v c="$NELM_CEIL" -v f="$NELM_FLOOR" \
           -v o="$NELM_ORIG" 'BEGIN{ if(t<=0){print f; exit}
                 n=int(b/(t*s*1.5)); if(n>c)n=c; if(n>o)n=o; print n }')
    (( CAP1 < NELM_FLOOR )) && die "one chunk cannot hold ${NELM_FLOOR} SCF steps at
   ${CAL}s per step within ${WALL} min. Raise --walltime or the rank count." 2
    CAP_UNIT="electronic steps"
else
    # Chunk 1 is a CALIBRATION chunk: deliberately tiny, because it also absorbs
    # the cold start, where the first ionic step costs several times the steady
    # state and would otherwise poison the estimate for everything after it.
    CAP1=$(awk -v b="$T_WORK" -v t="$T_ION" -v f="$COLD_FACTOR" -v r="$nsw" 'BEGIN{
               if(t<=0){print 1; exit} n=int(b/(t*f)); if(n>3)n=3; if(n>r)n=r
               if(n<1)n=1; print n }')
    CAP_UNIT="ionic steps"
fi

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
        bad_geometry|bad_contcar)
            die "the last chunk's geometry was REJECTED (${stop_reason}): see CONTCAR.rejected and
   $CH_DEAD. Continuing would propagate it. Fix POSCAR by hand, then --fresh." 3 ;;
        symmetry_drift)
            die "NKPTS changed between chunks, so the stored WAVECAR no longer matches the
   k-point set. Set ISYM = 0 in the INCAR and start again with --fresh." 3 ;;
        numerical)
            die "the last chunk produced NaN or overflow in OSZICAR. That is the calculation,
   not the chain: fix the INCAR (mixing, ALGO, POTIM), then --fresh." 3 ;;
    esac

    hdr "Resuming -- what the last chunk left behind"
    kv "last chunk"      "job ${last_jid:-?}"
    kv "how it ended"    "${RESUME_CAUSE:-stopped cleanly}$( (( _mmax > 0 )) && echo "  (peak ${_mmax} MB/rank measured)")"

    # (1) A chunk that died WITH its job never ran its own bookkeeping: nothing
    #     was archived, its ionic steps were not counted, the trajectory was not
    #     extended. Do exactly what it would have done. "Fresh" means written by
    #     that chunk, i.e. after it was submitted -- an older OSZICAR belongs to
    #     the chunk before and must not be counted twice.
    _ref="$CH_RUN"; [[ -f $_ref ]] || _ref="$CH_ENV"
    _fresh(){ [[ -s $1 && $1 -nt $_ref ]]; }
    ionic_dead=$(int "${dead_ionic:-0}")
    if (( unfinished )); then
        idx_dead=$(( $(int "${chunk_index:-0}") + 1 ))
        cdir="$CHDIR/chunk-$(printf '%03d' "$idx_dead")"; mkdir -p "$cdir"
        [[ $MODE == relax ]] && _fresh OSZICAR && ionic_dead=$(int "$(grep -c 'F=' OSZICAR 2>/dev/null)")
        [[ -s POSCAR ]] && { cp -f POSCAR "$cdir/POSCAR.in"; gzip -f "$cdir/POSCAR.in" 2>/dev/null; }
        for f in OUTCAR OSZICAR vasprun.xml CONTCAR XDATCAR; do
            _fresh "$f" && { cp -f "$f" "$cdir/"; gzip -f "$cdir/$f" 2>/dev/null; }
        done
        for f in "VASP-chain-${last_jid}.out" "VASP-chain-${last_jid}.err"; do
            [[ -e $f ]] && mv -f "$f" "$cdir/" 2>/dev/null
        done
        if [[ $MODE == relax ]] && _fresh XDATCAR; then
            if [[ -f "$CHDIR/XDATCAR.all" ]]; then tail -n +8 XDATCAR >> "$CHDIR/XDATCAR.all"
            else cp -f XDATCAR "$CHDIR/XDATCAR.all"; fi
        fi
        state_set chunk_index "$idx_dead" nsw_done "$(( $(int "${nsw_done:-0}") + ionic_dead ))"
        log_line "$idx_dead" "${last_jid:-?}" "$( [[ $MODE == relax ]] && echo RELAX || echo SCF)" \
                 "${next_cap:-?}" "$ionic_dead" "-" "-" "-" "$(( _mmax > 0 ? _mmax : 0 ))" \
                 "${chain_mem_per_cpu:-$MEMCPU}" "DIED" "${RESUME_CAUSE}; settled by --resume"
        kv "settled"         "chunk ${idx_dead}: ${ionic_dead} ionic step(s) counted and archived in ${cdir}/"
        # Settled, and recorded as such. If a check below refuses to go on, the
        # user will run --resume again -- and a chain still marked "running"
        # would have this chunk archived a second time as the next one, its
        # steps and its frames counted twice. The cause and the step count are
        # kept, so that second --resume reaches the same decision.
        case $RESUME_CAUSE in oom|timeout) _sk=$RESUME_CAUSE ;; *) _sk=died ;; esac
        state_set chain_state stopped stop_reason "$_sk" dead_ionic "$ionic_dead"
    fi

    # (2) The geometry the last chunk reached. VASP writes CONTCAR after every
    #     ionic step, so a chunk that died mid-run still left its progress there
    #     -- but the chain promotes CONTCAR to POSCAR only after a chunk it saw
    #     finish. Resuming from POSCAR would silently redo those steps.
    if [[ $MODE == relax ]] && [[ -s CONTCAR ]] && ! cmp -s CONTCAR POSCAR; then
        if _why=$(contcar_ok CONTCAR POSCAR); then
            _v0=$(cell_volume POSCAR); _v1=$(cell_volume CONTCAR)
            if awk -v a="${_v0:-0}" -v b="${_v1:-0}" \
                  'BEGIN{ exit !(a>0 && b>0 && (b > 1.5*a || b < 0.5*a)) }'; then
                warn "CONTCAR's cell volume changed ${_v0} -> ${_v1} A^3; NOT taking it. Continuing from POSCAR."
            else
                cp -f CONTCAR POSCAR.new && mv -f POSCAR.new POSCAR
                ok "geometry advanced to the last completed ionic step (CONTCAR -> POSCAR)"
            fi
        else
            warn "CONTCAR is not usable (${_why}); continuing from POSCAR, so the last chunk's steps are redone."
        fi
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
            # The walltime killed the job despite the STOPCAR warning: a step took
            # longer than the chain's model said. The walltime stays fixed; what
            # changes is how many steps a chunk is given.
            if (( ionic_dead == 0 )); then
                die "not one ionic step completed in a whole ${WALL}-min chunk before the walltime
   killed it. The chunk walltime is fixed for this chain, and a step does not
   fit in it. Start a new chain with a longer one:  --fresh --walltime <min>" 2
            fi
            _tdead=$(awk '/LOOP\+:/{ k=split($0,a,"real time"); if(k>1){ s+=a[2]+0; n++ } }
                          END{ if(n>0) printf "%.1f", s/n; else print 0 }' OUTCAR 2>/dev/null)
            if awk -v t="${_tdead:-0}" 'BEGIN{exit !(t>0)}'; then
                _ncap=$(awk -v b="$T_WORK" -v t="$_tdead" -v s="$SAFETY" 'BEGIN{ print int(b/(t*s)) }')
                (( _ncap < 1 )) && die "an ionic step now takes ~${_tdead}s and the fixed ${WALL}-min chunk leaves
   ${T_WORK}s: it no longer fits. POSCAR holds the geometry reached. Start a new
   chain from there:   vasp-${MODE}-loop --fresh --walltime $(walltime_for_step "$_tdead" "$SAFETY" "$STARTUP" "$MARGIN_CFG")" 2
                state_set next_cap "$_ncap" t_ionic_s "$_tdead" t_ionic_measured 1
                ok "steps per chunk reset to ${_ncap} from the ${_tdead}s the killed chunk measured"
            fi
            ;;
    esac

    # (5) Clear the dead chunk's markers and record what was decided.
    if [[ -f $CH_DEAD ]]; then
        _lastdir="$CHDIR/chunk-$(printf '%03d' "$(int "${chunk_index:-0}")")"
        mkdir -p "$_lastdir"; mv -f "$CH_DEAD" "$_lastdir/STOPPED.txt" 2>/dev/null
    fi
    rm -f "$CH_RUN" STOPCAR
    state_set chain_state running stop_reason "" dead_ionic "" next_cold_start "$COLD_NEXT" \
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
if [[ $MODE == relax ]]; then
    kv "one ionic step"     "~${T_FIT}s (${FIT_SRC}) -- fits the chunk"
    if [[ $ACTION != resume ]]; then
        kv "estimated ionic step" "~${T_ION} s  (${SPI} electronic steps each, ${SPI_SRC})"
        if [[ $SPI_SRC == ASSUMED* ]]; then
            # Do not let a default masquerade as a measurement. The per-step time IS
            # measured, but the steps-per-ionic-step factor that turns it into an
            # ionic-step cost is not whenever the benchmark was cut off mid-SCF --
            # which is usual. Chunk 1 is a calibration chunk precisely so this
            # number gets replaced by a real one.
            note "the electronic-steps-per-ionic-step factor is a DEFAULT, not a measurement:"
            note "the benchmark was cut off before it closed an ionic step. Chunk 1 is a"
            note "calibration chunk and will replace it with VASP's own LOOP+ timings."
        fi
        kv "first chunk cap"    "${CAP1} ionic steps  (calibration; later chunks measure)"
    fi
    kv "target NSW"         "$nsw  (${nsw_done:-0} done)"
    kv "NELM per ionic step" "${NELM_ORIG}  (never chunked: a truncated SCF gives wrong forces)"
else
    kv "first chunk cap"    "${CAP1} electronic steps  (calibration; later chunks resize)"
    kv "original NELM"      "$NELM_ORIG"
fi
kv "memory"             "measured after every chunk; the next one's --mem-per-cpu is rewritten from it"

# The study, where the user can read it: the chosen walltime is only as good
# as the data behind it, so the data is shown rather than summarised.
if [[ -n $STUDY_REPORT ]]; then
    hdr "backfill-study -- why this chunk walltime"
    printf '%s\n' "$STUDY_REPORT"
fi
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
[[ -n $STUDY_REPORT ]] && printf '%s\n' "$STUDY_REPORT" > "$CHDIR/backfill_study.txt"

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
              nsw_target "$nsw" chain_ediffg "$(incar_get EDIFFG)" \
              chain_isif "$(int "$(incar_get ISIF)")" \
              t_ionic_s "${T_ION:-0}" t_ionic_measured 0 nsw_done 0 nelm_hit_streak 0 recovery_used 0 \
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
