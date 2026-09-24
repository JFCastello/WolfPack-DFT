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
# 7. backfill-study, STANDING ALONE
# ===========================================================================
# In a calculation folder, with no option, it reads what the chain would read.
# This folder's job (4 ranks, 8 GB, --time=04:00:00), its 25.6-s steps and
# NSW = 20, against the history above:
#   the job as written, 4 h: the 12 four-hour jobs waited 4 h
#   one job: (10 + 20 x 25.6 x 1.15) s -> 1 h; 1-h jobs wait 2 h -> ~2.1 h in all
#   the chain: 3 chunks of 2 h waiting 5 min each -> 24 min in all  => the chain
out=$(ch_backfill "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -q 'asks for --time=04:00:00' <<<\"\$out\" && grep -qE 'expected wait +~4.0 h' <<<\"\$out\"" \
      "it estimates the queue wait of the job as written: 4 h asked, ~4 h wait (rc=$rc)"
ok_if "grep -q 'vasp-relax-loop   3 chunks of 2 h, each waiting ~5 min: ~24 min in all' <<<\"\$out\" && grep -q '=> use vasp-relax-loop' <<<\"\$out\"" \
      "and recommends the chain of 2-h chunks, which finishes first here"
ok_if "grep -q 'one job           --time=01:00:00' <<<\"\$out\"" \
      "with the one-job alternative next to it, as a concrete --time (01:00:00)"
out=$(ch_backfill "$d" --details 2>&1)
ok_if "grep -q 'NSW in INCAR' <<<\"\$out\" && grep -q 'slurm_vasptest.sh --ntasks' <<<\"\$out\" && grep -q 'PROPOSED CHUNK   : 2 h' <<<\"\$out\"" \
      "--details adds the per-walltime table and where each input came from"
ok_if "[[ ! -d '$d/wolfpack_chain' && '$(ch_nsub "$d")' == 0 ]]" "it creates nothing and submits nothing"

# One folder, both programs, the same numbers. If the two ever read a folder
# differently, the standalone answer would describe a chain that is not the one
# that runs. The start-up time is written the way vasp-test writes it, with a
# decimal: the chain used to strip the point and read "10.4" as 104 s.
d=$(ch_setup twins); cp "$H" "$W/twins.fake/history"
sed -i 's/test_startup_s="10"/test_startup_s="10.4"/' "$d/.wolfpack/state.env"
line=$(ch_backfill "$d" --machine 2>/dev/null | grep '^WP_BACKFILL_STUDY ')
ch_run "$d" >/dev/null 2>&1
_f(){ sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$line"; }
ok_if "[[ -n '$(_f t_ion_s)' && '$(_f t_ion_s)' == '$(ch_state "$d" t_ionic_s)' ]]" \
      "the same ionic step: backfill-study $(_f t_ion_s) s, the chain $(ch_state "$d" t_ionic_s) s"
ok_if "[[ '$(_f steps)' == '$(ch_state "$d" nsw_target)' && '$(_f cpus)' == '$(ch_state "$d" chain_ranks)' && '$(_f nodes)' == '$(ch_state "$d" chain_nodes)' ]]" \
      "the same steps, ranks and nodes ($(_f steps), $(_f cpus), $(_f nodes))"
ok_if "[[ '$(_f mem_mb)' == \$(( $(ch_state "$d" chain_mem_per_cpu) * $(ch_state "$d" chain_ranks) )) ]]" \
      "the same memory ($(_f mem_mb) MB)"
ok_if "[[ '$(_f wall_min)' == '$(ch_state "$d" chain_wall_min)' ]]" \
      "and the same proposal: $(_f wall_min) min, which is what the chain then runs with"
ok_if "[[ '$(ch_state "$d" t_startup_s)' == 10 ]]" \
      "a start-up written as 10.4 s is read as 10 s, not 104 (the chain read $(ch_state "$d" t_startup_s))"

# No folder at all: everything on the command line.
e="$W/nofolder"; mkdir -p "$e"
out=$( cd "$e" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" FAKE_DIR="$W/twins.fake" \
        FAKE_MAXTIME=UNLIMITED WOLFPACK_CLUSTER_CONF=/nonexistent HOME="$e" \
        "$WP_PY" "$Q" --partition fakepart --nodes 1 --cpus 4 --mem-mb 8192 --t-ion-s 25.6 \
        --steps 20 --startup-s 10 --margin-min 5 --default-wall-min 60 --machine 2>&1 ); rc=$?
ok_if "(( rc == 0 )) && grep -q 'PROPOSED CHUNK   : 2 h' <<<\"\$out\"" \
      "with no folder, given the job on the command line, it answers the same (rc=$rc)"
out=$( cd "$e" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" WOLFPACK_CLUSTER_CONF=/nonexistent \
        HOME="$e" "$WP_PY" "$Q" 2>&1 ); rc=$?
ok_if "(( rc == 2 )) && grep -q 'is not a calculation folder' <<<\"\$out\" && grep -q -- '--time' <<<\"\$out\"" \
      "with neither, it refuses: not a calculation folder, and how to give the job instead (rc=$rc)"

# Run where it was first run by hand on a real cluster: in the toolkit's own
# directory. That used to print four complaints for one cause, one of them
# false -- "NSW=0 in INCAR" where there is no INCAR at all.
out=$( cd "$TK_DIR" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" \
        WOLFPACK_CLUSTER_CONF="$W/twins.fake/cluster.conf" HOME="$e" "$WP_PY" "$Q" 2>&1 ); rc=$?
ok_if "(( rc == 2 )) && [[ \$(grep -c '^backfill-study:' <<<\"\$out\") == 1 ]] && ! grep -q 'NSW=0' <<<\"\$out\"" \
      "in the toolkit's own folder: one message, not four, and no false 'NSW=0 in INCAR' (rc=$rc)"
ok_if "grep -q 'still missing: --nodes --cpus --mem-mb\$' <<<\"\$out\"" \
      "it names what the queue estimate cannot do without, less --partition, which the profile gives"

# A calculation folder with no INCAR: the queue wait still, and says what the
# recommendation lacks -- not NSW=0.
f="$W/noincar"; rm -rf "$f"; cp -r "$W/twins" "$f"; rm -f "$f/INCAR" "$f/INCAR.chain.bak"
out=$( cd "$f" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" FAKE_DIR="$W/twins.fake" \
        FAKE_MAXTIME=UNLIMITED WOLFPACK_CLUSTER_CONF="$W/twins.fake/cluster.conf" HOME="$e" \
        "$WP_PY" "$Q" 2>&1 ); rc=$?
ok_if "(( rc == 0 )) && grep -q 'no INCAR here' <<<\"\$out\" && ! grep -q 'NSW=0' <<<\"\$out\" && grep -q 'QUEUE WAIT' <<<\"\$out\" && ! grep -q 'RECOMMENDATION' <<<\"\$out\"" \
      "a folder with no INCAR gives the queue wait, says the INCAR is missing, recommends nothing (rc=$rc)"

out=$( "$WP_PY" "$Q" "$W/does-not-exist" 2>&1 ); rc=$?
ok_if "(( rc == 2 )) && grep -q 'no such folder' <<<\"\$out\"" "a folder that does not exist is named as such"

# By hand, outside any calculation folder, the profile still counts: its
# partition, and its chunk settings.
out=$( cd "$e" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" FAKE_DIR="$W/twins.fake" \
        FAKE_MAXTIME=UNLIMITED WOLFPACK_CLUSTER_CONF="$W/twins.fake/cluster.conf" HOME="$e" \
        "$WP_PY" "$Q" --nodes 1 --cpus 4 --mem-mb 8192 --t-ion-s 25.6 --steps 20 --startup-s 10 \
        --details 2>&1 ); rc=$?
ok_if "(( rc == 0 )) && grep -q 'partition        profile WP_MAIN_PARTITION' <<<\"\$out\" && grep -q 'PROPOSED CHUNK   : 2 h' <<<\"\$out\"" \
      "by hand with no --partition, the profile's is used and said so (rc=$rc)"
# All six given: the profile's chunk settings still count. They used to be
# replaced by built-in defaults (a 600-min fallback walltime, where this
# profile says 60).
out=$( cd "$e" && env PATH="$W/twins.fake/bin:/usr/bin:/bin" FAKE_DIR="$W/twins.fake" \
        FAKE_MAXTIME=UNLIMITED WOLFPACK_CLUSTER_CONF="$W/twins.fake/cluster.conf" HOME="$e" \
        "$WP_PY" "$Q" --partition fakepart --nodes 1 --cpus 4 --mem-mb 8192 --t-ion-s 25.6 \
        --steps 20 --startup-s 10 --min-jobs 1000 --machine 2>&1 ); rc=$?
ok_if "(( rc == 0 )) && grep -q '^WP_BACKFILL_STUDY wall_min=60 source=fallback' <<<\"\$out\"" \
      "all six given by hand, the fallback is still the profile's walltime (60 min), not a built-in 600"

# ===========================================================================
# 8. A REAL CASE: a cell relaxation, before and while it runs
# ===========================================================================
# Shaped on a LaMnO3 relaxation run on a real cluster: 1 node x 56 ranks,
# 46 GB, --time=7-00:00:00, NSW = 120. vasp-test's benchmark measured 263.377 s
# per electronic step but stopped before completing an ionic step, and
# recorded an 889-s start-up. The queue: 76 short jobs, and 10 week-long jobs
# of this size that waited 35-37 min (median 36).
L="$W/lamno3"; d=$(ch_setup lamno3); fk="$d.fake"
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

# (a) BEFORE launching: vasp-test is all there is. One ionic step is estimated
#     263.377 x 12 (assumed) x 1.15 = 3634.6 s; one job needs
#     (889 + 120 x 3634.6 x 1.15) s = 139.6 h -> 140 h = 5-20:00:00.
out=$(ch_backfill "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -qE 'expected wait +~36 min +median of 10 jobs of your size' <<<\"\$out\"" \
      "before launching, the job as written (7 days) waits ~36 min: the median of the 10 similar week-long jobs"
ok_if "grep -q 'estimated from vasp-test' <<<\"\$out\" && grep -q 'the 12 is ASSUMED' <<<\"\$out\"" \
      "the step time is labelled an estimate from vasp-test, and what in it is assumed"
ok_if "grep -q 'one job           --time=5-20:00:00' <<<\"\$out\" && grep -q '=> submit as one job with  #SBATCH --time=5-20:00:00' <<<\"\$out\"" \
      "and a concrete walltime to submit with: --time=5-20:00:00"
ok_if "(( \$(wc -l <<<\"\$out\") <= 25 )) && ! grep -q 'WP_BACKFILL_STUDY' <<<\"\$out\" && ! grep -q 'fits?' <<<\"\$out\"" \
      "in $(wc -l <<<"$out") lines, with no machine line and no 17-row table"

# (b) WHILE it runs: its OUTCAR has 19 ionic steps (5400 s, then 3300 s each).
#     Measured beats estimated: max(mean without the cold first, last) = 3300 s;
#     one job then needs (889 + 120 x 3300 x 1.15) s = 126.8 h -> 5-07:00:00.
"$WP_PY" - "$d/OUTCAR" <<'PY'
import sys
with open(sys.argv[1], "w") as fh:
    for k in range(19):
        t = 5400 if k == 0 else 3300
        fh.write("     LOOP+:  cpu time   %.1f: real time   %.1f\n" % (t, t))
PY
touch "$d/VASP-13276000.out" "$d/VASP-13276000.err"
printf '13276000|2026-09-23T18:00:00|2026-09-23T18:00:00|2026-09-23T18:12:00|RUNNING|10080|7-00:00:00\n' \
    > "$fk/sacct.13276000"
out=$(ch_backfill "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -qE 'one ionic step +~55 min +measured: 19 ionic step' <<<\"\$out\" && ! grep -q 'ASSUMED' <<<\"\$out\"" \
      "with a run in the folder, the step is MEASURED from its OUTCAR (55 min), not assumed"
ok_if "grep -q 'one job           --time=5-07:00:00' <<<\"\$out\" && grep -q 'more than the run can use' <<<\"\$out\"" \
      "the recommendation follows the measurement (5-07:00:00), and says 7 days is more than it can use"
ok_if "grep -q 'job 13276000 asking 7-00:00:00 waited 12 min' <<<\"\$out\" && grep -q '19 step(s) already done here' <<<\"\$out\"" \
      "and it reports what the folder's own job waited, and how far it got"

# (c) Too little asked for: 2 days where the run can need 5-07:00:00.
sed -i 's/--time=7-00:00:00/--time=2-00:00:00/' "$d/slurm_vasptest.sh"
out=$(ch_backfill "$d" 2>&1)
ok_if "grep -q 'asks for 2-00:00:00 now: too little' <<<\"\$out\"" "a walltime too short for all of NSW is flagged"

# (d) No timing at all -- no vasp-test, no run: the queue wait, and nothing
#     invented. This is the case the command must still serve.
rm -f "$d/.wolfpack/state.env" "$d/OUTCAR" "$d"/VASP-13276000.*
sed -i 's/--time=2-00:00:00/--time=7-00:00:00/' "$d/slurm_vasptest.sh"
out=$(ch_backfill "$d" 2>&1); rc=$?
ok_if "(( rc == 0 )) && grep -qE 'expected wait +~36 min' <<<\"\$out\" && ! grep -q 'RECOMMENDATION' <<<\"\$out\" && grep -q 'no timing here yet' <<<\"\$out\"" \
      "with no timing data, it still gives the queue wait -- and recommends no walltime it could not know (rc=$rc)"

exit $(( FAIL_N > 0 ))
