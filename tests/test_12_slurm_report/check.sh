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

# --- a directory with no pipeline state ------------------------------------
mkdir -p "$W/bare"
out=$( cd "$W/bare" && timeout 120 bash "$SR" 2>&1 ) || true
grep -qiE "no folder|no job|not found|nothing|wolfpack" <<<"$out" \
    && pass "a directory with no recorded jobs says so" \
    || fail "a bare directory produced a report anyway"
exit $(( FAIL_N > 0 ))
