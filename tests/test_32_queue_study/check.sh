#!/usr/bin/env bash
# test_32_queue_study -- the chunk walltime chosen from what the queue has
# actually done to jobs shaped like this one.
#
# A fake accounting history is used on purpose: the right answer is then
# arithmetic chosen here, not something computed by the code under test.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/qstudy"; rm -rf "$W"; mkdir -p "$W"
source "$SUITE_DIR/chain_harness.sh"
Q="$TK_DIR/wolfpack_queue.py"

# _hist FILE LIMIT_MIN WAIT_MIN N [NODES CPUS MEM]  -- N started jobs
_hist(){
    "$WP_PY" - "$@" <<'PY'
import sys, datetime as dt
f, lim, wait, n = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
nodes = int(sys.argv[5]) if len(sys.argv) > 5 else 1
cpus  = int(sys.argv[6]) if len(sys.argv) > 6 else 4
mem   = sys.argv[7] if len(sys.argv) > 7 else "8G"
with open(f, "a") as fh:
    for i in range(n):
        sub = dt.datetime(2026, 9, 1) + dt.timedelta(minutes=37 * i + lim)
        sta = sub + dt.timedelta(minutes=wait)
        fh.write(f"{lim}{i}|fakepart|{sub.isoformat()}|{sub.isoformat()}|{sta.isoformat()}|"
                 f"COMPLETED|x|{lim}|{nodes}|{cpus}|cpu={cpus},mem={mem},node={nodes}|\n")
PY
}

# ===========================================================================
# 1. THE PARSING THE ANSWER RESTS ON
# ===========================================================================
got=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
print(Q.parse_mem_mb('', '1000Mc', 48, 1), Q.parse_mem_mb('', '48000Mn', 48, 1),
      Q.parse_mem_mb('', '48000M', 48, 1), Q.parse_mem_mb('cpu=48,mem=46.875G,node=1', '', 48, 1))
print(Q.parse_timelimit_min('600', ''), Q.parse_timelimit_min('', '1-00:00:00'),
      Q.parse_timelimit_min('', '04:30:00'), Q.parse_timelimit_min('', 'UNLIMITED'))")
ok_if "[[ '$(sed -n 1p <<<"$got")' == '48000.0 48000.0 48000.0 48000.0' ]]" \
      "ReqMem per-CPU, per-node and total spellings, and ReqTRES, all read as the same 48000 MB"
ok_if "[[ '$(sed -n 2p <<<"$got")' == '600.0 1440.0 270.0 None' ]]" \
      "requested walltimes parse from TimelimitRaw and from D-HH:MM:SS; UNLIMITED is no number"

# A job held by a dependency waited on its own job graph, not on the queue:
# its wait is counted from Eligible, not from Submit.
held=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
j = Q.load_jobs(['1|p|2026-09-01T00:00:00|2026-09-01T10:00:00|2026-09-01T10:01:00|COMPLETED|x|60|1|4|mem=8G|'])
print(int(j[0].wait_s))")
ok_if "[[ '$held' == 60 ]]" "a job held 10 h by a dependency and started 1 min after is a 60 s wait (got ${held} s)"

# ===========================================================================
# 2. THE DECISION, ON A HISTORY WITH A KNOWN ANSWER
# ===========================================================================
# The job: 1 node, 4 cores, 8 GB; ~25.6 s per ionic step; 20 steps to do.
# At every candidate walltime the chain needs the same 3 chunks (3, 6, 11:
# the calibration chunk, then the cap may only double), so the WAIT decides:
#     requests <= 1 h wait 2 h;  1-2 h wait 5 min;  2-4 h wait 4 h
# The answer is 2 h.
H="$W/hist.txt"; : > "$H"
_hist "$H" 60 120 12
_hist "$H" 120 5 12
_hist "$H" 240 240 12
res=$("$WP_PY" -c "
import sys, json; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
jobs = Q.load_jobs(open('$H').read().splitlines())
r = Q.study(jobs, nodes=1, cpus=4, mem_mb=8192, t_ion_s=25.6, startup_s=10,
            margin_cfg_min=5, steps=20, max_time_min=None, default_wall_min=60)
print(r['chosen_min'], r['source'], r['level'])
print(' '.join(str(x['chunks']) for x in r['rows'] if x['n']))")
ok_if "[[ '$(sed -n 1p <<<"$res" | cut -d' ' -f1-2)' == '120.0 study' ]]" \
      "the study picks the walltime with the shortest expected time: $(sed -n 1p <<<"$res" | cut -d' ' -f1) min (expected 120)"
ok_if "[[ '$(sed -n 2p <<<"$res")' == '3 3 3' ]]" \
      "and it replays the chain's ramp: 3 chunks at every candidate (got: $(sed -n 2p <<<"$res"))"
ok_if "grep -q 'nodes + cores + memory' <<<\"\$res\"" "the comparison is against jobs similar on nodes, cores AND memory"

# ===========================================================================
# 3. THE COMPARISON RELAXES, AND SAYS SO
# ===========================================================================
# Only jobs of a very different core count: the cores axis cannot be kept.
H2="$W/hist2.txt"; : > "$H2"
_hist "$H2" 60 120 12 1 64 8G
_hist "$H2" 120 5 12 1 64 8G
lvl=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
r = Q.study(Q.load_jobs(open('$H2').read().splitlines()), nodes=1, cpus=4, mem_mb=8192,
            t_ion_s=25.6, startup_s=10, margin_cfg_min=5, steps=20, max_time_min=None,
            default_wall_min=60)
print(r['level'])")
ok_if "[[ '$lvl' == nodes ]]" "with no job of a similar size, it compares on nodes alone -- and reports that level ('$lvl')"

# ===========================================================================
# 4. NOT ENOUGH DATA: NO PROPOSAL, NOT A GUESS
# ===========================================================================
H3="$W/hist3.txt"; : > "$H3"
_hist "$H3" 60 120 3
_hist "$H3" 120 5 3
fb=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
r = Q.study(Q.load_jobs(open('$H3').read().splitlines()), nodes=1, cpus=4, mem_mb=8192,
            t_ion_s=25.6, startup_s=10, margin_cfg_min=5, steps=20, max_time_min=None,
            default_wall_min=60)
print(r['source'], '|', r['reason'])")
ok_if "grep -q '^fallback | fewer than two' <<<\"\$fb\"" \
      "three jobs per walltime are not evidence: no proposal, and it says why"

# MaxTime bounds the candidates, and is itself one.
mt=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
r = Q.study([], nodes=1, cpus=4, mem_mb=8192, t_ion_s=25.6, startup_s=10, margin_cfg_min=5,
            steps=20, max_time_min=150, default_wall_min=60)
print(max(x['wall_min'] for x in r['rows']), 150.0 in [x['wall_min'] for x in r['rows']])")
ok_if "[[ '$mt' == '150.0 True' ]]" "no candidate exceeds the partition's MaxTime, and MaxTime itself is a candidate"

# ===========================================================================
# 5. THE CHAIN'S ARITHMETIC AND THE STUDY'S ARE THE SAME ARITHMETIC
# ===========================================================================
# The study replays the chain to count chunks. If the two drifted, it would be
# optimising a chain that does not exist.
d=$(ch_setup same)
ch_run "$d" --walltime 120 >/dev/null 2>&1
tw_chain=$(ch_state "$d" t_work_s)
tw_study=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
print(int(Q.chunk_budget(120, 5, 10)))")
ok_if "[[ '$tw_chain' == '$tw_study' ]]" "the study's time budget per chunk equals the chain's (${tw_study} s vs ${tw_chain} s)"
ramp=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import wolfpack_queue as Q
print(Q.replay_chunks(60, 30, 10, 5, 20))")
ok_if "[[ '$ramp' == '(True, 95, 3)' ]]" \
      "the study's ramp is the chain's: a calibration chunk of 3, then doubling, capped by what remains -- 3, 6, 11 -> 3 chunks for 20 steps ($ramp)"

# ===========================================================================
# 6. IN THE CHAIN: the study decides the walltime at launch
# ===========================================================================
d=$(ch_setup chosen)
cp "$H" "$W/chosen.fake/history"
out=$(ch_run "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && [[ '$(ch_job "$d" time)' == 02:00:00 ]]" \
      "launched with no --walltime, the chain uses the study's choice ($(ch_job "$d" time))"
ok_if "[[ '$(ch_state "$d" chain_wall_source)' == 'queue study' ]]" "and records that it was the study's"
ok_if "grep -q 'PROPOSED CHUNK' <<<\"\$out\" && [[ -s '$d/wolfpack_chain/queue_study.txt' ]]" \
      "the study is shown at launch and kept in wolfpack_chain/queue_study.txt"

# No accounting data: the profile's default, and the reason.
d=$(ch_setup nodata)
out=$(ch_run "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && [[ '$(ch_job "$d" time)' == 01:00:00 ]]" \
      "with no accounting data the profile's default is used ($(ch_job "$d" time))"
ok_if "grep -q 'could not decide' <<<\"\$(ch_state '$d' chain_wall_source)\"" "and the state says why the study could not decide"

# --no-queue-study skips it.
d=$(ch_setup nostudy); cp "$H" "$W/nostudy.fake/history"
ch_run "$d" --no-queue-study >/dev/null 2>&1
ok_if "[[ '$(ch_job "$d" time)' == 01:00:00 && ! -f '$d/wolfpack_chain/queue_study.txt' ]]" \
      "--no-queue-study uses the profile's walltime and runs no study"

# --study shows the analysis and launches nothing.
d=$(ch_setup lookonly); cp "$H" "$W/lookonly.fake/history"
out=$(ch_run "$d" --study 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -q 'PROPOSED CHUNK   : 2 h' <<<\"\$out\"" "--study prints the proposal (2 h)"
ok_if "[[ ! -d '$d/wolfpack_chain' && '$(ch_nsub "$d")' == 0 ]]" "and creates nothing and submits nothing"

exit $(( FAIL_N > 0 ))
