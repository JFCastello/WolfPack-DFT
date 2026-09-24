#!/usr/bin/env bash
# test_34_chain_nsw_only -- the only limit on a chunked relaxation is the
# user's own NSW.
#
# The chain used to carry three more: 50 chunks, 48 h of accumulated VASP
# time, and 7 days from launch. Any of them could stop a long relaxation part
# way, and --resume could not renew them, so after the first one each resume
# bought exactly one more chunk. They are gone. A chain launched before that
# change still has them in its state, and they must be ignored.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/chainnsw"; rm -rf "$W"; mkdir -p "$W"
source "$SUITE_DIR/chain_harness.sh"
_acct(){ ch_sacct "$1" "$2" "$2|RUNNING||" "$2.0|COMPLETED|${3}M|${4}M"; }

# ===========================================================================
# 1. NSW, AND NOTHING ELSE, ENDS IT
# ===========================================================================
# NSW = 100, 30 s per step in a 60-min chunk (3290 s of work): a warm chunk
# holds int(3290 / 34.5) = 95 steps, the cap may only double, so the chain
# runs 3, 6, 12, 24, 48 and then the 7 that are left: six chunks, 100 steps.
d=$(ch_setup allofnsw)
# EDIFFG out of reach: the fake VASP's forces keep falling, and at the harness's
# -0.01 the chain would rightly CONVERGE on them in chunk 5 -- which is not
# what this case is about.
sed -i -e 's/^NSW .*/NSW    = 100/' -e 's/^EDIFFG .*/EDIFFG = -0.0001/' "$d/INCAR"
ch_run "$d" --walltime 60 >/dev/null 2>&1
n=0
while [[ $(ch_state "$d" chain_state) == running ]] && (( n < 12 )); do
    ch_plan "$d" "t_ion=30"; _acct "$d" "$(ch_last_jid "$d")" 1500 1000
    ch_chunk "$d"; n=$(( n + 1 ))
done
caps=$(awk '/^  [0-9]+ /{printf "%s ", $5}' "$d/wolfpack_chain/chain.log")
ok_if "[[ '$(ch_state "$d" stop_reason)' == nsw_budget && '$(ch_state "$d" nsw_done)' == 100 ]]" \
      "the chain ends when NSW is spent: $(ch_state "$d" nsw_done) of 100 steps, reason $(ch_state "$d" stop_reason)"
ok_if "[[ '$caps' == '3 6 12 24 48 7 ' ]]" "in six chunks: 3 6 12 24 48 7 (got: $caps)"

# ===========================================================================
# 2. FAR PAST ALL THREE OLD LIMITS, IT KEEPS GOING
# ===========================================================================
# Chunk 60 (the cap was 50), 100 h of VASP time (the cap was 48 h), launched 30
# days ago (the cap was 7) -- and the old limits themselves written into the
# state, as a chain launched by the previous version carries them.
d=$(ch_setup pastlimits)
sed -i 's/^NSW .*/NSW    = 1000/' "$d/INCAR"
ch_run "$d" --walltime 60 >/dev/null 2>&1
ch_plan "$d" "t_ion=30"; _acct "$d" "$(ch_last_jid "$d")" 1500 1000; ch_chunk "$d"
old=$(date -d '-30 days' +%s)
{ echo "chunk_index=\"59\""; echo "wall_used_s=\"360000\""
  echo "max_chunks=\"50\""; echo "max_wall_min=\"2880\""; echo "deadline_epoch=\"$old\""
  echo "chain_started=\"$(date -d '-30 days' -Iseconds)\""; } >> "$d/wolfpack_chain/chain.env"
nsub=$(ch_nsub "$d")
ch_plan "$d" "t_ion=30"; _acct "$d" "$(ch_last_jid "$d")" 1500 1000; ch_chunk "$d"
ok_if "[[ '$(ch_state "$d" chain_state)' == running && '$(ch_nsub "$d")' == $((nsub+1)) ]]" \
      "chunk 60, 100 h of VASP, 30 days after launch: it continues and submits the next chunk"
ok_if "! grep -qE 'max_chunks|accumulated compute|deadline' '$d/wolfpack_chain/chain.log'" \
      "and chain.log mentions none of the old limits"

# A chain STOPPED by an old limit resumes, and is not stopped by it again.
sed -i 's/^chain_state=.*/chain_state="stopped"/; s/^stop_reason=.*/stop_reason="budget"/' \
    "$d/wolfpack_chain/chain.env"
rm -f "$d/wolfpack_chain/RUNNING"
ch_run "$d" --resume >/dev/null 2>&1; rc=$?
ch_plan "$d" "t_ion=30"; _acct "$d" "$(ch_last_jid "$d")" 1500 1000; ch_chunk "$d"
ok_if "(( rc == 0 )) && [[ '$(ch_state "$d" chain_state)' == running ]]" \
      "a chain the old limits had stopped resumes and runs on (rc=$rc)"

# ===========================================================================
# 3. THE OPTION IS GONE, AND SAYS SO
# ===========================================================================
d=$(ch_setup noopt)
must_refuse "--max-chunks is no longer an option" "unknown option" ch_run "$d" --max-chunks 10
ok_if "! bash '$TK_DIR/vasp_chain.sh' --mode relax --help | grep -qiE 'max-chunks|deadline'" \
      "and --help does not mention a chunk or time limit"

# ===========================================================================
# 4. --walltime IS WHOLE MINUTES
# ===========================================================================
# The chain's int() keeps digits only: "1:30" was 130 min, "90.5" was 905.
must_refuse "--walltime 1:30 is refused, not read as 130 min" "whole minutes" \
    ch_run "$d" --walltime 1:30
must_refuse "--walltime 90.5 is refused, not read as 905 min" "whole minutes" \
    ch_run "$d" --walltime 90.5

exit $(( FAIL_N > 0 ))
