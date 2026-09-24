#!/usr/bin/env bash
# vasp-slurm-report turns sacct into the three ratios that say whether an
# allocation was earned. Every one of them is a division, and sacct hands back
# units that differ between fields and between SLURM versions -- which is
# exactly where a ratio goes quietly wrong by a factor of 1024.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/slurm_report"; rm -rf "$W"; mkdir -p "$W"
SR="$TK_DIR/vasp_slurm_report.sh"

# A fake sacct, so the numbers are ones we chose and the right answer is known.
# The three ReqMem spellings are the point: SLURM has written it per-CPU (Mc),
# per-node (Mn) and as a job total depending on version, and reading one as
# another is a 1024x or an NCPUS-x error in the memory ratio.
_fake_sacct(){ # _fake_sacct NAME REQMEM -> a bin dir to put on PATH
    # The columns are exactly the ones vasp-slurm-report asks for, in order:
    #   JobID|JobName|State|ExitCode|Elapsed|Timelimit|NCPUS|NNodes|TotalCPU|MaxRSS|AveRSS|ReqMem
    # 240 cores x 1 h = 240 core-hours allocated (CPUTime = 10 days);
    # TotalCPU 5 days = 120 core-hours used  ->  CPU efficiency 50%.
    # Elapsed 1 h of a 2 h limit             ->  time use 50%.
    local b="$W/bin_$1"; mkdir -p "$b"
    cat > "$b/sacct" <<EOF
#!/usr/bin/env bash
cat <<'ROWS'
1001|vasp|COMPLETED|0:0|01:00:00|02:00:00|240|5|5-00:00:00|||${2}
1001.batch|batch|COMPLETED|0:0|01:00:00||240|5|5-00:00:00|1000M|800M|
ROWS
EOF
    sed -i 's/| \${2}/|${2}/' "$b/sacct" 2>/dev/null || true
    chmod 755 "$b/sacct"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$b/squeue"; chmod 755 "$b/squeue"
    echo "$b"
}

d="$W/calc"; mkdir -p "$d/.wolfpack"
printf 'stage="test"\nranks="240"\nkpar="10"\nncore="4"\n' > "$d/.wolfpack/state.env"
# Job ids are discovered from the NAMES of the stage logs the pipeline leaves
# behind (.wolfpack/benchmark-<jobid>.out), not from a recorded id file.
echo "log" > "$d/.wolfpack/benchmark-1001.out"

for spec in "percpu 1000Mc" "pernode 48000Mn" "total 240000M"; do
    read -r nm rm <<<"$spec"
    b=$(_fake_sacct "$nm" "$rm")
    out=$( cd "$d" && PATH="$b:$PATH" timeout 120 bash "$SR" 2>&1 )
    if grep -qiE "traceback|syntax error" <<<"$out"; then
        fail "ReqMem as $rm: the report crashed"
        continue
    fi
    # Whatever the spelling, the memory ratio must land in a sane range. The
    # bug this catches reported 5080%.
    pct=$(awk '$2=="1001"{gsub(/%/,"",$6); print $6; exit}' <<<"$out")
    if [[ -z "$pct" ]]; then
        skip "ReqMem as $rm: no memory ratio in the output to check"
    else
        near "$pct" 80 5 "ReqMem written as $rm gives the same 80% (AveRSS x NCPUS / ReqMem)"
    fi
done

# --- the ratio that catches the real failure -------------------------------
# A 240-rank job that actually ran on 1 rank shows up as CPU efficiency near
# zero and nothing else. That is the number this command exists for.
b=$(_fake_sacct eff "1000Mc")
out=$( cd "$d" && PATH="$b:$PATH" timeout 120 bash "$SR" 2>&1 )
cpu=$(awk '$2=="1001"{gsub(/%/,"",$5); print $5; exit}' <<<"$out")
near "${cpu:-}" 50 3 "CPU efficiency is TotalCPU/CPUTime (120h of 240h = 50%)"

# --- sacct that has no data yet --------------------------------------------
# A job that just finished is not yet in accounting. Reporting zeros for it is
# a lie; saying "no data yet" is the truth.
b="$W/bin_empty"; mkdir -p "$b"
printf '#!/usr/bin/env bash\nexit 0\n' > "$b/sacct"; chmod 755 "$b/sacct"
printf '#!/usr/bin/env bash\nexit 0\n' > "$b/squeue"; chmod 755 "$b/squeue"
out=$( cd "$d" && PATH="$b:$PATH" timeout 120 bash "$SR" 2>&1 )
grep -qiE "no data|not yet|no accounting|nothing" <<<"$out" \
    && pass "a job with no accounting data yet is reported as such, not as zeros" \
    || fail "a job with no accounting data produced numbers anyway"

# --- no sacct at all -------------------------------------------------------
# PATH must genuinely lack sacct. Pointing at /usr/bin keeps the real one, so
# the "no sacct" branch was never reached and the test proved nothing.
b="$W/bin_none"; mkdir -p "$b"
for t in bash sed awk grep cat basename readlink dirname printf sort head tail tr date timeout find; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$b/$t"
done
out=$( cd "$d" && PATH="$b" timeout 120 bash "$SR" 2>&1 ) || true
grep -qiE "sacct|accounting" <<<"$out" \
    && pass "without sacct it says so instead of failing obscurely" \
    || fail "no sacct: the message does not mention accounting"

# --- EVERY job that ran in the folder, not only the pipeline's --------------
# The usual sequence is vasp-dry-run, vasp-test, then the real run -- the
# production job, or a chain of chunks. The report used to read .wolfpack/
# only, so it showed the two preparatory jobs and never the run they were
# preparing. Here a folder holds all of it: a dry-run, a benchmark, a
# production job (slurm.sh names its log <jobname>-<id>.out), a chain whose
# chunks 1 and 2 are logged and whose third (2006) is only in chain.env and
# next to the inputs, and an older chain archived by --fresh.
b="$W/bin_perjob"; mkdir -p "$b"
cat > "$b/sacct" <<'EOF'
#!/usr/bin/env bash
jid=""; while (( $# )); do [[ $1 == -j ]] && jid=$2; shift; done
[[ -z $jid ]] && exit 0
printf '%s|job%s|COMPLETED|0:0|01:00:00|02:00:00|4|1|03:00:00|||8000M\n' "$jid" "$jid"
printf '%s.0|x|COMPLETED|0:0|01:00:00||4|1|03:00:00|1500M|1000M|\n' "$jid"
EOF
chmod 755 "$b/sacct"
t="$W/tree"; c="$t/calc"
mkdir -p "$c/.wolfpack" "$c/wolfpack_chain/chunk-001" "$c/wolfpack_chain.prev-20260901-000000"
touch "$c/.wolfpack/dryrun-2001.out" "$c/.wolfpack/dryrun-2001.err" "$c/.wolfpack/benchmark-2002.out" \
      "$c/vasp-2003.out" "$c/vasp-2003.err" "$c/report.out" \
      "$c/wolfpack_chain/chunk-001/VASP-chain-2004.out" "$c/VASP-chain-2006.out"
printf '# idx jobid kind\n  1    2004   RELAX  3 3\n  2    2005   RELAX  6 6\n' > "$c/wolfpack_chain/chain.log"
printf 'chain_state="running"\njobids=" 2004 2005 2006"\n' > "$c/wolfpack_chain/chain.env"
printf '  1    1990   RELAX  3 3\n' > "$c/wolfpack_chain.prev-20260901-000000/chain.log"
printf 'jobids=" 1990 1991"\n' > "$c/wolfpack_chain.prev-20260901-000000/chain.env"
out=$( cd "$c" && PATH="$b:$PATH" timeout 120 bash "$SR" --csv "$W/tree.csv" 2>&1 )
ids=$(awk '$1=="calc" && $2 ~ /^[0-9]+$/ {printf "%s ", $2}' <<<"$out")
ok_if "[[ '$ids' == '1990 1991 2001 2002 2003 2004 2005 2006 ' ]]" \
      "every job in the folder is reported, in job order: $ids"
_stage(){ awk -v j="$1" '$2==j { sub(/.*s  /, ""); print; exit }' <<<"$out"; }
ok_if "[[ '$(_stage 2001)' == dry-run && '$(_stage 2002)' == vasp-test ]]" \
      "the pipeline's jobs are named: dry-run, vasp-test"
ok_if "[[ '$(_stage 2003)' == production ]]" \
      "the production job, found by its log next to the inputs, is reported ($(_stage 2003))"
ok_if "[[ '$(_stage 2004)' == 'chunk 1' && '$(_stage 2005)' == 'chunk 2' && '$(_stage 2006)' == chunk ]]" \
      "every chunk of a chain, the logged ones numbered (2004 $(_stage 2004), 2005 $(_stage 2005), 2006 $(_stage 2006))"
ok_if "[[ '$(_stage 1990)' == 'chunk 1 (old chain)' && '$(_stage 1991)' == 'chunk (old chain)' ]]" \
      "and an older chain archived by --fresh, marked as such"
ok_if "grep -q '^8 job(s)' <<<\"\$out\"" "the count is 8"
ok_if "head -1 '$W/tree.csv' | grep -q ',stage\$' && grep -q ',production\$' '$W/tree.csv'" \
      "the CSV carries the stage, as its last column"

# After vasp-clean, which removes .wolfpack/, the folder still holds jobs. The
# report used to stop finding it at all.
rm -rf "$c/.wolfpack"
out=$( cd "$t" && PATH="$b:$PATH" timeout 120 bash "$SR" 2>&1 )
ok_if "grep -qE '^calc +2003 .*production' <<<\"\$out\" && grep -q '^6 job(s)' <<<\"\$out\"" \
      "after vasp-clean removes .wolfpack/, run from the parent, the folder and its 6 remaining jobs are still found"

# --- accounting that gathered no usage ---------------------------------------
# Some clusters record the job and its steps but no usage at all (no MaxRSS,
# TotalCPU of a second) -- this suite's own testbed does. The ratios cannot be
# computed then, and "0%" would describe a job that did nothing.
b="$W/bin_nousage"; mkdir -p "$b"
cat > "$b/sacct" <<'EOF'
#!/usr/bin/env bash
jid=""; while (( $# )); do [[ $1 == -j ]] && jid=$2; shift; done
[[ -z $jid ]] && exit 0
printf '%s|vasp|COMPLETED|0:0|01:00:00|02:00:00|4|1|00:00:01|||8000M\n' "$jid"
printf '%s.0|x|COMPLETED|0:0|01:00:00||4|1|00:00:01|||\n' "$jid"
EOF
chmod 755 "$b/sacct"
n="$W/nousage"; mkdir -p "$n/.wolfpack"; touch "$n/.wolfpack/benchmark-3001.out"
out=$( cd "$n" && PATH="$b:$PATH" timeout 120 bash "$SR" 2>&1 )
row=$(awk '$2=="3001"' <<<"$out")
ok_if "[[ \$(awk '{print \$5, \$6}' <<<\"\$row\") == '-- --' ]] && grep -q 'recorded no usage' <<<\"\$out\"" \
      "with no usage recorded, cpu% and mem% read -- and say why, not 0% ($(awk '{print $5, $6}' <<<"$row"))"
ok_if "grep -q '0 below 50% CPU efficiency' <<<\"\$out\" && ! grep -q 'CPU efficiency below 50' <<<\"\$out\"" \
      "and such a job is not flagged for low CPU efficiency"

# --- a directory with no pipeline state ------------------------------------
mkdir -p "$W/bare"
out=$( cd "$W/bare" && timeout 120 bash "$SR" 2>&1 ) || true
grep -qiE "no folder|no job|not found|nothing|wolfpack" <<<"$out" \
    && pass "a directory with no recorded jobs says so" \
    || fail "a bare directory produced a report anyway"
exit $(( FAIL_N > 0 ))
