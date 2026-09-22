#!/usr/bin/env bash
# A single-node SLURM + accounting database, in user space, shaped like a real
# cluster. Start it, then run the other tests against it.
#
#   tests/slurm_testbed.sh start     # bring it up (idempotent)
#   tests/slurm_testbed.sh stop
#   tests/slurm_testbed.sh status
#   eval "$(tests/slurm_testbed.sh env)"   # export SLURM_CONF for this shell
#
# ============================================================================
# WHY IT LOOKS LIKE THIS
# ============================================================================
# The point is to let sbatch JUDGE the scripts this toolkit writes, because a
# score table that reads well and a job script SLURM refuses are two different
# things, and only the scheduler can tell them apart.
#
#   * No root, no munge. auth/none is fine for a loopback cluster with one user.
#   * Cgroups disabled: WSL2 runs in a cgroup namespace whose /sys/fs/cgroup
#     carries host pids, so slurmd cannot claim a scope and refuses to start.
#   * Two kinds of node. The real box runs jobs at its true size. wpfake[01-05]
#     exist only in the config, at 48 cores each, so a multi-node geometry can
#     be VALIDATED against a cluster shaped like the target even though only one
#     machine exists. They are pinned to 127.0.0.1: without NodeAddr, slurmctld
#     blocks on a DNS lookup for them at every reconfigure.
#   * MaxNodes on the partitions stands in for the account limit that appears on
#     a real cluster as AssocMaxNodePerJobLimit.
#
# KNOWN LIMIT: jobacct_gather collects no memory under WSL2, so sacct reports an
# empty MaxRSS. That is not a toolkit fault -- and it is useful, because it
# exercises the path a user hits when their cluster's accounting is off.
set -uo pipefail
ROOT="${WP_TESTBED_ROOT:-/tmp/slurmtest}"
CONF="$ROOT/slurm.conf"
HOSTN="$(hostname)"
LOG="$ROOT/log"

_mysql_up(){ pgrep -f "mariadbd .*$ROOT/mysql" >/dev/null 2>&1; }
_up(){ pgrep -f "$1 -D" >/dev/null 2>&1; }

start() {
    mkdir -p "$ROOT"/{state,spool,log,dbd}
    [[ -f "$CONF" ]] || { echo "no $CONF -- generate it first" >&2; exit 1; }
    if ! _mysql_up; then
        [[ -d "$ROOT/mysql" ]] || mariadb-install-db --user="$USER" \
            --datadir="$ROOT/mysql" --auth-root-authentication-method=normal >"$LOG/mysqlinit.log" 2>&1
        setsid mariadbd --datadir="$ROOT/mysql" --socket="$ROOT/mysql.sock" \
            --port=13306 --pid-file="$ROOT/mysql.pid" --bind-address=127.0.0.1 \
            >"$LOG/mysqld.out" 2>&1 < /dev/null &
        sleep 6
    fi
    export SLURM_CONF="$CONF"
    _up slurmdbd   || { setsid slurmdbd -D   >"$LOG/dbd.out"  2>&1 </dev/null & sleep 4; }
    _up slurmctld  || { setsid slurmctld -D  >"$LOG/ctld.out" 2>&1 </dev/null & sleep 4; }
    _up slurmd     || { setsid slurmd -D -N "$HOSTN" >"$LOG/d.out" 2>&1 </dev/null & sleep 4; }
    scontrol update NodeName="wpfake[01-05]" State=RESUME Reason=testbed >/dev/null 2>&1 || true
    scontrol update NodeName="$HOSTN"        State=RESUME Reason=testbed >/dev/null 2>&1 || true
    sleep 2; status
}
stop() {
    for d in slurmd slurmctld slurmdbd; do pkill -f "$d -D" 2>/dev/null || true; done
    pkill -f "mariadbd .*$ROOT/mysql" 2>/dev/null || true
    echo "stopped"
}
status() {
    export SLURM_CONF="$CONF"
    for d in mariadbd slurmdbd slurmctld slurmd; do
        if [[ $d == mariadbd ]]; then _mysql_up && s=up || s=DOWN
        else _up "$d" && s=up || s=DOWN; fi
        printf '  %-10s %s\n' "$d" "$s"
    done
    sinfo -o "  %18P %6D %5c %8t %N" 2>&1 | head -6
}
case "${1:-status}" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    env) echo "export SLURM_CONF='$CONF'" ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
