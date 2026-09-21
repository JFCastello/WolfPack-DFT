#!/usr/bin/env bash
# vasp-slurm-report -- what every job in a folder ACTUALLY cost.
#
#   vasp-slurm-report                 # this folder and its sub-folders
#   vasp-slurm-report config_*        # only these
#   vasp-slurm-report --csv out.csv   # also write a machine-readable table
#
# ============================================================================
# WHY
# ============================================================================
# A job that finishes is not a job that went well. It can finish having used 1
# of the 240 ranks it reserved, or 4 % of the memory, or 3 % of its walltime --
# and nothing in the output says so. SLURM knows all of it, in `sacct`, and
# nobody reads `sacct` because its default columns are not the interesting ones
# and its memory fields are a trap.
#
# So this asks sacct for the columns that matter and turns them into the three
# ratios that say whether the allocation was earned:
#
#   CPU efficiency  = TotalCPU / CPUTime
#       How much of what you reserved was actually computing. This is the one
#       that catches a 240-rank job running on 1 rank: it reads ~0.4 %.
#
#   memory efficiency = MaxRSS x NCPUS / ReqMem
#       How much of the RAM you asked for was touched.
#
#   time use = Elapsed / Timelimit
#       Near 100 % means you were probably killed; near 0 % means you are
#       holding a queue slot you do not need.
#
# It reads nothing but sacct and the job ids the pipeline recorded. It does not
# submit, cancel or modify anything.
#
# ============================================================================
# THE --units=M TRAP
# ============================================================================
# Without --units=M, sacct reports MaxRSS and AveRSS in WHATEVER unit it feels
# like, per field, per cluster: this toolkit has seen MaxRSS as "576512K" next
# to an AveRSS in raw bytes, in the same row. Parsing that without the flag is
# how you get a 1024x error in a memory number that someone then sizes a job
# from. The flag is not optional; the suffix-less fallback below exists only
# for SLURM versions too old to have it, and it parses the suffixes by hand.
set -uo pipefail

CSV=""; DIRS=()
while (( $# )); do
    case "$1" in
        --csv) CSV="${2:-}"; shift 2 ;;
        --csv=*) CSV="${1#*=}"; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) DIRS+=("$1"); shift ;;
    esac
done

command -v sacct >/dev/null 2>&1 || {
    echo "ERROR: sacct not found. This needs SLURM job accounting." >&2; exit 1; }

# No folders given: this one, plus any sub-folder the pipeline has touched.
if (( ${#DIRS[@]} == 0 )); then
    [[ -d .wolfpack ]] && DIRS+=(".")
    while IFS= read -r d; do DIRS+=("$d"); done < <(
        find . -mindepth 2 -maxdepth 3 -type d -name .wolfpack \
             -printf '%h\n' 2>/dev/null | sort)
fi
(( ${#DIRS[@]} )) || { echo "No folder with a .wolfpack/ directory here." >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Collect the job ids the pipeline recorded for a folder.
# --------------------------------------------------------------------------- #
job_ids_for() {
    local d="$1"
    # Every stage names its SLURM logs after its own job id
    # (.wolfpack/dryrun-11071693.out, benchmark-11071727.out, ...), so the
    # folder carries the id list without anything having to record one.
    find "$d/.wolfpack" -maxdepth 1 \( -name '*-[0-9]*.out' -o -name '*-[0-9]*.err' \) \
         2>/dev/null \
      | sed -nE 's/.*-([0-9]+)\.(out|err)$/\1/p' \
      | grep -E '^[0-9]+$' | sort -un
}

fmt_pct() { awk -v n="${1:-0}" -v d="${2:-0}" 'BEGIN{
    if (d+0 <= 0) { print "  --"; exit } printf "%4.0f%%", 100.0*n/d }'; }

[[ -n "$CSV" ]] && echo "folder,jobid,jobname,state,exit,elapsed_s,timelimit_s,ncpus,nnodes,totalcpu_s,cputime_s,cpu_eff,maxrss_mb,averss_mb,reqmem_mb,mem_eff,time_use" > "$CSV"

printf '%-14s %-11s %-13s %-9s %6s %6s %6s  %9s %9s\n' \
    "folder" "jobid" "job" "state" "cpu%" "mem%" "time%" "maxRSS/rk" "elapsed"
printf '%s\n' "--------------------------------------------------------------------------------------"

n_seen=0; n_bad=0
for d in "${DIRS[@]}"; do
    label="$(basename "$(readlink -f "$d")")"
    ids="$(job_ids_for "$d")"
    if [[ -z "$ids" ]]; then
        printf '%-14s %s\n' "$label" "(no job ids recorded in .wolfpack/)"
        continue
    fi
    for jid in $ids; do
        RAW=$(sacct -j "$jid" -n -P --units=M \
              -o JobID,JobName,State,ExitCode,Elapsed,Timelimit,NCPUS,NNodes,TotalCPU,MaxRSS,AveRSS,ReqMem 2>/dev/null)
        [[ -z "$RAW" ]] && RAW=$(sacct -j "$jid" -n -P \
              -o JobID,JobName,State,ExitCode,Elapsed,Timelimit,NCPUS,NNodes,TotalCPU,MaxRSS,AveRSS,ReqMem 2>/dev/null)
        if [[ -z "$RAW" ]]; then
            # Accounting lags a freshly finished job; say so rather than print zeros.
            printf '%-14s %-11s %s\n' "$label" "$jid" "(no accounting data yet -- try again shortly)"
            continue
        fi
        # Fold the job and its steps into one row: the parent carries the
        # request and the state, the steps carry the RSS.
        read -r name state ecode el tl ncpus nnodes tcpu maxrss averss reqmem <<<"$(
            printf '%s\n' "$RAW" | awk -F'|' '
            function to_mb(x,  u,n){ if(x==""||x=="0")return 0
                u=substr(x,length(x),1)
                if(u ~ /[KMGT]/){ n=substr(x,1,length(x)-1)+0 } else { n=x+0; u="K" }
                if(u=="K")return n/1024.0; if(u=="M")return n
                if(u=="G")return n*1024.0; if(u=="T")return n*1048576.0; return n/1024.0 }
            function to_s(t,  d,a,n,s){ if(t==""||t=="UNLIMITED"||t=="Partition_Limit")return 0
                s=0; n=split(t,d,"-"); if(n==2){ s+=d[1]*86400; t=d[2] }
                n=split(t,a,":"); if(n==3)s+=a[1]*3600+a[2]*60+a[3]
                else if(n==2)s+=a[1]*60+a[2]; else s+=a[1]+0; return s }
            # ReqMem is the one field whose meaning changed between SLURM
            # versions. Up to 20.02 it carried a per-what suffix -- "9700Mc"
            # is per CPU, "360000Mn" per node -- and from 20.11 it is the
            # TOTAL for the job with no suffix. Getting this wrong turns a
            # healthy 80% into 5080%, so resolve it to a job total here and
            # let the caller compare totals with totals.
            function req_total_mb(x, ncpus, nnodes,   per, v){
                if (x=="" || x=="0") return 0
                per = substr(x, length(x), 1)
                if (per=="c" || per=="n") { v = to_mb(substr(x, 1, length(x)-1))
                    return (per=="c") ? v*(ncpus>0?ncpus:1) : v*(nnodes>0?nnodes:1) }
                return to_mb(x) }
            { if ($1 !~ /\./) { name=$2; state=$3; ecode=$4; el=to_s($5); tl=to_s($6)
                                ncpus=$7+0; nnodes=$8+0; tcpu=to_s($9); rqraw=$12 }
              r=to_mb($10); a=to_mb($11); if(r>mx)mx=r; if(a>av)av=a
              if($1 ~ /\./ && to_s($9)>stepcpu) stepcpu=to_s($9) }
            END{ if(tcpu<=0) tcpu=stepcpu
                 gsub(/ /,"_",state)
                 rq = req_total_mb(rqraw, ncpus, nnodes)
                 printf "%s %s %s %d %d %d %d %d %.1f %.1f %.1f",
                        (name==""?"?":name), (state==""?"?":state), (ecode==""?"?":ecode),
                        el, tl, ncpus, nnodes, tcpu, mx, av, rq }'
        )"
        cputime=$(( el * ncpus ))
        # reqmem is already the whole-job total (resolved in the awk above).
        req_total="$reqmem"
        # What the job actually occupied is the MEAN rank times the rank count,
        # not the peak rank times the rank count: rank 0 is a large outlier on
        # k-point-parallel layouts, so MaxRSS x NCPUS overstates the real
        # footprint by the imbalance factor. Fall back to MaxRSS only when
        # AveRSS is missing or nonsense.
        used_total=$(awk -v mx="$maxrss" -v av="$averss" -v c="$ncpus" 'BEGIN{
            m = (av>0 && av<=mx) ? av : mx; printf "%.1f", m*c }')
        cpu_eff=$(fmt_pct "$tcpu" "$cputime")
        mem_eff=$(fmt_pct "$used_total" "$req_total")
        time_use=$(fmt_pct "$el" "$tl")
        printf '%-14s %-11s %-13s %-9s %6s %6s %6s  %7.0f MB %6ds\n' \
            "$label" "$jid" "${name:0:13}" "${state:0:9}" \
            "$cpu_eff" "$mem_eff" "$time_use" "$maxrss" "$el"
        n_seen=$((n_seen+1))
        # Flag what is worth acting on. The thresholds are stated, not hidden.
        awk -v e="$tcpu" -v c="$cputime" -v t="$el" -v l="$tl" -v s="$state" 'BEGIN{
            if (c>0 && 100.0*e/c < 50)
                printf "               ^ CPU efficiency below 50%%: the job reserved %d core-seconds and used %d.\n", c, e
            if (l>0 && 100.0*t/l > 98)
                print  "               ^ ran to the walltime limit -- check whether it was cut off."
            if (s ~ /TIMEOUT|CANCELLED|FAILED|OUT_OF_MEMORY/)
                printf "               ^ state %s -- this job did not finish cleanly.\n", s }'
        awk -v e="$tcpu" -v c="$cputime" 'BEGIN{ exit !(c>0 && 100.0*e/c < 50) }' && n_bad=$((n_bad+1))
        [[ -n "$CSV" ]] && printf '%s,%s,%s,%s,%s,%d,%d,%d,%d,%.1f,%d,%s,%.1f,%.1f,%.1f,%s,%s\n' \
            "$label" "$jid" "$name" "$state" "$ecode" "$el" "$tl" "$ncpus" "$nnodes" \
            "$tcpu" "$cputime" "${cpu_eff// /}" "$maxrss" "$averss" "$req_total" \
            "${mem_eff// /}" "${time_use// /}" >> "$CSV"
    done
done
printf '%s\n' "--------------------------------------------------------------------------------------"
echo "$n_seen job(s); $n_bad below 50% CPU efficiency."
echo
echo "cpu%   = TotalCPU / (Elapsed x NCPUS)  -- how much of the reservation computed"
echo "mem%   = AveRSS x NCPUS / ReqMem       -- how much of the RAM asked for was touched"
echo "         (AveRSS, not MaxRSS: rank 0 is an outlier when KPAR is large)"
echo "time%  = Elapsed / Timelimit           -- near 100% often means it was cut off"
[[ -n "$CSV" ]] && echo && echo "table written to $CSV"
exit 0
