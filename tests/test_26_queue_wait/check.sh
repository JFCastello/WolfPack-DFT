#!/usr/bin/env bash
# test_26_queue_wait -- vasp-queue-wait: the statistics, against arithmetic.
#
# The command turns sacct's Submit and Start times into a median, a mean, a p90
# and a worst case per partition. Every one is a reduction over a list, and a
# reduction is exactly the kind of thing that is wrong by one element and looks
# entirely plausible.
#
# A FAKE sacct is used on purpose. Against a real one the "expected" value
# would have to be computed the same way the tool computes it, and the test
# would prove only that the code agrees with itself.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/queuewait"; rm -rf "$W"; mkdir -p "$W/bin"
QW="$TK_DIR/vasp_queue_wait.sh"

# ---------------------------------------------------------------------------
# The fixture, and what it must produce.
#
#   fast   waits of  60 120 180 240 300 s  -> median 180  mean 180   p90 300
#   slow   waits of  60  60  60  60 86400  -> median  60  mean 17328 p90 86400
#
# `slow` is the point of the table. Its median is one minute and its mean is
# nearly five hours: a tool that printed only the mean would describe a queue
# that usually starts in a minute as one that takes five hours.
#
# Plus two rows that must NOT become a wait:
#   a PENDING job     -- no Start. It is counted as pending, not as a wait of 0.
#   a CANCELLED job   -- no Start either, but it is not pending: it never will
#                        run. Counting it made "pending now" disagree with squeue.
#   a HELD job        -- Eligible later than Submit, so it was waiting on its
#                        own dependency, not on the queue.
# ---------------------------------------------------------------------------
cat > "$W/bin/sacct" <<'FAKE'
#!/usr/bin/env bash
# rows: JobID|Partition|Submit|Eligible|Start|State|NNodes
cat <<'ROWS'
101|fast|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:01:00|COMPLETED|1
102|fast|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:02:00|COMPLETED|1
103|fast|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:03:00|COMPLETED|1
104|fast|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:04:00|COMPLETED|8
105|fast|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:05:00|COMPLETED|8
201|slow|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:01:00|COMPLETED|1
202|slow|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:01:00|COMPLETED|1
203|slow|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:01:00|COMPLETED|1
204|slow|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-20T10:01:00|COMPLETED|1
205|slow|2026-09-20T10:00:00|2026-09-20T10:00:00|2026-09-21T10:00:00|COMPLETED|32
301|slow|2026-09-20T12:00:00|2026-09-20T12:00:00|Unknown|PENDING|1
302|slow|2026-09-20T12:00:00|2026-09-20T12:00:00|None|CANCELLED by 1000|1
401|fast|2026-09-20T09:00:00|2026-09-20T23:00:00|2026-09-20T23:00:30|COMPLETED|1
ROWS
FAKE
chmod +x "$W/bin/sacct"

_run(){ PATH="$W/bin:$PATH" timeout 120 bash "$QW" "$@" 2>&1; }
out=$(_run --days 30); echo "$out" > "$W/report.log"
_row(){ grep -E "^  $1 " <<<"$out" | head -1; }

# --- 1. the medians, which is what the command is FOR ----------------------
# Printed as "3.0m" / "60s": the seconds are the source of truth, so the CSV is
# what the arithmetic is checked against. The table is checked separately for
# actually containing the partition.
csv="$W/out.csv"; _run --days 30 --csv "$csv" >/dev/null
_csv(){ awk -F, -v p="$1" '$1==p{print $'"$2"'}' "$csv" | head -1; }
ok_if "[[ -s '$csv' ]]" "a machine-readable table is written when asked"
near "$(_csv fast 3)" 180 1 "fast: median wait is the middle of 60..300 s"
near "$(_csv fast 4)" 180 1 "fast: mean wait"
near "$(_csv fast 5)" 300 1 "fast: p90 is the slowest of five"
near "$(_csv slow 3)" 60  1 "slow: median is ONE MINUTE despite the day-long outlier"
near "$(_csv slow 4)" 17328 5 "slow: mean is dragged to ~4.8 h by that one job"
near "$(_csv slow 5)" 86400 1 "slow: p90 is the day-long wait"

# --- 2. what must NOT be counted as a wait ---------------------------------
# 6 completed jobs in `fast`, but one of them was held by a dependency until
# 23:00 and then started in 30 s. Counting Submit->Start there would report a
# 14-hour queue wait that nobody experienced.
near "$(_csv fast 2)" 5 0.5 "a job held by a dependency is left out of the queue statistics"
near "$(_csv slow 7)" 1 0.5 "a pending job is counted as pending -- and one cancelled before it started is not"

# --- 3. the size split -----------------------------------------------------
# A 1-node job and a 32-node job are not waiting in the same queue. slow's
# day-long wait is the 32-node one, so the bands must separate them.
ok_if "grep -qE '^  slow +1 node' <<<\"\$out\"" "the by-size table lists the 1-node band"
ok_if "grep -qE '^  slow +17\\+' <<<\"\$out\""  "and the 17+ node band the outlier belongs to"
b1=$(grep -E '^  slow +1 node' <<<"$out" | awk '{print $4}')
ok_if "[[ '$b1' == 4 ]]" "slow's four fast jobs are the 1-node ones ($b1)"

# --- 4. the refusals -------------------------------------------------------
must_refuse "--days 0 is refused" "at least 1" bash "$QW" --days 0
must_refuse "--days abc is refused" "whole number" bash "$QW" --days abc
must_refuse "an unknown option is refused" "unknown option" bash "$QW" --nonsense

# No sacct at all. A tool that needs an accounting database has to say so
# rather than report an empty table, which reads as "no waiting".
# NOT an empty PATH: that takes `timeout` and the rest of coreutils with it,
# and the check then fails for a reason that has nothing to do with sacct. The
# suite has made this mistake before (see ../RULES.md). Instead, a PATH of
# symlinks to everything that is needed EXCEPT sacct.
empty="$W/nosacct"; mkdir -p "$empty"
for t in bash timeout awk sed grep sort head tail printf cat; do
    _p=$(command -v "$t" 2>/dev/null) && ln -sf "$_p" "$empty/$t"
done
command -v sacct >/dev/null && [[ ! -e "$empty/sacct" ]] \
    || fail "the no-sacct fixture still has sacct on its PATH"
out_nos=$(PATH="$empty" timeout 60 bash "$QW" 2>&1 || true)
grep -qiE "sacct is not on PATH|accounting" <<<"$out_nos" \
    && pass "without sacct it says so, instead of printing an empty table" \
    || fail "without sacct the message does not mention it: $(tail -1 <<<"$out_nos")"

# An accounting database with nothing in the window. "No record" and "no wait"
# are different statements and the second one is a lie.
cat > "$W/bin/sacct" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$W/bin/sacct"
out_none=$(_run --days 30)
grep -qiE "no jobs in the accounting database" <<<"$out_none" \
    && pass "an empty window is reported as no record, not as a wait of zero" \
    || fail "an empty window produced: $(tail -1 <<<"$out_none")"
grep -qE "0\.0[sm]|median" <<<"$out_none" \
    && fail "an empty window still printed a statistics table" \
    || pass "and no statistics table is printed for it"

exit $(( FAIL_N > 0 ))
