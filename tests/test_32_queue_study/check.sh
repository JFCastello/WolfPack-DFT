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
Q="$TK_DIR/backfill_study.py"

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
import backfill_study as Q
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
import backfill_study as Q
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
import backfill_study as Q
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
import backfill_study as Q
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
import backfill_study as Q
r = Q.study(Q.load_jobs(open('$H3').read().splitlines()), nodes=1, cpus=4, mem_mb=8192,
            t_ion_s=25.6, startup_s=10, margin_cfg_min=5, steps=20, max_time_min=None,
            default_wall_min=60)
print(r['source'], '|', r['reason'])")
ok_if "grep -q '^fallback | fewer than two' <<<\"\$fb\"" \
      "three jobs per walltime are not evidence: no proposal, and it says why"

# MaxTime bounds the candidates, and is itself one.
mt=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import backfill_study as Q
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
import backfill_study as Q
print(int(Q.chunk_budget(120, 5, 10)))")
ok_if "[[ '$tw_chain' == '$tw_study' ]]" "the study's time budget per chunk equals the chain's (${tw_study} s vs ${tw_chain} s)"
ramp=$("$WP_PY" -c "
import sys; sys.path.insert(0, '$TK_DIR')
import backfill_study as Q
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
ok_if "[[ '$(ch_state "$d" chain_wall_source)' == 'backfill-study' ]]" "and records that it was backfill-study's"
ok_if "grep -q 'PROPOSED CHUNK' <<<\"\$out\" && [[ -s '$d/wolfpack_chain/backfill_study.txt' ]]" \
      "the study is shown at launch and kept in wolfpack_chain/backfill_study.txt"

# No accounting data: the profile's default, and the reason.
d=$(ch_setup nodata)
out=$(ch_run "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && [[ '$(ch_job "$d" time)' == 01:00:00 ]]" \
      "with no accounting data the profile's default is used ($(ch_job "$d" time))"
ok_if "grep -q 'could not decide' <<<\"\$(ch_state '$d' chain_wall_source)\"" "and the state says why the study could not decide"

# --no-queue-study skips it.
d=$(ch_setup nostudy); cp "$H" "$W/nostudy.fake/history"
ch_run "$d" --no-queue-study >/dev/null 2>&1
ok_if "[[ '$(ch_job "$d" time)' == 01:00:00 && ! -f '$d/wolfpack_chain/backfill_study.txt' ]]" \
      "--no-queue-study uses the profile's walltime and runs no study"

# The study is not the chain's any more: --study points at the command.
d=$(ch_setup lookonly); cp "$H" "$W/lookonly.fake/history"
must_refuse "vasp-relax-loop --study points at the command that does it now" "backfill-study" \
    ch_run "$d" --study

# ===========================================================================
# 7. backfill-study, STANDING ALONE: the queue, and nothing else
# ===========================================================================
# In a calculation folder it reads the job from slurm_vasptest.sh -- here 1
# node, 4 ranks, 8 GB, --time=04:00:00 -- and reports what the queue did to
# jobs of that shape, in broad walltime bands. Against the history above:
#   up to 1 h:  the twelve 1-h jobs, all waited 2 h
#   1 to 4 h:   twelve 2-h jobs (5 min) and twelve 4-h jobs (4 h): median
#               (5 + 240)/2 min = 2.0 h, 9 in 10 within 4 h
#   the job as written (4 h) falls in 1 to 4 h: about 2.0 h
# It estimates no run time: that is vasp-relax-loop's, from vasp-test.
out=$(ch_backfill "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -q 'Expected wait: about 2.0 h. Of the 24 jobs of your size that asked for 1 to 4 h' <<<\"\$out\"" \
      "the job as written, in a sentence: about 2.0 h, from the 24 jobs of its size that asked 1 to 4 h (rc=$rc)"
ok_if "grep -qE '^  up to 1 h +2.0 h +2.0 h +12\$' <<<\"\$out\" && grep -qE '^  1 to 4 h +2.0 h +4.0 h +24\$' <<<\"\$out\"" \
      "the table: one row per broad band, half-started and 9-in-10, and how many jobs"
ok_if "grep -q 'your size = 1 node, 2-8 cores, 3-23 GB' <<<\"\$out\"" \
      "and it says in numbers what 'your size' means"
ok_if "! grep -qiE 'ionic|RECOMMENDATION|RUN TIME|NSW' <<<\"\$out\"" \
      "no run-time estimate, no recommendation: the queue only"
ok_if "[[ ! -d '$d/wolfpack_chain' && '$(ch_nsub "$d")' == 0 ]]" "it creates nothing and submits nothing"

# The start-up time vasp-test writes has a decimal; the chain used to strip
# the point and read "10.4" as 104 s.
d=$(ch_setup twins); cp "$H" "$W/twins.fake/history"
sed -i 's/test_startup_s="10"/test_startup_s="10.4"/' "$d/.wolfpack/state.env"
ch_run "$d" >/dev/null 2>&1
ok_if "[[ '$(ch_state "$d" t_startup_s)' == 10 ]]" \
      "a start-up written as 10.4 s is read as 10 s, not 104 (the chain read $(ch_state "$d" t_startup_s))"
ok_if "[[ '$(ch_state "$d" chain_wall_min)' == 120 ]]" \
      "and the chain, with its own step estimate, takes backfill-study's 2 h (got $(ch_state "$d" chain_wall_min) min)"

# No folder at all: the job on the command line.
e="$W/nofolder"; mkdir -p "$e"
_bf(){ ( cd "$e" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" FAKE_DIR="$W/twins.fake" \
          FAKE_MAXTIME=UNLIMITED WOLFPACK_CLUSTER_CONF="${CONF:-/nonexistent}" HOME="$e" \
          "$WP_PY" "$Q" "$@" 2>&1 ); }
out=$(_bf --partition fakepart --nodes 1 --cpus 4 --mem-mb 8192 --time 04:00:00); rc=$?
ok_if "(( rc == 0 )) && grep -q 'Expected wait: about 2.0 h' <<<\"\$out\"" \
      "with no folder, the job given on the command line gets the same answer (rc=$rc)"
out=$(_bf); rc=$?
ok_if "(( rc == 2 )) && grep -q 'is not a calculation folder' <<<\"\$out\" && grep -q -- '--time' <<<\"\$out\"" \
      "with neither, it refuses: not a calculation folder, and how to give the job instead (rc=$rc)"
out=$(CONF="$W/twins.fake/cluster.conf" _bf --nodes 1 --cpus 4 --mem-mb 8192 --time 240); rc=$?
ok_if "(( rc == 0 )) && grep -qE '^  partition +fakepart' <<<\"\$out\" && grep -q 'Expected wait: about 2.0 h' <<<\"\$out\"" \
      "by hand with no --partition, the profile's is used (rc=$rc)"

# Run where it was first run by hand on a real cluster: in the toolkit's own
# directory. That used to print four complaints for one cause, one of them
# false -- "NSW=0 in INCAR" where there is no INCAR at all.
out=$( cd "$TK_DIR" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" \
        WOLFPACK_CLUSTER_CONF="$W/twins.fake/cluster.conf" HOME="$e" "$WP_PY" "$Q" 2>&1 ); rc=$?
ok_if "(( rc == 2 )) && [[ \$(grep -c '^backfill-study:' <<<\"\$out\") == 1 ]] && ! grep -q 'NSW' <<<\"\$out\"" \
      "in the toolkit's own folder: one message, not four (rc=$rc)"
ok_if "grep -q 'still missing: --nodes --cpus --mem-mb\$' <<<\"\$out\"" \
      "naming what a wait estimate cannot do without, less --partition, which the profile gives"
out=$( "$WP_PY" "$Q" "$W/does-not-exist" 2>&1 ); rc=$?
ok_if "(( rc == 2 )) && grep -q 'no such folder' <<<\"\$out\"" "a folder that does not exist is named as such"

# vasp-relax-loop's call (--machine): its own step estimate in, a chunk
# walltime out. Too little data: the profile's walltime (60 min here), not a
# built-in 600.
out=$(CONF="$W/twins.fake/cluster.conf" _bf --machine --partition fakepart --nodes 1 --cpus 4 \
        --mem-mb 8192 --t-ion-s 25.6 --steps 20 --startup-s 10)
ok_if "grep -q 'PROPOSED CHUNK   : 2 h' <<<\"\$out\" && grep -q '^WP_BACKFILL_STUDY wall_min=120 source=study' <<<\"\$out\"" \
      "--machine: the chain's step estimate in, its chunk walltime out (2 h)"
out=$(CONF="$W/twins.fake/cluster.conf" _bf --machine --partition fakepart --nodes 1 --cpus 4 \
        --mem-mb 8192 --t-ion-s 25.6 --steps 20 --startup-s 10 --min-jobs 1000)
ok_if "grep -q '^WP_BACKFILL_STUDY wall_min=60 source=fallback' <<<\"\$out\"" \
      "with too little data, the chain falls back to the profile's walltime (60 min)"
out=$(_bf --machine --partition fakepart --nodes 1 --cpus 4 --mem-mb 8192); rc=$?
ok_if "(( rc == 2 ))" "--machine without the chain's step estimate is refused (rc=$rc)"

# ===========================================================================
# 8. A REAL CASE: the LaMnO3 relaxation on Leftraru
# ===========================================================================
# 1 node x 56 ranks, 46 GB, --time=7-00:00:00, NSW = 120. The queue: 76 short
# jobs, and 10 week-long jobs of this size that waited 35-37 min (median 36).
d=$(ch_setup lamno3); fk="$d.fake"
cat > "$d/slurm_vasptest.sh" <<'EOF'
#!/bin/bash
#SBATCH --job-name=VASP
#SBATCH --partition=fakepart
#SBATCH --nodes=1
#SBATCH --ntasks=56
#SBATCH --mem-per-cpu=850
#SBATCH --time=7-00:00:00
EOF
sed -i -e 's/WP_CHUNK_WALLTIME_MIN="60"/WP_CHUNK_WALLTIME_MIN="600"/' "$fk/cluster.conf"
printf 'stage="test"\ntest_avg_loop="263.377"\ntest_ranks="56"\ntest_cpu_eff="100"\ntest_startup_s="889"\ntest_scf_per_ionic="0"\n' \
    > "$d/.wolfpack/state.env"
sed -i 's/^NSW .*/NSW    = 120/' "$d/INCAR"
"$WP_PY" - "$fk/history" <<'PY'
import sys, datetime as dt
with open(sys.argv[1], "w") as fh:
    i = 0
    for lim, wait, n, cpus in ((30, 1, 76, 4), (10080, 35, 10, 48)):
        for k in range(n):
            sub = dt.datetime(2026, 9, 1) + dt.timedelta(minutes=53 * i); i += 1
            sta = sub + dt.timedelta(minutes=wait + (k % 3))
            fh.write(f"{i}|fakepart|{sub.isoformat()}|{sub.isoformat()}|{sta.isoformat()}|"
                     f"COMPLETED|x|{lim}|1|{cpus}|cpu={cpus},mem=40G,node=1|\n")
PY
touch "$d/VASP-13276000.out" "$d/VASP-13276000.err"
printf '13276000|2026-09-23T18:00:00|2026-09-23T18:00:00|2026-09-23T18:12:00|RUNNING|10080|7-00:00:00\n' \
    > "$fk/sacct.13276000"

out=$(ch_backfill "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -q 'Expected wait: about 36 min. Of the 10 jobs of your size that asked for 4 to 7 days' <<<\"\$out\"" \
      "the 7-day job waits about 36 min: the median of the 10 similar week-long jobs"
ok_if "grep -q 'Your job 13276000 here asked for 7 days and waited 12 min' <<<\"\$out\"" \
      "and it reports what the folder's own job waited"
ok_if "grep -qE '^  4 to 7 days +36 min +37 min +10\$' <<<\"\$out\" && ! grep -q 'up to 1 h' <<<\"\$out\"" \
      "the table shows jobs of this size only -- the 76 short jobs of 4 cores are not"
ok_if "(( \$(wc -l <<<\"\$out\") <= 15 )) && ! grep -q 'WP_BACKFILL_STUDY' <<<\"\$out\"" \
      "in $(wc -l <<<"$out") lines, with no machine line"

# ===========================================================================
# 8b. SANTOS DUMONT: a 7-day job on a partition where nobody asks for more than 4
# ===========================================================================
# As seen on sequana_cpu: 1 x 48 cores, 73 GB, --time=7-00:00:00, and in 30
# days no job asked for more than 4 days. With scontrol showing no MaxTime,
# the report used to borrow the 4-day jobs' wait for the 7-day job ("~31.8 h,
# jobs that asked for 4 days to 14 days") and say nothing of the limit.
s=$(ch_setup sdumont); sf="$s.fake"
printf '#!/bin/bash\n#SBATCH --partition=fakepart\n#SBATCH --nodes=1\n#SBATCH --ntasks=48\n#SBATCH --mem-per-cpu=1560\n#SBATCH --time=7-00:00:00\n' \
    > "$s/slurm_vasptest.sh"
"$WP_PY" - "$sf/history" <<'PY'
import sys, datetime as dt
with open(sys.argv[1], "w") as fh:
    i = 0
    for lim, wait, n in ((180, 1, 20), (360, 200, 20), (5760, 1900, 20)):
        for k in range(n):
            sub = dt.datetime(2026, 9, 1) + dt.timedelta(minutes=17 * i); i += 1
            sta = sub + dt.timedelta(minutes=wait)
            fh.write(f"{i}|fakepart|{sub.isoformat()}|{sub.isoformat()}|{sta.isoformat()}|"
                     f"COMPLETED|x|{lim}|1|48|cpu=48,mem=73G,node=1|\n")
PY
printf '#!/bin/bash\nexit 0\n' > "$sf/bin/scontrol"      # shows no MaxTime at all
sout=$(ch_backfill "$s" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -q '(MaxTime: not shown by scontrol)' <<<\"\$sout\"" \
      "a MaxTime scontrol does not show is said to be unknown, not left out (rc=$rc)"
ok_if "grep -q 'No job on fakepart asked for more than 4 days in the last 30 days; yours asks for 7 days' <<<\"\$sout\" && ! grep -q 'Expected wait' <<<\"\$sout\"" \
      "a walltime beyond anything in the history gets that fact, not a wait borrowed from shorter jobs"
ok_if "grep -q 'sacctmgr show qos format=name,maxwall' <<<\"\$sout\"" "and the commands that show the limit"
cat > "$sf/bin/scontrol" <<'EOS'
#!/bin/bash
echo "PartitionName=fakepart MaxTime=4-00:00:00 State=UP"
EOS
sout=$(ch_backfill "$s" 2>&1)
ok_if "grep -q \"It asks for 7 days, more than the partition's MaxTime of 4 days: it will not start\" <<<\"\$sout\"" \
      "with MaxTime known, a job above it is said not to start"
ok_if "grep -qE '^  2 to 4 days +31.7 h' <<<\"\$sout\" && grep -qE '^  1 to 4 h +60 s' <<<\"\$sout\" && grep -qE '^  4 to 12 h +3.3 h' <<<\"\$sout\"" \
      "and the table gives the bands the history has: 60 s, 3.3 h, 31.7 h"

# The same folder with no timing data at all: the queue answer is the same --
# it never needed any.
rm -f "$d/.wolfpack/state.env"
out2=$(ch_backfill "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && [[ \"\$out2\" == \"\$out\" ]]" \
      "without vasp-test's data the queue report is unchanged (rc=$rc)"

# vasp-relax-loop there: IT estimates the step from vasp-test (263 s x 12 x
# 1.15 = 3634.6 s), hands that to backfill-study, and takes the chunk walltime
# back. 96, 120 and 168 h all need 6 chunks at that step; the shortest wins.
printf 'stage="test"\ntest_avg_loop="263.377"\ntest_ranks="56"\ntest_cpu_eff="100"\ntest_startup_s="889"\ntest_scf_per_ionic="0"\n' \
    > "$d/.wolfpack/state.env"
rm -f "$d"/VASP-13276000.*
ch_run "$d" >/dev/null 2>&1
ok_if "[[ '$(ch_state "$d" chain_wall_min)' == 5760 && '$(ch_state "$d" chain_wall_source)' == backfill-study ]]" \
      "vasp-relax-loop, from vasp-test's data and backfill-study's waits, picks 96-h chunks ($(ch_state "$d" chain_wall_min) min)"

exit $(( FAIL_N > 0 ))
