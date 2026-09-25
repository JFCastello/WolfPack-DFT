#!/usr/bin/env bash
# vasp-configure writes the profile every job script is built from. A value
# lost here is a wrong job everywhere, silently.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
W="$WORK/configure"; rm -rf "$W"; mkdir -p "$W"
C="$TK_DIR/vasp_configure.sh"
conf="$W/cluster.conf"

# --- a profile can be created from nothing ---------------------------------
timeout 120 bash "$C" --conf "$conf" --non-interactive >"$W/gen.log" 2>&1
ok_if "[[ -s '$conf' ]]" "a profile is generated where none existed"
n=$(grep -cE '^WP_[A-Z_]+=' "$conf" 2>/dev/null || echo 0)
ok_if "[[ $n -ge 20 ]]" "the generated profile carries the expected settings ($n)"

# --- a flag patches ONE value and leaves the rest ---------------------------
# This is the promise the flags make, and the one that matters: vasp-test tells
# users to run `vasp-configure --debug-max-cores N`, and if that re-detected
# everything it would wipe hand-tuned values they never mentioned.
before=$(md5sum < "$conf")
timeout 120 bash "$C" --conf "$conf" --non-interactive --max-cores 123 >>"$W/gen.log" 2>&1
grep -q 'WP_MAX_CORES="123"' "$conf" \
    && pass "a flag sets the value it names" \
    || fail "--max-cores 123 did not take"
others=$(grep -vE '^WP_MAX_CORES=|^#' "$conf" | md5sum)
timeout 120 bash "$C" --conf "$conf" --non-interactive --max-cores 456 >>"$W/gen.log" 2>&1
others2=$(grep -vE '^WP_MAX_CORES=|^#' "$conf" | md5sum)
ok_if "[[ '$others' == '$others2' ]]" "a flag changes NOTHING but the value it names"

# --- a hand-added setting survives ------------------------------------------
# The profile's own header says "or edit by hand (KEY=value)". A wizard that
# then truncates the file back to the keys it knows makes that invitation a
# trap, and the loss is silent.
printf '\nWP_SOMETHING_I_ADDED="keepme"\n' >> "$conf"
timeout 120 bash "$C" --conf "$conf" --non-interactive >>"$W/gen.log" 2>&1
grep -q 'WP_SOMETHING_I_ADDED="keepme"' "$conf" \
    && pass "a hand-added setting survives a full regeneration" \
    || fail "a hand-added setting was silently deleted by the wizard"

# --- the chunk walltime is reachable from here ------------------------------
# vasp-scf-loop reads WP_CHUNK_WALLTIME_MIN. If the configuration tool cannot
# set it, the only way to change it is to edit the file -- see the test above
# for why that used to be a trap.
timeout 120 bash "$C" --conf "$conf" --non-interactive --chunk-walltime 240 >>"$W/gen.log" 2>&1
grep -q 'WP_CHUNK_WALLTIME_MIN="240"' "$conf" \
    && pass "the chunk walltime can be set from the configuration tool" \
    || fail "WP_CHUNK_WALLTIME_MIN cannot be set by vasp-configure"

# --- --show reads back what was written -------------------------------------
out=$(timeout 60 bash "$C" --conf "$conf" --show 2>&1)
grep -q 'WP_CHUNK_WALLTIME_MIN="240"' <<<"$out" \
    && pass "--show reads back the value that was written" \
    || fail "--show does not report the stored chunk walltime"

# --- the adversarial half ---------------------------------------------------
# Values that are arithmetic nonsense must not reach a job script. A zero core
# count produces a job SLURM rejects; a negative one produces a job nobody can
# reason about.
for bad in 0 -8 abc; do
    cp "$conf" "$W/probe.conf"
    timeout 60 bash "$C" --conf "$W/probe.conf" --non-interactive --max-cores "$bad" \
        >"$W/bad.log" 2>&1 || true
    got=$(grep -oP '^WP_MAX_CORES="\K[^"]*' "$W/probe.conf" 2>/dev/null)
    if [[ "$got" == "$bad" ]]; then
        fail "--max-cores $bad was written into the profile verbatim"
    else
        pass "--max-cores $bad does not end up in the profile (got '${got:-unset}')"
    fi
done

# An empty module list is a STATEMENT, not a mistake: it is every machine whose
# VASP is an absolute path. It must be accepted, and must not swallow the next
# flag as its value.
cp "$conf" "$W/mod.conf"
timeout 60 bash "$C" --conf "$W/mod.conf" --non-interactive --vasp-modules "" >"$W/mod.log" 2>&1
grep -q '^WP_VASP_MODULES=""' "$W/mod.conf" \
    && pass "an empty module list is accepted and stored empty" \
    || fail "--vasp-modules '' was not stored as empty"
timeout 60 bash "$C" --conf "$W/mod2.conf" --non-interactive --vasp-modules --max-cores 48 \
    >"$W/mod2.log" 2>&1 || true
got=$(grep -oP '^WP_VASP_MODULES=.\K[^"'"'"']*' "$W/mod2.conf" 2>/dev/null)
[[ "$got" == "--max-cores" ]] \
    && fail "--vasp-modules swallowed the NEXT FLAG as its value" \
    || pass "--vasp-modules does not swallow the following flag"

# --- the node limit is read from the partition -----------------------------
# The core cap alone does not bound the nodes of an evenly split job (189 ranks
# on 48-core nodes is 7 nodes of 27), and a partition whose MaxNodes is lower
# rejects it. The testbed's main partition says MaxNodes=5.
if have_slurm; then
    timeout 120 env SLURM_CONF="$TESTBED_ROOT/slurm.conf" bash "$C" --conf "$W/nodes.conf" \
        --non-interactive --main-partition sequana_cpu >"$W/nodes.log" 2>&1
    got=$(grep -oP '^WP_MAX_NODES="\K[^"]*' "$W/nodes.conf" 2>/dev/null)
    ok_if "[[ '$got' == 5 ]] && grep -q '5 nodes <- partition MaxNodes' '$W/nodes.log'" \
          "the node limit is read from the partition's MaxNodes, and says so (got '${got:-unset}')"
else
    skip "no reachable slurmctld -- the node limit's detection was not checked"
fi
timeout 60 bash "$C" --conf "$W/nodes2.conf" --non-interactive --max-nodes 3 >"$W/nodes2.log" 2>&1
grep -q '^WP_MAX_NODES="3"' "$W/nodes2.conf" \
    && pass "--max-nodes sets it by hand" \
    || fail "--max-nodes 3 did not take"
cp "$W/nodes2.conf" "$W/nodes3.conf"
timeout 60 bash "$C" --conf "$W/nodes3.conf" --non-interactive --max-nodes 0 >"$W/nodes3.log" 2>&1 || true
ok_if "grep -q '^WP_MAX_NODES=\"3\"' '$W/nodes3.conf'" "--max-nodes 0 is refused, and the profile keeps its value"
exit $(( FAIL_N > 0 ))
