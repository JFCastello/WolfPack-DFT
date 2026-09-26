#!/usr/bin/env python3
"""backfill_study.py  (on PATH as: backfill-study)

How long a job waits in this cluster's queue, from what the queue has done to
jobs shaped like it, and where you stand in its priority order today (your
fairshare: scontrol show config, sshare, sprio). Nothing else: it estimates
no run time.

    cd <calc folder>        # reads the job from slurm_vasptest.sh (or slurm.sh)
    backfill-study          # its predicted wait (its column, narrowed to the
                            # jobs of users with a fairshare like yours), the
                            # quartiles of the waits at each walltime, and
                            # your fairshare now

    backfill-study --partition main --nodes 1 --cpus 40 --mem-mb 80000 --time 2-00:00:00

    backfill-study --job 12345678   # a job already submitted, pending or not:
                                    # its shape from sacct, and how long it has
                                    # waited against the prediction

Standard library only, Python 3.6+: it runs on a login node, where nothing
beyond python3 can be assumed.

It does not simulate the scheduler. It measures what the scheduler actually
did -- backfill included -- to jobs like yours, at each walltime they asked for.

==============================================================================
THE QUESTION
==============================================================================
Backfill fits a pending job into a gap only if its REQUESTED walltime fits
the gap, so the walltime a job asks for changes how long it waits. By how much
is a property of one cluster, one partition and one job shape, so it is
measured rather than assumed.

==============================================================================
WHAT IS MEASURED
==============================================================================
Every job the accounting database will show for the partition over the last N
days that actually STARTED. For each:

    wait  = Start - Eligible        (Eligible when it is known, else Submit)

Eligible rather than Submit because a job held by a dependency or a begin
time was not waiting on the queue; counting that as queue wait would blame
the partition for someone's job graph.

Jobs are then compared with YOURS on four axes -- the ones SLURM's scheduler
actually sees:

    nodes        the same band (1, 2-4, 5-16, 17+)
    cores        within a factor of 2
    memory       total requested memory within a factor of 3
    walltime     in broad bands (up to 1 h, 1 to 4 h, ... more than 7 days)

The comparison is progressive. It starts from jobs similar on nodes, cores
AND memory, and relaxes one axis at a time -- dropping memory, then cores,
then nodes -- until some walltime band has enough jobs. The report says which
level it used. Walltime is never relaxed: it is the axis being compared.

==============================================================================
WHEN IT CANNOT ANSWER
==============================================================================
No sacct, no accounting database, or fewer than 8 comparable jobs at a
walltime: the report says so rather than draw a wait from three jobs, which
would look like evidence.
"""
import argparse
import datetime as _dt
import json
import math
import os
import re
import subprocess
import sys
from typing import Dict, List, Optional, Sequence, Tuple

MIN_JOBS = 8                 # below this a bin's median is anecdote, not data

SACCT_FIELDS = ("JobID,Partition,Submit,Eligible,Start,State,Timelimit,"
                "TimelimitRaw,NNodes,NCPUS,ReqTRES,ReqMem,User,Account")

LEVELS = (
    ("nodes + cores + memory", True, True, True),
    ("nodes + cores", True, True, False),
    ("nodes", True, False, False),
    ("whole partition", False, False, False),
)


# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #
def parse_time(s: str) -> Optional[_dt.datetime]:
    """SLURM ISO time -> datetime, or None for Unknown/None/empty."""
    s = (s or "").strip()
    if not s or s in ("Unknown", "None", "N/A", "0"):
        return None
    # strptime, not fromisoformat: the latter is Python 3.7+, and login nodes
    # still ship 3.6.
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f"):
        try:
            return _dt.datetime.strptime(s, fmt)
        except ValueError:
            pass
    return None


def parse_timelimit_min(raw: str, text: str) -> Optional[float]:
    """Requested walltime in minutes. TimelimitRaw is already minutes; the
    formatted Timelimit is the fallback for SLURM builds without it."""
    raw = (raw or "").strip()
    if raw.isdigit():
        return float(raw)
    t = (text or "").strip()
    if not t or t in ("UNLIMITED", "Partition_Limit", "INVALID", "NONE"):
        return None
    days = 0
    if "-" in t:
        d, t = t.split("-", 1)
        if not d.isdigit():
            return None
        days = int(d)
    parts = t.split(":")
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return None
    if len(nums) == 3:
        h, m, s = nums
    elif len(nums) == 2:
        h, m, s = 0, nums[0], nums[1]
    elif len(nums) == 1:
        h, m, s = 0, nums[0], 0
    else:
        return None
    return days * 1440 + h * 60 + m + s / 60.0


_UNIT_MB = {"K": 1.0 / 1024, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024}


def _mem_token_mb(tok: str) -> Optional[float]:
    tok = tok.strip()
    if not tok:
        return None
    unit = tok[-1].upper()
    if unit in _UNIT_MB:
        num = tok[:-1]
    else:
        unit, num = "M", tok
    try:
        return float(num) * _UNIT_MB[unit]
    except ValueError:
        return None


def parse_mem_mb(reqtres: str, reqmem: str, ncpus: int, nnodes: int) -> Optional[float]:
    """TOTAL requested memory of the job, in MB.

    ReqTRES first: its mem= entry is always the job total, with no suffix
    games. ReqMem is the fallback, and it has been spelled three ways across
    SLURM versions -- 4000Mc (per CPU), 4000Mn (per node), and a bare 4000M
    for the job total -- which is exactly the trap vasp-slurm-report's test
    guards (reading one as another is an NCPUS-fold error)."""
    for item in (reqtres or "").split(","):
        if item.startswith("mem="):
            v = _mem_token_mb(item[4:])
            if v is not None and v > 0:
                return v
    rm = (reqmem or "").strip()
    if not rm or rm == "0":
        return None
    per = ""
    if rm[-1] in "cn":
        per, rm = rm[-1], rm[:-1]
    v = _mem_token_mb(rm)
    if v is None or v <= 0:
        return None
    if per == "c":
        return v * max(1, ncpus)
    if per == "n":
        return v * max(1, nnodes)
    return v


class Job:
    __slots__ = ("wait_s", "limit_min", "nodes", "cpus", "mem_mb", "user", "account")

    def __init__(self, wait_s, limit_min, nodes, cpus, mem_mb, user="", account=""):
        self.wait_s = wait_s
        self.limit_min = limit_min
        self.nodes = nodes
        self.cpus = cpus
        self.mem_mb = mem_mb
        self.user = user
        self.account = account


def load_jobs(lines: Sequence[str]) -> List[Job]:
    """Parse sacct -P -n output (SACCT_FIELDS order) into started jobs."""
    out: List[Job] = []
    for ln in lines:
        f = ln.rstrip("\n").split("|")
        if len(f) < 12:
            continue
        _jid, _part, sub, eli, sta, _state, tl, tlraw, nn, nc, tres, rmem = f[:12]
        t_sub, t_eli, t_sta = parse_time(sub), parse_time(eli), parse_time(sta)
        if t_sta is None:
            continue                       # never started: no wait to measure
        t0 = t_eli if (t_eli is not None and (t_sub is None or t_eli >= t_sub)) else t_sub
        if t0 is None:
            continue
        wait = (t_sta - t0).total_seconds()
        if wait < 0:
            continue
        limit = parse_timelimit_min(tlraw, tl)
        if limit is None or limit <= 0:
            continue
        try:
            nodes = max(1, int(nn or 1))
            cpus = max(1, int(nc or 1))
        except ValueError:
            continue
        user, acct = (f[12].strip(), f[13].strip()) if len(f) >= 14 else ("", "")
        out.append(Job(wait, limit, nodes, cpus, parse_mem_mb(tres, rmem, cpus, nodes),
                       user, acct))
    return out


def run_sacct(partition: str, days: int, all_users: bool = True,
              timeout: int = 90) -> Tuple[List[str], str]:
    """(lines, error). An error string means 'no data', never an exception."""
    cmd = ["sacct", "-X", "-P", "-n", "-S", f"now-{int(days)}days",
           "-o", SACCT_FIELDS]
    if all_users:
        cmd.insert(1, "-a")
    if partition:
        cmd += ["-r", partition]
    try:
        # stdout/stderr/universal_newlines rather than capture_output/text,
        # which are Python 3.7+.
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout)
    except FileNotFoundError:
        return [], "sacct is not on PATH"
    except subprocess.TimeoutExpired:
        return [], f"sacct did not answer within {timeout}s"
    lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
    if p.returncode != 0 and not lines:
        err = (p.stderr or "").strip().splitlines()
        return [], ("sacct failed: " + err[-1]) if err else "sacct failed"
    return lines, ""


# --------------------------------------------------------------------------- #
# Similarity
# --------------------------------------------------------------------------- #
def node_band(n: int) -> str:
    if n <= 1:
        return "1"
    if n <= 4:
        return "2-4"
    if n <= 16:
        return "5-16"
    return "17+"


def is_similar(j: Job, nodes: int, cpus: int, mem_mb: float,
               use_nodes: bool, use_cpus: bool, use_mem: bool) -> bool:
    if use_nodes and node_band(j.nodes) != node_band(nodes):
        return False
    if use_cpus and not (cpus / 2.0 <= j.cpus <= cpus * 2.0):
        return False
    if use_mem:
        if j.mem_mb is None or mem_mb <= 0:
            return False
        if not (mem_mb / 3.0 <= j.mem_mb <= mem_mb * 3.0):
            return False
    return True


def median(xs: Sequence[float]) -> float:
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return float("nan")
    mid = n // 2
    return s[mid] if n % 2 else 0.5 * (s[mid - 1] + s[mid])


def percentile(xs: Sequence[float], q: float) -> float:
    s = sorted(xs)
    if not s:
        return float("nan")
    k = (len(s) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return s[lo] if lo == hi else s[lo] + (s[hi] - s[lo]) * (k - lo)


# --------------------------------------------------------------------------- #
# The job, from a calculation folder or the command line
# --------------------------------------------------------------------------- #
DEF_DAYS = 30                # WP_CHAIN_QUEUE_DAYS
JOB_SCRIPTS = ("slurm_vasptest.sh", "slurm.sh")   # the one to submit, in that order
CORE = ("partition", "nodes", "cpus", "mem_mb")
OPTION_OF = {"partition": "--partition", "nodes": "--nodes", "cpus": "--cpus",
             "mem_mb": "--mem-mb", "wall_min": "--time"}
USAGE_BY_HAND = ("backfill-study --partition P --nodes N --cpus RANKS --mem-mb TOTAL_MB "
                 "--time D-HH:MM:SS")


def read_kv(path: str) -> Dict[str, str]:
    """KEY="value" lines, as the profile is written."""
    out: Dict[str, str] = {}
    try:
        with open(path) as fh:
            for ln in fh:
                m = re.match(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$', ln)
                if not m:
                    continue
                v = m.group(2).strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                else:
                    v = re.split(r"\s+#", v, 1)[0].strip()
                out[m.group(1)] = v
    except OSError:
        pass
    return out


def sbatch_value(text: str, opt: str) -> Optional[str]:
    """First --opt=VALUE in the job script."""
    m = re.search(r"--%s=(\S+)" % re.escape(opt), text, re.IGNORECASE)
    return m.group(1) if m else None


def _whole(v, default: int = 0) -> int:
    """Keep the digits of an integer field, as the shell tools' int() does."""
    d = re.sub(r"[^0-9-]", "", str(v or ""))
    try:
        return int(d)
    except ValueError:
        return default


def partition_maxtime(partition: str) -> Tuple[Optional[float], str]:
    """(MaxTime in minutes or None, "set" | "unlimited" | "unknown").
    "unknown" is scontrol not answering, which is not the same as no limit:
    a limit can also live in a QOS, where scontrol does not show it."""
    try:
        p = subprocess.run(["scontrol", "show", "partition", partition],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None, "unknown"
    m = re.search(r"MaxTime=(\S+)", p.stdout or "")
    if not m:
        return None, "unknown"
    if m.group(1) in ("UNLIMITED", "INFINITE", "NONE"):
        return None, "unlimited"
    v = parse_timelimit_min("", m.group(1))
    return (v, "set") if v and v > 0 else (None, "unknown")


def profile_settings() -> Dict:
    """What the cluster profile says: the partition, and how many days of
    history to read. A key the profile sets wins over the environment."""
    conf_path = os.environ.get("WOLFPACK_CLUSTER_CONF") or \
        os.path.expanduser("~/.config/wolfpack-dft/cluster.conf")
    conf = read_kv(conf_path)

    def setting(key):
        v = conf.get(key)
        return v if v not in (None, "") else os.environ.get(key) or None
    val: Dict = {}
    if setting("WP_MAIN_PARTITION"):
        val["partition"] = setting("WP_MAIN_PARTITION")
        val["partition_from"] = "the profile"
    days = setting("WP_CHAIN_QUEUE_DAYS")
    val["days"] = _whole(days, DEF_DAYS) or DEF_DAYS
    return val


def is_calc_folder(folder: str) -> bool:
    return any(os.path.exists(os.path.join(folder, f))
               for f in ("INCAR", ".wolfpack") + JOB_SCRIPTS)


def parse_walltime_arg(v: str) -> Optional[float]:
    """--time as minutes ("90") or as SLURM writes it ("5-06:00:00")."""
    v = (v or "").strip()
    if v.isdigit():
        return float(v)
    return parse_timelimit_min("", v)


def fmt_walltime(minutes: float) -> str:
    """A walltime for sentences: 7 days, 8 h, 90 min."""
    m = int(math.ceil(minutes))
    if m % 1440 == 0:
        return f"{m // 1440} day" + ("" if m == 1440 else "s")
    if m % 60 == 0:
        return f"{m // 60} h"
    return fmt_slurm_time(m) if m > 90 else f"{m} min"


def fmt_slurm_time(minutes: float) -> str:
    m = int(math.ceil(minutes))
    d, m = divmod(m, 1440)
    h, m = divmod(m, 60)
    return (f"{d}-" if d else "") + f"{h:02d}:{m:02d}:00"


def from_folder(folder: str) -> Tuple[Dict, List[str]]:
    """The job as written in the folder's job script: its shape and walltime."""
    val = profile_settings()
    notes: List[str] = []
    script = next((f for f in JOB_SCRIPTS if os.path.isfile(os.path.join(folder, f))), None)
    if not script:
        notes.append("no slurm_vasptest.sh or slurm.sh here: give --nodes --cpus --mem-mb --time")
        return val, notes
    job = open(os.path.join(folder, script)).read()
    val["script"] = script
    ranks = _whole(sbatch_value(job, "ntasks"))
    memcpu = _whole(sbatch_value(job, "mem-per-cpu"))
    if ranks > 0 and memcpu > 0:
        val["cpus"] = ranks
        val["nodes"] = _whole(sbatch_value(job, "nodes"), 1) or 1
        val["mem_mb"] = float(memcpu * ranks)
    else:
        notes.append(f"{script} has no --ntasks or no --mem-per-cpu")
    part = sbatch_value(job, "partition")
    if part:
        val["partition"], val["partition_from"] = part, script
    m = re.search(r"^#SBATCH\s+(?:--account=|-A\s*)(\S+)", job, re.MULTILINE)
    if m:
        val["account"] = m.group(1)
    tw = parse_walltime_arg(sbatch_value(job, "time") or "")
    if tw:
        val["wall_min"] = tw
    return val, notes


JOB_ID = re.compile(r"^\d+(_\d+)?$")        # a job, or one task of an array


def from_job(jid: str, timeout: int = 30) -> Tuple[Dict, List[str], Optional[Dict]]:
    """The job as SLURM recorded it: (its shape, notes, its wait so far).

    sacct -j knows pending, running and finished jobs alike, and with --jobs
    and no --state its window starts at Epoch 0 (sacct(1), DEFAULT TIME
    WINDOW), so the job's age does not matter. The shape is read with the same
    fields and the same parsing as the history it is compared with.
    Returns an empty shape, with the reason in the notes, when sacct does not
    know the job."""
    val = profile_settings()
    try:
        p = subprocess.run(["sacct", "-X", "-P", "-n", "-j", jid, "-o", SACCT_FIELDS],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout)
    except FileNotFoundError:
        return {}, ["sacct is not on PATH"], None
    except subprocess.TimeoutExpired:
        return {}, [f"sacct did not answer within {timeout}s"], None
    rec = next((ln.split("|") for ln in (p.stdout or "").splitlines()
                if ln.split("|")[0] == jid and len(ln.split("|")) >= 12), None)
    if rec is None:
        err = (p.stderr or "").strip().splitlines()
        return {}, [f"sacct -j {jid} shows no such job" + (f" ({err[-1]})" if err else "")], None
    _jid, part, sub, eli, sta, state, tl, tlraw, nn, nc, tres, rmem = rec[:12]
    notes: List[str] = []
    val["script"] = f"job {jid}, {state.split()[0] if state else '?'}"
    if part:
        # A job submitted to several partitions lists them all until it starts.
        parts = part.split(",")
        val["partition"], val["partition_from"] = parts[0], f"job {jid}"
        if len(parts) > 1:
            notes.append(f"job {jid} was submitted to {part}; the study uses {parts[0]}")
    nodes, cpus = _whole(nn, 1) or 1, _whole(nc)
    if cpus > 0:
        val["nodes"], val["cpus"] = nodes, cpus
        mem = parse_mem_mb(tres, rmem, cpus, nodes)
        if mem:
            val["mem_mb"] = mem
    limit = parse_timelimit_min(tlraw, tl)
    if limit and limit > 0:
        val["wall_min"] = limit
    if len(rec) >= 14:
        if rec[13].strip():
            val["account"] = rec[13].strip()
        if rec[12].strip():
            val["job_user"] = rec[12].strip()
    # Its own wait, counted as the history's are: from Eligible, else Submit.
    wait = None
    t_sub, t_eli, t_sta = parse_time(sub), parse_time(eli), parse_time(sta)
    t0 = t_eli if (t_eli is not None and (t_sub is None or t_eli >= t_sub)) else t_sub
    if t0 is not None:
        pending = t_sta is None
        end = _dt.datetime.now() if pending else t_sta
        wait = {"jid": jid, "wait_s": max((end - t0).total_seconds(), 0.0),
                "pending": pending, "state": state.split()[0] if state else "?",
                "limit_min": limit, "given": True}
    return val, notes, wait


def folder_job_ids(folder: str) -> List[str]:
    """Jobs that ran in the folder itself: SLURM logs <name>-<jobid>.out."""
    ids = set()
    try:
        for f in os.listdir(folder):
            m = re.match(r"^.+-(\d+)\.(out|err)$", f)
            if m and os.path.isfile(os.path.join(folder, f)):
                ids.add(m.group(1))
    except OSError:
        pass
    return sorted(ids, key=int)


def folder_job_waits(folder: str, limit: int = 3) -> List[Dict]:
    """How long the jobs already run from this folder waited, from sacct."""
    ids = folder_job_ids(folder)[-limit:]
    if not ids:
        return []
    try:
        p = subprocess.run(["sacct", "-X", "-n", "-P", "-j", ",".join(ids), "-o",
                            "JobID,Submit,Eligible,Start,State,TimelimitRaw,Timelimit"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return []
    out = []
    now = _dt.datetime.now()
    for ln in (p.stdout or "").splitlines():
        f = ln.split("|")
        if len(f) < 7 or not f[0].isdigit():
            continue
        sub, eli, sta = parse_time(f[1]), parse_time(f[2]), parse_time(f[3])
        t0 = eli if (eli is not None and (sub is None or eli >= sub)) else sub
        if t0 is None:
            continue
        pending = sta is None
        wait = ((now if pending else sta) - t0).total_seconds()
        out.append({"jid": f[0], "wait_s": max(wait, 0.0), "pending": pending,
                    "state": f[4].split()[0] if f[4] else "?",
                    "limit_min": parse_timelimit_min(f[5], f[6])})
    return out


# --------------------------------------------------------------------------- #
# Presentation
# --------------------------------------------------------------------------- #
def fmt_h(s: Optional[float]) -> str:
    """A duration for people: 40 s, 36 min, 5.2 h, 4.6 days."""
    if s is None or (isinstance(s, float) and math.isnan(s)):
        return "?"
    s = float(s)
    if s < 90:
        return f"{s:.0f} s"
    if s < 90 * 60:
        return f"{s / 60:.0f} min"
    if s < 48 * 3600:
        return f"{s / 3600:.1f} h"
    return f"{s / 86400:.1f} days"


def fmt_cell(s: Optional[float]) -> str:
    """fmt_h, short enough for a table cell: 40 s, 36 min, 5.2 h, 4.6 d."""
    t = fmt_h(s)
    return t[:-5] + " d" if t.endswith(" days") else t


# Broad walltime bands for the table people read. Fine bins spread a month of
# history thin, one noisy row at a time; a few wide bands keep enough jobs in
# each to mean something. (lo, hi, words for sentences, a table heading)
BANDS = ((0, 60, "up to 1 h", "0-1 h"), (60, 240, "1 to 4 h", "1-4 h"),
         (240, 720, "4 to 12 h", "4-12 h"), (720, 1440, "12 h to 1 day", "12-24 h"),
         (1440, 2880, "1 to 2 days", "1-2 d"), (2880, 5760, "2 to 4 days", "2-4 d"),
         (5760, 10080, "4 to 7 days", "4-7 d"), (10080, float("inf"), "more than 7 days", "> 7 d"))
# The table's rows: the quartiles of the wait.
QUARTILES = (("Q1  (25 % within)", "p25_s"), ("Q2  (50 % within)", "median_s"),
             ("Q3  (75 % within)", "p75_s"))
LEVEL_WORDS = {"nodes + cores + memory": "your size",
               "nodes + cores": "your node and core count",
               "nodes": "your node count",
               "whole partition": "any size"}


def band_of(limit_min: float) -> Optional[Tuple[float, float, str]]:
    for lo, hi, label, _short in BANDS:
        if lo < limit_min <= hi:
            return (lo, hi, label)
    return None


def band_table(jobs: Sequence[Job], nodes: int, cpus: int, mem_mb: float,
               min_jobs: int = MIN_JOBS) -> Tuple[Optional[str], List[Dict]]:
    """(level, rows): the waits by broad walltime band, all rows compared the
    SAME way -- the most specific level at which any band has min_jobs jobs.
    Bands with fewer jobs are left out."""
    for lname, un, uc, um in LEVELS:
        acc: Dict[str, List[float]] = {}
        for j in jobs:
            if not is_similar(j, nodes, cpus, mem_mb, un, uc, um):
                continue
            b = band_of(j.limit_min)
            if b:
                acc.setdefault(b[2], []).append(j.wait_s)
        rows = [{"label": label, "short": short, "lo": lo, "hi": hi, "n": len(acc[label]),
                 "p25_s": percentile(acc[label], 0.25), "median_s": median(acc[label]),
                 "p75_s": percentile(acc[label], 0.75)}
                for lo, hi, label, short in BANDS if len(acc.get(label, [])) >= min_jobs]
        if rows:
            return lname, rows
    return None, []


# The prediction: the table's column for your walltime, narrowed to the jobs
# whose owners' fairshare TODAY is closest to yours. Measured, not modelled:
# if fairshare orders this queue, those jobs waited the way yours will; if it
# does not, they are a sample of the same column and say the same thing.
# The owners' factors are today's; what they were when those jobs ran is not
# recorded anywhere sacct or sshare can show.
FS_WINDOWS = (0.05, 0.10, 0.20, 0.30)


def predict_wait(jobs: Sequence[Job], nodes: int, cpus: int, mem_mb: float,
                 level: Optional[str], wall_min: float, fs: Optional[Dict],
                 min_jobs: int = MIN_JOBS) -> Dict:
    """The quartiles of the fairshare neighbours' waits, with who they are;
    or {"why": ...} when fairshare cannot narrow the column."""
    if fs is None:
        return {"why": "--no-fairshare"}
    if fs.get("type") == "priority/basic":
        return {"why": "priority/basic starts jobs in submission order"}
    W = fs.get("weights")
    if W and W["fairshare"] == 0:
        return {"why": "it does not count here (PriorityWeightFairshare 0)"}
    row = fs.get("mine")
    if not row or row["factor"] is None:
        return {"why": fs.get("sshare_error") or "your factor is unknown"}
    mine, band = row["factor"], band_of(wall_min)
    lvl = next((x for x in LEVELS if x[0] == level), None)
    if band is None or lvl is None:
        return {"why": "no comparable jobs"}
    factors = fs.get("factors", {})
    cand = [(j, factors[(j.account, j.user)]) for j in jobs
            if band_of(j.limit_min) == band and (j.account, j.user) in factors
            and is_similar(j, nodes, cpus, mem_mb, *lvl[1:])]
    if not cand:
        return {"why": "none of those jobs' owners is visible in sshare"}
    for w in FS_WINDOWS:
        sel = [(j, f) for j, f in cand if abs(f - mine) <= w + 1e-9]
        if len(sel) >= min_jobs:
            ws = [j.wait_s for j, _ in sel]
            return {"n": len(sel), "users": len({j.user for j, _ in sel}), "window": w,
                    "own": sum(1 for j, _ in sel if j.user == fs.get("user")),
                    "f_lo": min(f for _, f in sel), "f_hi": max(f for _, f in sel),
                    "mine": mine, "p25_s": percentile(ws, 0.25), "median_s": median(ws),
                    "p75_s": percentile(ws, 0.75)}
    return {"why": f"fewer than {min_jobs} of them are by users within "
                   f"{FS_WINDOWS[-1]:.2f} of your fairshare ({mine:.3f})"}


def size_words(level: Optional[str], nodes: int, cpus: int, mem_mb: float) -> str:
    """What "similar" meant, in numbers."""
    parts = []
    if level in ("nodes + cores + memory", "nodes + cores", "nodes"):
        nb = node_band(nodes)
        parts.append("1 node" if nb == "1" else f"{nb} nodes")
    if level in ("nodes + cores + memory", "nodes + cores"):
        parts.append(f"{max(1, cpus // 2)}-{cpus * 2} cores")
    if level == "nodes + cores + memory":
        parts.append(f"{mem_mb / 3 / 1024:.0f}-{mem_mb * 3 / 1024:.0f} GB")
    return ", ".join(parts) if parts else "any size"


def queue_report(where: str, val: Dict, notes: List[str], level: Optional[str],
                 rows: List[Dict], past: List[Dict], maxtime: Tuple[Optional[float], str],
                 max_asked_min: Optional[float], days: int, n_jobs: int,
                 fairshare: Optional[Dict] = None, pred: Optional[Dict] = None) -> str:
    L: List[str] = []
    qref: Optional[Dict] = None
    part, nodes, cpus, mem = val["partition"], int(val["nodes"]), int(val["cpus"]), val["mem_mb"]
    mt, mt_state = maxtime
    wall = val.get("wall_min")
    mt_txt = {"set": fmt_walltime(mt) if mt else "?", "unlimited": "unlimited",
              "unknown": "not shown by scontrol"}[mt_state]
    L.append(f"backfill-study -- {os.path.basename(where) or where}")
    L.append(f"  partition   {part}   (MaxTime: {mt_txt})")
    L.append(f"  your job    {nodes} node{'' if nodes == 1 else 's'} x {cpus} cores, {mem / 1024:.0f} GB"
             + (f", --time={fmt_slurm_time(wall)}" if wall else "")
             + (f"   ({val['script']})" if val.get("script") else ""))
    L.append(f"  history     {n_jobs} jobs that started on {part} in the last {days} days")
    L.append("")

    # ---- the job as written, in sentences --------------------------------
    L.append("YOUR JOB")
    if not wall:
        L.append("  The job script has no --time: see the table for what each walltime waits.")
    elif mt_state == "set" and mt and wall > mt:
        L.append(f"  It asks for {fmt_walltime(wall)}, more than the partition's MaxTime of "
                 f"{fmt_walltime(mt)}: it will not start.")
    elif max_asked_min and wall > max_asked_min:
        L.append(f"  No job on {part} asked for more than {fmt_walltime(max_asked_min)} in the "
                 f"last {days} days; yours asks for {fmt_walltime(wall)}.")
        L.append(f"  If that is the partition's limit, this job will not start. Check:")
        L.append(f"      scontrol show partition {part} | grep -o 'MaxTime=[^ ]*'")
        L.append(f"      sacctmgr show qos format=name,maxwall")
    else:
        b = band_of(wall)
        row = next((r for r in rows if b and r["label"] == b[2]), None)
        if row:
            # The prediction: the column, narrowed by fairshare when it can be.
            near = pred if pred and pred.get("n") else None
            q = qref = near or row
            size = f"jobs of {LEVEL_WORDS.get(level, level)} that asked for {row['label']}"
            L.append(f"  Predicted wait: about {fmt_h(q['median_s'])}   (Q1 {fmt_h(q['p25_s'])}, "
                     f"Q3 {fmt_h(q['p75_s'])})")
            if near and near["own"] == near["n"]:
                L.append(f"  from {near['n']} of your own {size} (your fairshare today "
                         f"{near['mine']:.3f}).")
                L.append(f"  All {row['n']} such jobs, any user: about {fmt_h(row['median_s'])}.")
            elif near:
                who = f"{near['users']} user{'' if near['users'] == 1 else 's'}"
                if near["own"]:
                    who += ", you among them"
                span = (f"{near['f_lo']:.2f}" if near["f_lo"] == near["f_hi"]
                        else f"{near['f_lo']:.2f}-{near['f_hi']:.2f}")
                L.append(f"  from {near['n']} {size}, by {who}, whose fairshare")
                L.append(f"  today is {span} (yours {near['mine']:.3f}). All {row['n']} such jobs, "
                         f"any fairshare: about {fmt_h(row['median_s'])}.")
            else:
                why = (pred or {}).get("why", "")
                L.append(f"  from the {row['n']} {size}.")
                if why:
                    L.append(f"  Fairshare not used: {why}.")
        else:
            L.append(f"  Not enough jobs of {LEVEL_WORDS.get(level, 'your size')} asked for "
                     f"{b[2] if b else fmt_slurm_time(wall)} to estimate its wait "
                     f"(fewer than {MIN_JOBS}).")
    for pj in past:
        lim = f"asked for {fmt_walltime(pj['limit_min'])} and " if pj.get("limit_min") else ""
        who = f"Job {pj['jid']}" if pj.get("given") else f"Your job {pj['jid']} here"
        if pj["pending"]:
            L.append(f"  {who} {lim}has been waiting {fmt_h(pj['wait_s'])} so far.")
        else:
            L.append(f"  {who} {lim}waited {fmt_h(pj['wait_s'])}.")
        # Where that falls among the jobs it was compared with. Data, not a
        # verdict: a wait above Q3 is one a quarter of those jobs also had.
        if pj.get("given") and qref and not pj["pending"]:
            w = pj["wait_s"]
            where_ = ("below Q1: shorter than three quarters of them" if w < qref["p25_s"] else
                      "above Q3: longer than three quarters of them" if w > qref["p75_s"] else
                      "between Q1 and Q3, like half of them")
            L.append(f"  That is {where_}.")
    L.append("")

    # ---- the table ---------------------------------------------------------
    if rows:
        # The quartiles down, the walltimes across: one column per band.
        L.append(f"HOW LONG JOBS OF {LEVEL_WORDS.get(level, level).upper()} WAITED, "
                 f"BY THE WALLTIME THEY ASKED FOR")
        L.append(f"  {'walltime asked':<19}" + "".join(f"{r['short']:>9}" for r in rows))
        for name, key in QUARTILES:
            L.append(f"  {name:<19}" + "".join(f"{fmt_cell(r[key]):>9}" for r in rows))
        L.append(f"  {'jobs':<19}" + "".join(f"{r['n']:>9}" for r in rows))
        what = ("every job on the partition" if level == "whole partition"
                else f"jobs that asked for {size_words(level, nodes, cpus, mem)}")
        L.append(f"  {LEVEL_WORDS.get(level, level)} = {what} (yours: {cpus} cores, "
                 f"{mem / 1024:.0f} GB).")
        L.append("  Q1, Q2, Q3: a quarter, half and three quarters of them had started within that time.")
        L.append(f"  Walltimes with fewer than {MIN_JOBS} such jobs are not shown.")
    else:
        L.append(f"No walltime band has {MIN_JOBS}+ jobs comparable to yours in the last {days} days.")
    if fairshare is not None:
        L.append("")
        L.extend(fairshare_report(fairshare, part))
    for n in notes:
        L.append(f"  note: {n}")
    return "\n".join(L)


# --------------------------------------------------------------------------- #
# Fairshare, now
# --------------------------------------------------------------------------- #
# The waits above are what the queue did, over the past weeks, to everyone's
# jobs of your size. What orders the pending jobs TODAY is their priority, and
# your part of it is your fairshare. Data only, from three commands:
#
#   scontrol show config   the priority plugin, its weights, PriorityMaxAge,
#                          PriorityDecayHalfLife
#   sshare -a              each association's shares, usage and factor
#   sprio -p PARTITION     the pending jobs: priority and fairshare term
#
# SLURM's own definitions (priority_multifactor.html, fair_tree.html,
# classic_fair_share.html): priority = sum of weight x factor, every factor
# in [0, 1]. Under Fair Tree -- the default since 19.05 -- a user's factor is
# their rank over the number of user associations, 1.0 the top-ranked, and
# LevelFS = shares / usage among siblings. Under the classic algorithm
# (PriorityFlags=NO_FAIR_TREE) the factor is 2^(-usage/shares): 1.0 unused,
# 0.5 exactly one's share. The age factor grows from 0 to 1 over
# PriorityMaxAge of waiting.
SSHARE_FIELDS = "Account,User,RawShares,NormShares,RawUsage,EffectvUsage,FairShare,LevelFS"


def _run(cmd: Sequence[str], timeout: int = 30) -> Tuple[Optional[str], str]:
    """(stdout, error): None and the reason when the command cannot answer."""
    try:
        p = subprocess.run(list(cmd), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=timeout)
    except FileNotFoundError:
        return None, f"{cmd[0]} is not on PATH"
    except subprocess.TimeoutExpired:
        return None, f"{cmd[0]} did not answer within {timeout}s"
    except OSError as exc:
        return None, f"{cmd[0]}: {exc}"
    if p.returncode != 0 and not (p.stdout or "").strip():
        err = [ln.strip() for ln in (p.stderr or "").splitlines() if ln.strip()]
        return None, f"{cmd[0]} failed" + (f" ({err[-1]})" if err else "")
    return p.stdout or "", ""


def _num(v) -> Optional[float]:
    try:
        x = float(str(v).strip())
    except ValueError:
        return None
    return None if math.isnan(x) else x


def _me() -> str:
    u = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
    if not u:
        try:
            import getpass
            u = getpass.getuser()
        except Exception:
            pass
    return u


def priority_config() -> Tuple[Dict[str, str], str]:
    """scontrol show config's Priority* settings, keys lower-cased: scontrol
    prints PriorityWeightFairShare where slurm.conf spells ...Fairshare."""
    out, err = _run(["scontrol", "show", "config"])
    if out is None:
        return {}, err
    cfg: Dict[str, str] = {}
    for ln in out.splitlines():
        m = re.match(r"^\s*(Priority\w+)\s*=\s*(.*?)\s*$", ln)
        if m:
            cfg[m.group(1).lower()] = m.group(2)
    return cfg, ("" if cfg else "scontrol show config shows no Priority settings")


def sshare_rows() -> Tuple[List[Dict], str]:
    """Every association sshare shows: accounts (no user) and users."""
    out, err = _run(["sshare", "-a", "-P", "-n", "-o", SSHARE_FIELDS])
    if out is None:
        return [], err
    rows = []
    for ln in out.splitlines():
        f = ln.split("|")
        if len(f) < 8:
            continue
        rows.append({"account": f[0].strip(), "user": f[1].strip(),
                     "norm_shares": _num(f[3]), "eff_usage": _num(f[5]),
                     "factor": _num(f[6]), "level_fs": _num(f[7])})
    return rows, ("" if rows else "sshare shows no associations")


def sprio_rows(partition: str) -> Tuple[List[Dict], str]:
    """The partition's pending jobs: id, user, priority, fairshare term."""
    out, err = _run(["sprio", "-h", "-p", partition, "-o", "%i %u %Y %F"])
    if out is None:
        return [], err
    rows = []
    for ln in out.splitlines():
        f = ln.split()
        if len(f) < 4:
            continue
        pr, fs = _num(f[2]), _num(f[3])
        if pr is not None and fs is not None:
            rows.append({"jid": f[0], "user": f[1], "priority": pr, "fs": fs})
    return rows, ""


def default_account(user: str) -> Optional[str]:
    out, _ = _run(["sacctmgr", "-n", "-P", "show", "user", user, "format=DefaultAccount"])
    first = (out or "").strip().splitlines()
    return first[0].strip() if first and first[0].strip() else None


def fairshare_study(partition: str, account: Optional[str] = None,
                    user: Optional[str] = None) -> Dict:
    """Where the user stands now -- you, or the owner of the job being
    studied. Every piece is optional: what a command cannot tell is recorded
    as its reason, never guessed."""
    me = user or _me()
    fs: Dict = {"user": me, "notes": []}
    cfg, fs["config_error"] = priority_config()
    fs["type"] = cfg.get("prioritytype", "")
    if fs["type"] == "priority/basic":
        return fs
    if cfg:
        flags = cfg.get("priorityflags", "").upper()
        fs["algorithm"] = ("classic" if "NO_FAIR_TREE" in flags or "DEPTH_OBLIVIOUS" in flags
                           else "Fair Tree")
        fs["weights"] = {k: _num(cfg.get("priorityweight" + k, "0")) or 0.0
                         for k in ("fairshare", "age", "jobsize", "partition", "qos", "assoc")}
        fs["weight_tres"] = cfg.get("priorityweighttres", "")
        fs["max_age_min"] = parse_timelimit_min("", cfg.get("prioritymaxage", ""))
        fs["half_life_min"] = parse_timelimit_min("", cfg.get("prioritydecayhalflife", ""))
        fs["reset"] = cfg.get("priorityusageresetperiod", "")

    rows, fs["sshare_error"] = sshare_rows()
    fs["factors"] = {(r["account"], r["user"]): r["factor"] for r in rows
                     if r["user"] and r["factor"] is not None}
    mine = [r for r in rows if r["user"] == me]
    if rows and not mine:
        fs["sshare_error"] = f"sshare shows no association for {me or 'you'}"
    if mine:
        accts = [r["account"] for r in mine]
        pick = account if account in accts else None
        if account and not pick:
            fs["notes"].append(f"the job's account {account} is not one of yours in sshare")
        if pick is None and len(mine) > 1:
            d = default_account(me)
            pick = d if d in accts else None
            why = "your default" if pick else "the first sshare lists"
            pick = pick or accts[0]
            fs["notes"].append(f"you have {len(accts)} accounts ({', '.join(accts)}); "
                               f"this is {pick}, {why}: --account picks another")
        row = next((r for r in mine if r["account"] == pick), mine[0])
        fs["mine"] = row
        fs["account_row"] = next((r for r in rows if not r["user"]
                                  and r["account"] == row["account"]), None)
        users = [r for r in rows if r["user"]]
        fs["n_users"] = len(users)
        fs["others_visible"] = any(r["user"] != me for r in users)
        if row["factor"] is not None:
            fs["n_above"] = sum(1 for r in users
                                if r["factor"] is not None and r["factor"] > row["factor"])
            if cfg:
                fs["term"] = row["factor"] * fs["weights"]["fairshare"]

    if partition:
        fs["pending"], fs["sprio_error"] = sprio_rows(partition)
    return fs


def _pct(x: Optional[float]) -> str:
    if x is None:
        return "?"
    return "<0.1 %" if 0 < x < 0.001 else f"{100 * x:.1f} %"


def fairshare_report(fs: Dict, partition: str) -> List[str]:
    alg = fs.get("algorithm")
    L = ["FAIRSHARE NOW" + (f"   ({alg})" if alg else "")]
    if fs.get("type") == "priority/basic":
        L.append("  PriorityType=priority/basic: jobs start in the order they were submitted "
                 "(FIFO); there is no fairshare.")
        return L
    me, row, W = fs["user"] or "you", fs.get("mine"), fs.get("weights")
    if not row and not W:
        why = "; ".join(e for e in (fs.get("config_error"), fs.get("sshare_error")) if e)
        L.append(f"  not available here: {why or 'no answer'}.")
        return L
    pad = " " * 16

    # ---- your factor, and who is above it ----------------------------------
    if row and row["factor"] is not None:
        scale = {"Fair Tree": "1.000 is the top-ranked user",
                 "classic": "1.000 unused, 0.500 exactly your share"}.get(alg, "")
        L.append(f"  your factor   {row['factor']:.3f}   {me} in account {row['account']}"
                 + (f"; {scale}" if scale else ""))
        if fs.get("others_visible"):
            L.append(f"  above you     {fs['n_above']} of the {fs['n_users']} user associations "
                     f"(user + account) {'has' if fs['n_above'] == 1 else 'have'} a higher factor")
        else:
            L.append("  above you     not visible: sshare shows only your own associations")
        ar, share = fs.get("account_row"), []

        def known(r):
            return bool(r) and r["norm_shares"] is not None and r["eff_usage"] is not None
        if alg == "Fair Tree":
            # NormShares and EffectvUsage are among siblings here (sshare.html).
            if known(ar):
                share.append(f"account {ar['account']}: {_pct(ar['norm_shares'])} of the shares, "
                             f"{_pct(ar['eff_usage'])} of the use, among its sibling accounts")
            if known(row):
                share.append(f"{me}: {_pct(row['norm_shares'])} of the shares, "
                             f"{_pct(row['eff_usage'])} of the use, within {row['account']}")
        elif known(row):
            share.append(f"normalized shares {row['norm_shares']:.4f}, effective usage "
                         f"{row['eff_usage']:.4f}; factor = 2^(-usage/shares)")
        for i, s in enumerate(share):
            L.append(("  shares, use   " if i == 0 else pad) + s)
    elif fs.get("sshare_error"):
        L.append(f"  your factor   unknown: {fs['sshare_error']}")

    # ---- what it weighs ----------------------------------------------------
    if W:
        age = f"age {W['age']:.0f}"
        if fs.get("max_age_min"):
            age += f" (full after {fmt_walltime(fs['max_age_min'])})"
        parts = [f"fairshare {W['fairshare']:.0f}", age, f"job size {W['jobsize']:.0f}",
                 f"partition {W['partition']:.0f}", f"QOS {W['qos']:.0f}"]
        if W["assoc"]:
            parts.append(f"association {W['assoc']:.0f}")
        if fs.get("weight_tres") and fs["weight_tres"] != "(null)":
            parts.append(f"TRES {fs['weight_tres']}")
        L.append("  weights       " + ", ".join(parts))
        if W["fairshare"] == 0:
            L.append(f"{pad}PriorityWeightFairshare is 0: fairshare does not change priority here")
        elif fs.get("term") is not None:
            L.append(f"  worth         your factor adds {fs['term']:.0f} points to each of your "
                     f"jobs' priority")
            step = 0.1 * W["fairshare"]
            if W["age"] and fs.get("max_age_min"):
                per_day = W["age"] / (fs["max_age_min"] / 1440.0)
                days = step / per_day
                if days <= fs["max_age_min"] / 1440.0:
                    L.append(f"{pad}0.1 of factor = {step:.0f} points = what {days:.1f} days of "
                             f"waiting add (age)")
                else:
                    L.append(f"{pad}0.1 of factor = {step:.0f} points, more than waiting ever "
                             f"adds ({W['age']:.0f})")
            elif not W["age"]:
                L.append(f"{pad}waiting adds nothing: PriorityWeightAge is 0")
    elif fs.get("config_error"):
        L.append(f"  weights       unknown: {fs['config_error']}")

    # ---- the pending jobs, now ---------------------------------------------
    if partition and "pending" in fs:
        pend = fs["pending"]
        if fs.get("sprio_error"):
            L.append(f"  pending now   unknown: {fs['sprio_error']}")
        elif not pend:
            L.append(f"  pending now   no pending jobs on {partition}")
        else:
            others = [p for p in pend if p["user"] != me]
            if others:
                line = (f"  pending now   {len(pend)} jobs of {len({p['user'] for p in pend})} "
                        f"users on {partition}")
                if fs.get("term") is not None and W and W["fairshare"] > 0:
                    more = sum(1 for p in others if round(p["fs"]) > round(fs["term"]))
                    line += f"; {more} carry more fairshare points than yours"
                L.append(line)
            else:
                L.append(f"  pending now   sprio lists only your own jobs on {partition}")
            for p in sorted((p for p in pend if p["user"] == me),
                            key=lambda p: -p["priority"])[:3]:
                ahead = sum(1 for q in pend if q["priority"] > p["priority"])
                L.append(f"{pad}your job {p['jid']}: priority {p['priority']:.0f}, "
                         f"{ahead} pending job{'' if ahead == 1 else 's'} above it")

    # ---- how fast it changes -----------------------------------------------
    hl = fs.get("half_life_min")
    if hl:
        L.append(f"  decay         past use counts half after {fmt_walltime(hl)} "
                 f"(PriorityDecayHalfLife)")
    elif hl == 0:
        L.append(f"  decay         none (PriorityDecayHalfLife 0); usage reset: "
                 f"{fs.get('reset') or '?'}")
    for n in fs.get("notes", []):
        L.append(f"  note: {n}")
    return L


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        prog="backfill-study",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="How long a job waits in this queue: the job as written, and the "
                    "same job at other walltimes, from the partition's own accounting "
                    "history (sacct). Launches nothing.",
        epilog="In a calculation folder no option is needed: the job is read from "
               "slurm_vasptest.sh (or slurm.sh). Any option given wins over the folder.")
    p.add_argument("folder", nargs="?", default=".",
                   help="calculation folder (default: here)")
    p.add_argument("--partition")
    p.add_argument("--nodes", type=int)
    p.add_argument("--cpus", type=int, help="total cores (ranks) of the job")
    p.add_argument("--mem-mb", type=float, help="TOTAL requested memory, MB")
    p.add_argument("--time", dest="wall",
                   help="the walltime the job asks for: minutes, or D-HH:MM:SS")
    p.add_argument("--days", type=int, help="history to read (default 30)")
    p.add_argument("--account", help="the account for the fairshare (default: the job "
                   "script's, else yours)")
    p.add_argument("--no-fairshare", action="store_true",
                   help="leave out where you stand in the queue's priority now")
    p.add_argument("--mine", action="store_true", help="only your own jobs")
    p.add_argument("--json", default="", help="also write the analysis as JSON here")
    p.add_argument("--job", metavar="JOBID",
                   help="study this job: its partition, size, walltime and account as "
                        "sacct -j records them (pending, running or finished), and how "
                        "long it has waited. Options given win over it.")
    a = p.parse_args(argv)

    given = {"partition": a.partition, "nodes": a.nodes, "cpus": a.cpus, "mem_mb": a.mem_mb,
             "days": a.days, "account": a.account}
    if a.wall:
        tw = parse_walltime_arg(a.wall)
        if not tw:
            print(f"backfill-study: --time {a.wall!r}: give minutes or D-HH:MM:SS",
                  file=sys.stderr)
            return 2
        given["wall_min"] = tw
    notes: List[str] = []
    where = os.path.abspath(a.folder)
    job_wait: Optional[Dict] = None
    jid = (a.job or "").strip()
    if a.job is not None:
        if not JOB_ID.match(jid):
            print(f"backfill-study: --job {a.job!r}: a job id is digits (123456, or "
                  f"123456_7 for one task of an array)", file=sys.stderr)
            return 2
        val, notes, job_wait = from_job(jid)
        if not val:
            print(f"backfill-study: {notes[0]}", file=sys.stderr)
            return 2
        where = f"job {jid}"
    elif all(given[k] is not None for k in CORE):
        val = profile_settings()        # the job is given; the folder is not read
    else:
        if not os.path.isdir(where):
            print(f"backfill-study: no such folder: {where}", file=sys.stderr)
            return 2
        if is_calc_folder(where):
            val, notes = from_folder(where)
        else:
            val = profile_settings()
            lacking = [OPTION_OF[k] for k in CORE if given[k] is None and k not in val]
            if lacking:
                # One cause, one message.
                print(f"backfill-study: {where} is not a calculation folder "
                      f"(no INCAR, no job script, no .wolfpack/).\n"
                      f"  cd into one, or give the job yourself:\n"
                      f"    {USAGE_BY_HAND}\n"
                      f"  still missing: {' '.join(lacking)}", file=sys.stderr)
                return 2
    for k, v in given.items():
        if v is not None:
            val[k] = v
    missing = [k for k in CORE if val.get(k) in (None, 0, 0.0, "")]
    if missing:
        for n in notes:
            print(f"backfill-study: {n}", file=sys.stderr)
        print("backfill-study: cannot estimate a wait without: "
              + " ".join(OPTION_OF[k] for k in missing), file=sys.stderr)
        return 2

    maxtime = partition_maxtime(val["partition"])
    days = int(val["days"])
    lines, err = run_sacct(val["partition"], days, all_users=not a.mine)
    if jid:
        # The job is left out of the history it is compared with.
        lines = [ln for ln in lines if ln.split("|", 1)[0] != jid]
    jobs = load_jobs(lines)
    nodes, cpus, mem = int(val["nodes"]), int(val["cpus"]), float(val["mem_mb"])

    level, rows = band_table(jobs, nodes, cpus, mem)
    # The longest walltime ANY job on the partition asked for: past it, the
    # history has nothing to say, and a limit may be why.
    max_asked = max((j.limit_min for j in jobs), default=None)
    if jid:
        past = [job_wait] if job_wait else []
    else:
        past = folder_job_waits(where) if is_calc_folder(where) else []
    if err:
        notes.insert(0, err)
    owner = val.get("job_user") or ""
    if owner and owner != _me():
        notes.append(f"job {jid} is {owner}'s: the fairshare and the prediction are for {owner}")
    fsh = None if a.no_fairshare else fairshare_study(val["partition"], val.get("account"),
                                                     owner or None)
    pred = (predict_wait(jobs, nodes, cpus, mem, level, val["wall_min"], fsh)
            if val.get("wall_min") and level else None)
    print(queue_report(where, val, notes, level, rows, past, maxtime, max_asked, days, len(jobs),
                       fsh, pred))
    if a.json:
        with open(a.json, "w") as fh:
            json.dump({"inputs": val, "maxtime": maxtime, "level": level, "bands": rows,
                       "max_asked_min": max_asked, "sacct_error": err, "prediction": pred,
                       "fairshare": {k: v for k, v in (fsh or {}).items() if k != "factors"}},
                      fh, indent=1, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
