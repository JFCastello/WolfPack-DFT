#!/usr/bin/env bash
# vasp-queue-wait -- how long jobs actually wait in each partition.
#
#   vasp-queue-wait                  # the last 7 days, every partition
#   vasp-queue-wait --days 30        # a longer window
#   vasp-queue-wait --mine           # only your own jobs
#   vasp-queue-wait -p sequana_cpu   # one partition
#   vasp-queue-wait --csv out.csv    # also write a machine-readable table
#
# ============================================================================
# WHY
# ============================================================================
# Choosing a partition, or a job size, is a bet on how long you will wait, and
# the bet is normally made on hearsay. SLURM has the answer: every job it has
# run carries a Submit time and a Start time, and the difference is the wait.
#
# What this does NOT do is predict your wait. A queue is not stationary -- it
# depends on who else is submitting, on reservations, on fairshare -- so this
# reports what HAS happened and leaves the inference to you.
#
# THE MEDIAN IS THE HEADLINE, NOT THE MEAN.
#   Queue waits have a long tail: a handful of jobs that sat for two days drag
#   a mean far above anything you are likely to experience, and a mean is what
#   makes people say "this queue takes a day" about a queue that usually
#   starts in ten minutes. Both are printed, and when they disagree that
#   disagreement is the useful part -- so p90 is printed too.
#
# WAIT DEPENDS ON SIZE, so the table is split by how many nodes a job asked
# for. A 1-node job and a 40-node job in the same partition are not waiting in
# the same queue in any meaningful sense.
# ============================================================================
set -uo pipefail

DAYS=7; MINE=0; PART=""; CSV=""; SHOW_PENDING=1
c_b=$'\033[1m'; c_d=$'\033[2m'; c_y=$'\033[33m'; c_0=$'\033[0m'
hdr(){ printf '\n%s== %s ==%s\n' "$c_b" "$*" "$c_0"; }
note(){ printf '  %s\n' "$*"; }
warn(){ printf '  %s%s%s\n' "$c_y" "$*" "$c_0" >&2; }

usage(){ sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; cat <<'EOF'

OPTIONS
  --days N       how far back to look (default: 7)
  --mine         only your own jobs (default: every user the accounting
                 database will show you)
  -p, --partition NAME   restrict to one partition
  --csv PATH     write partition,njobs,median_s,mean_s,p90_s,max_s
  --no-pending   skip the "queued right now" section
  -h, --help     this text

WHAT IS MEASURED
  wait = Start - Submit, for jobs that have actually started. A job that is
  still pending has no Start, so it cannot contribute a wait; those are counted
  separately, with how long they have been waiting SO FAR.

  Eligible is not the same as Submit: a job held by a dependency was not
  waiting on the queue. Such jobs are excluded when SLURM reports an Eligible
  time later than Submit.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="${2:?}"; shift 2 ;;
        --mine) MINE=1; shift ;;
        -p|--partition) PART="${2:?}"; shift 2 ;;
        --csv)  CSV="${2:?}"; shift 2 ;;
        --no-pending) SHOW_PENDING=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "vasp-queue-wait: unknown option '$1' (try --help)" >&2; exit 2 ;;
    esac
done
case "$DAYS" in ''|*[!0-9]*) echo "vasp-queue-wait: --days needs a whole number, got '$DAYS'." >&2; exit 2 ;; esac
(( DAYS >= 1 )) || { echo "vasp-queue-wait: --days must be at least 1." >&2; exit 2; }

command -v sacct >/dev/null 2>&1 || {
    echo "vasp-queue-wait: sacct is not on PATH." >&2
    echo "       Queue waits come from SLURM's accounting database; without" >&2
    echo "       sacct there is no record to read. On a login node it is" >&2
    echo "       normally there -- check you are not on a compute node." >&2
    exit 1; }

SINCE="now-${DAYS}days"
SCOPE_ARGS=(); SCOPE="every user the database will show"
if (( MINE )); then SCOPE_ARGS=(-u "$USER"); SCOPE="your jobs only"
else SCOPE_ARGS=(-a); fi
[[ -n "$PART" ]] && SCOPE_ARGS+=(-r "$PART")

# -X: allocations, not steps. A job step inherits its parent's times and would
# count the same wait several times over.
RAW=$(sacct "${SCOPE_ARGS[@]}" -X -P -n -S "$SINCE" \
      -o JobID,Partition,Submit,Eligible,Start,State,NNodes 2>/dev/null)
rc=$?
if (( rc != 0 )); then
    warn "sacct returned no data (exit $rc)."
    note "Accounting may be disabled on this cluster, or you may not be"
    note "permitted to see other users' jobs -- try: vasp-queue-wait --mine"
    exit 1
fi
if [[ -z "${RAW//[[:space:]]/}" ]]; then
    warn "no jobs in the accounting database for the last ${DAYS} day(s)."
    note "Nothing is wrong: there is simply no record to average. Try a longer"
    note "window with --days, or --mine if the cluster hides other users."
    exit 0
fi

hdr "Queue wait by partition -- last ${DAYS} day(s), ${SCOPE}"

STATS=$(printf '%s\n' "$RAW" | awk -F'|' -v OFS='|' '
# Days since 1970-01-01 from a civil date, in PLAIN awk. mktime() would be
# shorter and is what this used at first, but mktime is a GNU extension: on a
# login node running mawk or busybox awk it returns nothing and every wait
# silently becomes garbage. Only DIFFERENCES of these values are used, so the
# missing timezone offset cancels (bar an hour across a DST change).
function days_from_civil(y, m, d,   era, yoe, doy, doe) {
    if (m <= 2) y -= 1
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}
function secs(t,   d, tp, h) {
    # SLURM ISO: 2026-09-23T10:15:00.  Unknown/None/empty -> -1.
    if (t == "" || t == "Unknown" || t == "None") return -1
    split(t, d, "T"); if (length(d) < 2) return -1
    split(d[1], tp, "-"); split(d[2], h, ":")
    if (tp[1] + 0 <= 0) return -1
    return days_from_civil(tp[1] + 0, tp[2] + 0, tp[3] + 0) * 86400 \
           + (h[1] + 0) * 3600 + (h[2] + 0) * 60 + (h[3] + 0)
}
{
    part = $2; sub(/\*$/, "", part)
    if (part == "") next
    sub_t = secs($3); elig = secs($4); start = secs($5); nn = $7 + 0
    if (sub_t < 0) next
    # A job held by a dependency was not waiting on the QUEUE. SLURM says so by
    # making Eligible later than Submit; counting that as queue wait would
    # blame the partition for the user`s own job graph.
    if (elig > 0 && elig > sub_t + 1) next
    if (start < 0) { pend[part]++; next }
    w = start - sub_t
    if (w < 0) next
    band = (nn <= 1 ? "1 node" : (nn <= 4 ? "2-4" : (nn <= 16 ? "5-16" : "17+")))
    key = part "|" band
    n[key]++; W[key, n[key]] = w; sum[key] += w
    if (w > mx[key]) mx[key] = w
    tot_n[part]++; tot_sum[part] += w; TW[part, tot_n[part]] = w
    if (w > tot_mx[part]) tot_mx[part] = w
    seen[part] = 1
}
function pct(key, cnt, q,   i, j, a, tmp, idx) {
    for (i = 1; i <= cnt; i++) a[i] = W[key, i]
    for (i = 2; i <= cnt; i++) { tmp = a[i]; for (j = i-1; j >= 1 && a[j] > tmp; j--) a[j+1] = a[j]; a[j+1] = tmp }
    idx = int(q * cnt + 0.5); if (idx < 1) idx = 1; if (idx > cnt) idx = cnt
    return a[idx]
}
function tpct(part, cnt, q,   i, j, a, tmp, idx) {
    for (i = 1; i <= cnt; i++) a[i] = TW[part, i]
    for (i = 2; i <= cnt; i++) { tmp = a[i]; for (j = i-1; j >= 1 && a[j] > tmp; j--) a[j+1] = a[j]; a[j+1] = tmp }
    idx = int(q * cnt + 0.5); if (idx < 1) idx = 1; if (idx > cnt) idx = cnt
    return a[idx]
}
END {
    for (p in seen)
        printf "P|%s|%d|%d|%d|%d|%d|%d\n", p, tot_n[p], tpct(p, tot_n[p], 0.5),
               (tot_n[p] ? tot_sum[p]/tot_n[p] : 0), tpct(p, tot_n[p], 0.9),
               tot_mx[p], pend[p]
    for (k in n) {
        split(k, kk, "|")
        printf "B|%s|%s|%d|%d|%d|%d\n", kk[1], kk[2], n[k], pct(k, n[k], 0.5),
               (n[k] ? sum[k]/n[k] : 0), pct(k, n[k], 0.9)
    }
    for (p in pend) if (!(p in seen)) printf "P|%s|0|0|0|0|0|%d\n", p, pend[p]
}')

_hms(){ # seconds -> compact human time
    local s=$1
    (( s < 0 )) && { printf '   --  '; return; }
    if   (( s < 60 ));    then printf '%5ds ' "$s"
    elif (( s < 3600 ));  then printf '%5.1fm ' "$(awk -v x="$s" 'BEGIN{printf "%.1f", x/60}')"
    elif (( s < 86400 )); then printf '%5.1fh ' "$(awk -v x="$s" 'BEGIN{printf "%.1f", x/3600}')"
    else                       printf '%5.1fd ' "$(awk -v x="$s" 'BEGIN{printf "%.1f", x/86400}')"
    fi
}

if [[ -z "${STATS//[[:space:]]/}" ]]; then
    warn "no job in that window had both a Submit and a Start time."
    note "Every record was still pending, cancelled before starting, or held by"
    note "a dependency. There is no wait to report -- not a wait of zero."
    exit 0
fi

printf '  %-20s %6s  %8s %8s %8s %8s  %s\n' \
       "PARTITION" "jobs" "median" "mean" "p90" "worst" "pending now"
printf '  %s\n' "--------------------------------------------------------------------------------"
while IFS='|' read -r tag part njobs med mean p90 worst pend; do
    [[ "$tag" == P ]] || continue
    printf '  %-20s %6s  ' "$part" "$njobs"
    _hms "$med"; _hms "$mean"; _hms "$p90"; _hms "$worst"
    printf ' %s\n' "${pend:-0}"
done < <(printf '%s\n' "$STATS" | grep '^P|' | sort -t'|' -k3,3nr)

hdr "By job size (nodes requested)"
note "A 1-node job and a 40-node job are not waiting in the same queue."
printf '\n  %-20s %-8s %6s  %8s %8s %8s\n' "PARTITION" "size" "jobs" "median" "mean" "p90"
printf '  %s\n' "------------------------------------------------------------------------"
while IFS='|' read -r tag part band njobs med mean p90; do
    [[ "$tag" == B ]] || continue
    printf '  %-20s %-8s %6s  ' "$part" "$band" "$njobs"
    _hms "$med"; _hms "$mean"; _hms "$p90"; printf '\n'
done < <(printf '%s\n' "$STATS" | grep '^B|' | sort -t'|' -k2,2 -k3,3)

# What is queued RIGHT NOW. History says what happened; this says what you are
# joining, and the two disagree exactly when it matters.
if (( SHOW_PENDING )) && command -v squeue >/dev/null 2>&1; then
    PEND=$(squeue -h -t PD -o '%P|%S|%D|%r' 2>/dev/null)
    if [[ -n "${PEND//[[:space:]]/}" ]]; then
        hdr "Pending right now"
        printf '  %-20s %6s  %s\n' "PARTITION" "queued" "most common reason"
        printf '  %s\n' "-------------------------------------------------------------"
        printf '%s\n' "$PEND" | awk -F'|' '
            { p=$1; sub(/\*$/,"",p); n[p]++; r[p"|"$4]++ }
            END { for (k in r) { split(k,kk,"|"); if (r[k] > best[kk[1]]) { best[kk[1]]=r[k]; why[kk[1]]=kk[2] } }
                  for (p in n) printf "  %-20s %6d  %s\n", p, n[p], why[p] }' | sort -k2,2nr
    fi
fi

if [[ -n "$CSV" ]]; then
    { echo "partition,njobs,median_s,mean_s,p90_s,max_s,pending"
      printf '%s\n' "$STATS" | grep '^P|' | awk -F'|' '{print $2","$3","$4","$5","$6","$7","$8}'
    } > "$CSV" && note "" && note "CSV written: $CSV"
fi

hdr "Reading this"
note "median  half the jobs waited less than this. The number to plan with."
note "mean    dragged up by a few very long waits; when it is far above the"
note "        median, the queue is usually fast with an occasional bad day."
note "p90     nine jobs in ten started within this. The number to plan with"
note "        when you cannot afford to be late."
note ""
note "This is what HAS happened, not a forecast: a queue depends on who else is"
note "submitting, on reservations and on fairshare, none of which are in here."
