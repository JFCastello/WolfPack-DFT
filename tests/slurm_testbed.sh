#!/usr/bin/env bash
# A SLURM shaped like the target cluster, on this laptop.
#
#   tests/slurm_testbed.sh start | stop | status | restart
#
# WHY IT LIVES IN /tmp AND NOT IN THE SUITE
# The previous testbed put its StateSaveLocation inside the suite's own work
# directory. Deleting the suite therefore killed the scheduler -- sinfo kept
# answering (the controller was still up) while every sbatch died with
# "I/O error writing script/environment to file", which looks like a SLURM
# problem and is not. The scheduler must survive `rm -rf` of the tests.
#
# WHAT IT PROVIDES
#   sequana_cpu / sequana_cpu_dev : 5 x 48-core nodes, CONFIG ONLY. They exist
#       so a multi-node layout can be submitted and judged by a real
#       slurmctld. Nothing runs on them.
#   local  : the one real node, for jobs that must actually compute.
#   small  : two 4-core nodes on the same box via multiple-slurmd, so a
#       recommendation has more than one rank count to choose between AND the
#       chosen one can still run.
set -uo pipefail
ROOT="${WP_TESTBED_ROOT:-/tmp/wpslurm}"
CONF="$ROOT/slurm.conf"
HOSTN="$(hostname -s)"
LOG="$ROOT/log"
export SLURM_CONF="$CONF"

_up(){ pgrep -f "$1" >/dev/null 2>&1; }
_mysql_up(){ pgrep -f "mariadbd .*$ROOT/mysql" >/dev/null 2>&1; }

render(){
    mkdir -p "$ROOT"/{state,spool,log,dbd} "$ROOT"/spool/{$HOSTN,wpsmall01,wpsmall02}
    cat > "$CONF" <<EOF
ClusterName=wolfpacktest
SlurmctldHost=$HOSTN
AuthType=auth/none
# With auth/none the credential plugin must be told too, or srun dies with
# "Error generating job credential": the BATCH step runs, the VASP step is
# cancelled, and the job still reports COMPLETED.
CredType=cred/none
SlurmUser=$USER
# slurmd refuses to run as anyone but root unless told so explicitly.
SlurmdUser=$USER
SlurmctldPort=6817
SlurmdPort=6818
StateSaveLocation=$ROOT/state
SlurmdSpoolDir=$ROOT/spool/%n
SlurmctldLogFile=$ROOT/log/slurmctld.log
SlurmdLogFile=$ROOT/log/slurmd-%n.log
SlurmctldPidFile=$ROOT/slurmctld.pid
SlurmdPidFile=$ROOT/slurmd-%n.pid
ProctrackType=proctrack/pgid
TaskPlugin=task/none
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
ReturnToService=2
# WSL2 has no usable cgroup hierarchy for slurmd, so accounting gathers what it
# can from /proc. MaxRSS may come back 0; checks must treat that as "not
# measured" rather than as a measurement of zero.
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=1
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
AccountingStoragePort=6819
AccountingStorageTRES=cpu,mem,node
# No mail on a laptop; without this every job logs a MailProg failure.
MailProg=/bin/true
DebugFlags=NO_CONF_HASH

# Config-only nodes: a multi-node layout can be SUBMITTED and judged here.
NodeName=wpfake[01-05] NodeAddr=127.0.0.1 CPUs=48 RealMemory=384000 State=UNKNOWN
PartitionName=sequana_cpu     Nodes=wpfake[01-05] Default=YES MaxTime=INFINITE MaxNodes=5 State=UP
PartitionName=sequana_cpu_dev Nodes=wpfake[01-05] MaxTime=INFINITE MaxNodes=5 State=UP

# The one real node: where small jobs actually compute.
NodeName=$HOSTN CPUs=$(nproc) RealMemory=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 - 1000 )) State=UNKNOWN
PartitionName=local Nodes=$HOSTN MaxTime=INFINITE State=UP

# Two SMALL nodes, multiple-slurmd on this same box, each on its own port.
# A single-node cluster gives a one-row recommendation table, and "benchmark
# candidate 2" then has nothing to benchmark.
NodeName=wpsmall01 NodeHostname=$HOSTN NodeAddr=127.0.0.1 Port=17001 CPUs=4 RealMemory=3000 State=UNKNOWN
NodeName=wpsmall02 NodeHostname=$HOSTN NodeAddr=127.0.0.1 Port=17002 CPUs=4 RealMemory=3000 State=UNKNOWN
PartitionName=small Nodes=wpsmall[01-02] MaxTime=INFINITE MaxNodes=2 State=UP
EOF
    cat > "$ROOT/slurmdbd.conf" <<EOF
AuthType=auth/none
DbdHost=localhost
DbdPort=6819
SlurmUser=$USER
StorageType=accounting_storage/mysql
StorageHost=127.0.0.1
StoragePort=13306
StorageUser=slurm
StoragePass=slurmpw
StorageLoc=slurm_acct_db
LogFile=$ROOT/log/slurmdbd.log
PidFile=$ROOT/slurmdbd.pid
EOF
    chmod 600 "$ROOT/slurmdbd.conf"
    # WSL2 runs in a cgroup namespace whose /sys/fs/cgroup carries pids from
    # the host, so slurmd cannot claim a scope and refuses to START -- the
    # nodes then sit in "unk*" forever and every submission fails with
    # "Requested node configuration is not available", which looks like a
    # config error and is not. Nothing here needs cgroup accounting.
    printf '%s\n' \
        '# See the comment in slurm_testbed.sh: WSL2 cgroups are unusable by slurmd.' \
        'CgroupPlugin=disabled' > "$ROOT/cgroup.conf"
}

start(){
    render
    if ! _mysql_up; then
        [[ -d "$ROOT/mysql" ]] || mariadb-install-db --user="$USER" \
            --datadir="$ROOT/mysql" --auth-root-authentication-method=normal \
            >"$LOG/mysqlinit.log" 2>&1
        setsid mariadbd --datadir="$ROOT/mysql" --socket="$ROOT/mysql.sock" \
            --port=13306 --pid-file="$ROOT/mysql.pid" --bind-address=127.0.0.1 \
            >"$LOG/mysqld.out" 2>&1 </dev/null &
        sleep 6
        mariadb --socket="$ROOT/mysql.sock" -u root -e "
            CREATE DATABASE IF NOT EXISTS slurm_acct_db;
            CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY 'slurmpw';
            CREATE USER IF NOT EXISTS 'slurm'@'127.0.0.1' IDENTIFIED BY 'slurmpw';
            GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';
            GRANT ALL ON slurm_acct_db.* TO 'slurm'@'127.0.0.1';
            FLUSH PRIVILEGES;" >>"$LOG/mysqlinit.log" 2>&1 || true
    fi
    _up "slurmdbd -D"  || { setsid slurmdbd  -D >"$LOG/dbd.out"  2>&1 </dev/null & sleep 5; }
    _up "slurmctld -D" || { setsid slurmctld -D >"$LOG/ctld.out" 2>&1 </dev/null & sleep 5; }
    for n in "$HOSTN" wpsmall01 wpsmall02; do
        pgrep -f "slurmd -D -N $n" >/dev/null 2>&1 || {
            setsid slurmd -D -N "$n" >"$LOG/d-$n.out" 2>&1 </dev/null & sleep 3; }
    done
    scontrol update NodeName="wpfake[01-05]"  State=RESUME Reason=testbed >/dev/null 2>&1 || true
    scontrol update NodeName="wpsmall[01-02]" State=RESUME Reason=testbed >/dev/null 2>&1 || true
    scontrol update NodeName="$HOSTN"         State=RESUME Reason=testbed >/dev/null 2>&1 || true
    sleep 2; status
}

stop(){
    for d in slurmd slurmctld slurmdbd; do pkill -f "$d -D" 2>/dev/null || true; done
    pkill -f "mariadbd .*$ROOT/mysql" 2>/dev/null || true
    echo "testbed stopped"
}

status(){
    printf '  %-18s %s\n' "SLURM_CONF" "$CONF"
    if sinfo -h >/dev/null 2>&1; then
        sinfo -o "  %.18P %.5D %.5c %.8T %N" | tail -n +2
        # A controller that answers sinfo can still be unable to take a job if
        # its StateSaveLocation vanished. Check what actually matters.
        if sbatch --test-only -p local -n 1 -t 00:01:00 --wrap 'true' >/dev/null 2>&1; then
            printf '  %-18s %s\n' "submission" "ok"
        else
            printf '  %-18s %s\n' "submission" "BROKEN -- run: $0 restart"
        fi
    else
        printf '  %-18s %s\n' "slurmctld" "not reachable"
    fi
}

case "${1:-status}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 3; start ;;
    status)  status ;;
    *) echo "usage: $0 {start|stop|status|restart}" >&2; exit 2 ;;
esac
