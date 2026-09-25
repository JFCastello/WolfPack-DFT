#!/usr/bin/env bash
###############################################################################
# wolfpack_chain_lib.sh -- what vasp-scf-loop (vasp_chain.sh) and
# vasp-relax-loop (vasp_relax_loop.sh) share. Sourced, never run.
#
# The caller defines, before calling any of it:
#   CHDIR CH_ENV CH_JOB          the chain directory, its state file, its job
#   MEM_SAFETY MEM_FLOOR_MB      headroom over a measured peak, and a floor
#   chain_node_mem_mb chain_mem_margin chain_cpn chain_max_cores
#   chain_profile chain_nodes0   the node the chunks land on (fit_layout)
#
# Pure bash and awk: most of this runs inside the chunk job, on a compute
# node where only VASP's modules are loaded.
###############################################################################

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
    for f in "VASP-chain-$1.err" "$CHDIR"/*/"VASP-chain-$1.err"; do
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

