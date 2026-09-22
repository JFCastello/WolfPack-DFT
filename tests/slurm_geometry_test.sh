#!/usr/bin/env bash
# Hand every SLURM script the toolkit writes to a real slurmctld and ask it.
#
# ============================================================================
# WHY THIS EXISTS
# ============================================================================
# The recommender used to be checked by reading its score table. The table said
# "190 ranks, 4 nodes, 48 per node" and looked right; the slurm.sh it wrote next
# to that table said `--nodes=190 --ntasks-per-node=1` -- 9120 cores to run 190,
# 38x the account cap -- and the real cluster refused it. Nobody compared the two
# because nothing did.
#
# So: generate the script, submit it with `sbatch --test-only` (validates against
# the live cluster, queues nothing), and fail if SLURM will not take it.
#
# ============================================================================
# THE CLUSTER IT NEEDS
# ============================================================================
# A slurmctld shaped like the target cluster. tests/slurm_testbed.sh builds one:
# a single real node plus config-only nodes, so multi-node geometries validate
# even though only one box exists. Point SLURM_CONF at it before running this.
set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK="$(dirname "$HERE")"
PY="${WP_TEST_PYTHON:-$HOME/miniconda3/envs/wolfpack-dft/bin/python}"
REC="${WP_TEST_RECOMMENDER:-$TK/vasp_recommend_slurm.py}"
CONF="${WP_TEST_CLUSTER_CONF:-$HERE/fixtures/cluster.conf.48core}"

command -v sbatch >/dev/null || { echo "SKIP: no sbatch on PATH"; exit 0; }
sinfo >/dev/null 2>&1 || { echo "SKIP: no reachable slurmctld (SLURM_CONF=${SLURM_CONF:-unset})"; exit 0; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ok=0; bad=0

# Every dry-run OUTCAR we have, at several account caps. The caps matter: the
# winning layout changes with them, and so does the geometry.
# The committed fixtures first -- they are the cases that broke production --
# then any local OUTCAR under Test/, which is gitignored and may not exist.
mapfile -t CASES < <( { find "$HERE/fixtures" -name 'dryrun_OUTCAR*' 2>/dev/null
                        find "$TK/Test" \( -name 'OUTCAR' -o -name 'dryrun_OUTCAR*' \) 2>/dev/null
                      } | sort -u )

printf '%-34s %-6s %-6s %-6s %s\n' "case" "cap" "ranks" "nodes" "verdict"
printf '%s\n' "--------------------------------------------------------------------------------"
for f in "${CASES[@]}"; do
    for cap in 48 96 240; do
        d="$W/$(md5sum <<<"$f$cap" | cut -c1-10)"; mkdir -p "$d/.wolfpack"
        cp "$f" "$d/.wolfpack/dryrun_OUTCAR"
        ( cd "$d" && WOLFPACK_CLUSTER_CONF="$CONF" "$PY" "$REC" \
              --no-report --no-apply-incar --max-cores "$cap" >rec.log 2>&1 )
        [[ -s "$d/slurm.sh" ]] || continue          # recommender refused: not this test's business
        sed -i 's|^/usr/bin/time -v srun .*|echo would-run|' "$d/slurm.sh"
        ranks=$(grep -oP '(?<=--ntasks=)\d+' "$d/slurm.sh" | head -1)
        nodes=$(grep -oP '(?<=--nodes=)\d+' "$d/slurm.sh" | head -1)
        out=$(cd "$d" && sbatch --test-only slurm.sh 2>&1)
        name="$(basename "$(dirname "$f")")/$(basename "$f")"
        if grep -qiE 'error|failure' <<<"$out"; then
            bad=$((bad+1))
            printf '%-34s %-6s %-6s %-6s %s\n' "${name:0:34}" "$cap" "$ranks" "$nodes" \
                   "REJECTED: $(sed 's/^sbatch: //' <<<"$out" | tail -1 | cut -c1-50)"
        else
            ok=$((ok+1))
        fi
        # The allocation must also stay inside the cap SLURM actually charges:
        # whole nodes, not ranks.
        cpn=$(awk -F'"' '/WP_MAIN_CPUS_PER_NODE/{print $2}' "$CONF")
        if [[ -n "$nodes" && -n "${cpn:-}" ]] && (( nodes * cpn > cap )); then
            bad=$((bad+1))
            printf '%-34s %-6s %-6s %-6s %s\n' "${name:0:34}" "$cap" "$ranks" "$nodes" \
                   "OVER CAP: $((nodes * cpn)) cores allocated for a ${cap}-core cap"
        fi
    done
done
printf '%s\n' "--------------------------------------------------------------------------------"
echo "accepted: $ok    problems: $bad"
exit $(( bad > 0 ))
