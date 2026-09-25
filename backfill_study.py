#!/usr/bin/env python3
"""backfill_study.py  (on PATH as: backfill-study)

How long a job waits in this cluster's queue, from what the queue has done to
jobs shaped like it. Nothing else: it estimates no run time.

    cd <calc folder>        # reads the job from slurm_vasptest.sh (or slurm.sh)
    backfill-study          # its expected wait, and the waits at other walltimes

    backfill-study --partition main --nodes 1 --cpus 40 --mem-mb 80000 --time 2-00:00:00

vasp-relax-loop calls it at launch (--machine), with the ionic-step time IT
estimated from vasp-test's measurements, to choose its chunk walltime from
these same waits. That estimate is the chain's; it is not repeated here.

Standard library only, Python 3.6+: it runs on a login node, where nothing
beyond python3 can be assumed.

It does not simulate the scheduler. It measures what the scheduler actually
did -- backfill included -- to jobs like yours, at each walltime they asked for.

==============================================================================
THE QUESTION
==============================================================================
A chunked relaxation pays one queue wait PER CHUNK. A long chunk means fewer
waits, but a long walltime request can itself wait longer: backfill fits a
pending job into a gap only if its REQUESTED walltime fits the gap. Which of
the two wins is a property of one cluster, one partition and one job shape,
so it is measured rather than assumed.

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
    walltime     binned by the candidate chunk lengths

The comparison is progressive. It starts from jobs similar on nodes, cores
AND memory, and relaxes one axis at a time -- dropping memory, then cores,
then nodes -- until enough jobs remain to compare at least two walltimes. The
report says which level it used. Walltime is never relaxed: it is the axis
being decided.

==============================================================================
THE CHAIN'S DECISION (--machine, called by vasp-relax-loop)
==============================================================================
Given the chain's ionic-step time, for each candidate walltime W the chain's
own arithmetic is replayed:

  * chunk 1 is a CALIBRATION chunk: at most 3 ionic steps, sized with a 1.5x
    cold-start factor. If not even ONE ionic step fits, W is infeasible.
  * later chunks hold  floor(T_work / (t_ion x 1.15))  steps, but the cap may
    at most DOUBLE from one chunk to the next (the chain's governor), so a
    long walltime needs several chunks to ramp up.

The ionic steps still to do (NSW minus those done) are replayed through that
ramp to count chunks, and the expected time to finish is

    T(W) = chunks(W) x (median_wait(W) + startup)  +  steps x t_ion

The W with the smallest T(W) wins. The median, not the mean: queue waits have
a long tail, and a handful of multi-day waits would otherwise decide the
answer on their own.

NSW is YOUR ceiling on the relaxation, not a prediction of how long it will
take. Using it makes T(W) a worst case, which is the honest thing to compare
when the real number of steps is not known in advance.

==============================================================================
WHEN IT CANNOT ANSWER
==============================================================================
No sacct, no accounting database, or too few comparable jobs to tell two
walltimes apart: the study says so and the caller falls back to the chunk
walltime in the cluster profile. A decision drawn from three jobs is worse
than the default, because it looks like evidence.
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

# The chain's own constants. Kept in step with vasp_chain.sh by hand: they are
# three numbers, and a test (test_32_queue_study) checks the replayed chunk
# counts against the chain's rules.
CHAIN_SAFETY = 1.15          # SAFETY in vasp_chain.sh
CHAIN_COLD_FACTOR = 1.5      # the calibration chunk's extra margin
CHAIN_CAP1_MAX = 3           # calibration chunk: at most this many ionic steps
CHAIN_NELM_CEIL = 500        # NELM_CEIL: no cap exceeds this
CHAIN_MARGIN_FRAC = 0.08     # MARGIN = max(configured, 8 % of the walltime)

# Candidate chunk walltimes, in minutes. Round values, because that is what
# people ask for -- and therefore where the data is.
CANDIDATES_MIN = (30, 60, 120, 180, 240, 360, 480, 600, 720, 960,
                  1440, 2160, 2880, 4320, 5760, 7200, 10080)

MIN_JOBS = 8                 # below this a bin's median is anecdote, not data

SACCT_FIELDS = ("JobID,Partition,Submit,Eligible,Start,State,Timelimit,"
                "TimelimitRaw,NNodes,NCPUS,ReqTRES,ReqMem")

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
    __slots__ = ("wait_s", "limit_min", "nodes", "cpus", "mem_mb")

    def __init__(self, wait_s, limit_min, nodes, cpus, mem_mb):
        self.wait_s = wait_s
        self.limit_min = limit_min
        self.nodes = nodes
        self.cpus = cpus
        self.mem_mb = mem_mb


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
        out.append(Job(wait, limit, nodes, cpus, parse_mem_mb(tres, rmem, cpus, nodes)))
    return out


def run_sacct(partition: str, days: int, all_users: bool = True,
              timeout: int = 90) -> Tuple[List[str], str]:
    """(lines, error). An error string means 'no data', never an exception:
    the caller always has the profile's default to fall back on."""
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
# The chain, replayed
# --------------------------------------------------------------------------- #
def chunk_budget(wall_min: float, margin_cfg_min: float, startup_s: float) -> float:
    """T_work in seconds, exactly as vasp_chain.sh derives it."""
    margin = max(float(margin_cfg_min), int(wall_min * CHAIN_MARGIN_FRAC))
    return wall_min * 60.0 - margin * 60.0 - float(startup_s)


def replay_chunks(wall_min: float, t_ion_s: float, startup_s: float,
                  margin_cfg_min: float, steps: int) -> Tuple[bool, int, int]:
    """(feasible, steady_cap, chunks_needed) for one walltime.

    feasible   : chunk 1 fits at least one ionic step with the cold-start factor.
    steady_cap : ionic steps a warm chunk holds.
    chunks     : chunks to do `steps` ionic steps, through the doubling ramp.
    """
    t_work = chunk_budget(wall_min, margin_cfg_min, startup_s)
    if t_ion_s <= 0 or t_work <= 0:
        return False, 0, 0
    cap1 = int(t_work / (t_ion_s * CHAIN_COLD_FACTOR))
    if cap1 < 1:
        return False, 0, 0
    steady = min(int(t_work / (t_ion_s * CHAIN_SAFETY)), CHAIN_NELM_CEIL)
    steady = max(steady, 1)
    cap1 = min(cap1, CHAIN_CAP1_MAX, max(1, steps))
    done, chunks, prev = cap1, 1, cap1
    while done < steps:
        cap = min(steady, 2 * prev, steps - done)
        cap = max(cap, 1)
        done += cap
        chunks += 1
        prev = cap
        if chunks > 10000:          # cannot happen with cap >= 1; belt and braces
            break
    return True, steady, chunks


# --------------------------------------------------------------------------- #
# The study
# --------------------------------------------------------------------------- #
def candidates_for(max_time_min: Optional[float],
                   candidates: Sequence[float] = CANDIDATES_MIN) -> List[float]:
    """The walltimes worth comparing: the round ones up to MaxTime, and MaxTime."""
    cands = sorted({float(c) for c in candidates
                    if max_time_min is None or c <= max_time_min})
    if max_time_min is not None and max_time_min > 0 and max_time_min not in cands:
        cands.append(float(max_time_min))
        cands.sort()
    return cands


def bin_of(limit: float, cands: Sequence[float]) -> Optional[float]:
    """A request belongs to the smallest candidate walltime >= it."""
    for w in cands:
        if limit <= w + 1e-9:
            return w
    return None


def wait_estimate(jobs: Sequence[Job], nodes: int, cpus: int, mem_mb: float,
                  wall_min: float, cands: Sequence[float],
                  min_jobs: int = MIN_JOBS, widen: bool = True) -> Optional[Dict]:
    """The queue wait of a job this shape asking for wall_min, from the jobs
    that came closest. Tried in order, the first with min_jobs jobs wins:
    the same walltime range at each similarity level (nodes + cores + memory,
    then fewer axes); then half to twice the walltime, at each level. What was
    used is returned with the numbers, because the answer is only as good as
    the jobs behind it."""
    b = bin_of(wall_min, cands) if cands else None
    lo = max([c for c in cands if b is not None and c < b], default=0.0)
    windows = (
        ((lo, b), lambda j: b is not None and bin_of(j.limit_min, cands) == b),
        ((wall_min / 2.0, wall_min * 2.0),
         lambda j: wall_min / 2.0 <= j.limit_min <= wall_min * 2.0),
    )
    for wname, inside in (windows if widen else windows[:1]):
        for lname, un, uc, um in LEVELS:
            ws = [j.wait_s for j in jobs
                  if inside(j) and is_similar(j, nodes, cpus, mem_mb, un, uc, um)]
            if len(ws) >= min_jobs:
                return {"median_s": median(ws), "p75_s": percentile(ws, 0.75),
                        "p90_s": percentile(ws, 0.90), "n": len(ws),
                        "level": lname, "window": wname}   # window: (from, to] minutes
    return None


def study(jobs: Sequence[Job], *, nodes: int, cpus: int, mem_mb: float,
          t_ion_s: float, startup_s: float, margin_cfg_min: float,
          steps: int, max_time_min: Optional[float],
          default_wall_min: float, min_jobs: int = MIN_JOBS,
          candidates: Sequence[float] = CANDIDATES_MIN) -> Dict:
    """The whole analysis, as a plain dict (the CLI prints it; tests read it)."""
    cands = candidates_for(max_time_min, candidates)

    res: Dict = {
        "shape": {"nodes": nodes, "cpus": cpus, "mem_mb": mem_mb},
        "t_ion_s": t_ion_s, "startup_s": startup_s, "steps": steps,
        "max_time_min": max_time_min, "default_wall_min": default_wall_min,
        "n_jobs": len(jobs), "min_jobs": min_jobs,
        "level": None, "rows": [], "chosen_min": None,
        "source": "fallback", "reason": "",
        "feasible_any": False, "min_feasible_min": None,
    }

    # Feasibility does not depend on the queue at all: it is the chain's own
    # arithmetic. Establish it first, so "nothing fits" is reported as that
    # and not as "no queue data".
    feas = {}
    for w in cands:
        feas[w] = replay_chunks(w, t_ion_s, startup_s, margin_cfg_min, steps)
    feasible_ws = [w for w in cands if feas[w][0]]
    res["feasible_any"] = bool(feasible_ws)
    res["min_feasible_min"] = feasible_ws[0] if feasible_ws else None
    if not feasible_ws:
        res["reason"] = ("not one ionic step fits in a chunk at any walltime up to "
                         + (f"the partition's {max_time_min:.0f} min" if max_time_min
                            else "the longest candidate"))
        return res

    chosen_level = None
    level_bins: Dict[float, List[float]] = {}
    for name, un, uc, um in LEVELS:
        bins: Dict[float, List[float]] = {w: [] for w in cands}
        for j in jobs:
            if not is_similar(j, nodes, cpus, mem_mb, un, uc, um):
                continue
            b = bin_of(j.limit_min, cands)
            if b is not None:
                bins[b].append(j.wait_s)
        usable = [w for w in feasible_ws if len(bins[w]) >= min_jobs]
        if len(usable) >= 2:
            chosen_level, level_bins = name, bins
            break

    # The rows are reported even when the study cannot decide: the user can
    # still read what little there is.
    table_bins = level_bins
    if chosen_level is None:
        table_bins = {w: [] for w in cands}
        for j in jobs:
            b = bin_of(j.limit_min, cands)
            if b is not None:
                table_bins[b].append(j.wait_s)

    for w in cands:
        ok, steady, nchunks = feas[w]
        ws = table_bins.get(w, [])
        row = {"wall_min": w, "feasible": ok, "steady_cap": steady,
               "chunks": nchunks, "n": len(ws),
               "median_s": median(ws) if ws else None,
               "p75_s": percentile(ws, 0.75) if ws else None,
               "p90_s": percentile(ws, 0.90) if ws else None,
               "total_s": None, "usable": False}
        if ok and chosen_level is not None and len(ws) >= min_jobs:
            row["usable"] = True
            row["total_s"] = nchunks * (row["median_s"] + startup_s) + steps * t_ion_s
        res["rows"].append(row)

    if chosen_level is None:
        # No one level compares two walltimes. Take, walltime by walltime, the
        # closest jobs there are (wait_estimate) -- less comparable, and said
        # so, but an answer from data rather than none at all.
        for row in res["rows"]:
            if not row["feasible"]:
                continue
            est = wait_estimate(jobs, nodes, cpus, mem_mb, row["wall_min"], cands, min_jobs)
            if est is None:
                continue
            row.update(n=est["n"], median_s=est["median_s"], p75_s=est["p75_s"],
                       p90_s=est["p90_s"], usable=True, basis=est)
            row["total_s"] = row["chunks"] * (row["median_s"] + startup_s) + steps * t_ion_s
        if not any(r["usable"] for r in res["rows"]):
            res["reason"] = (f"fewer than two feasible walltimes have {min_jobs}+ comparable "
                             f"jobs, and no single one has {min_jobs} within half to twice its "
                             f"length ({len(jobs)} started jobs seen)")
            return res
        chosen_level = "best available per walltime"

    res["level"] = chosen_level
    usable_rows = [r for r in res["rows"] if r["usable"]]
    best = min(usable_rows, key=lambda r: (r["total_s"], r["wall_min"]))
    res["chosen_min"] = best["wall_min"]
    res["source"] = "study"
    res["reason"] = (f"smallest expected time to finish {steps} ionic step(s): "
                     f"{best['chunks']} chunk(s) x median wait "
                     f"{fmt_dur(best['median_s'])} (n={best['n']}, level: {chosen_level})")
    return res


# --------------------------------------------------------------------------- #
# The job, from a calculation folder or the command line
# --------------------------------------------------------------------------- #
DEF_WALLTIME_MIN = 600       # DEF_WALLTIME_MIN in vasp_chain.sh
DEF_MARGIN_MIN = 5           # DEF_MARGIN_MIN
DEF_STARTUP_S = 120
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
    """First --opt=VALUE in the job script, as vasp_chain.sh's sb_num/sb_str."""
    m = re.search(r"--%s=(\S+)" % re.escape(opt), text, re.IGNORECASE)
    return m.group(1) if m else None


def _whole(v, default: int = 0) -> int:
    """vasp_chain.sh's int(): keep the digits of an integer field."""
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


def partition_maxtime_min(partition: str) -> Optional[float]:
    """The partition's MaxTime in minutes; None when unlimited or unknown."""
    return partition_maxtime(partition)[0]


def profile_settings() -> Dict:
    """What the cluster profile says: the partition, and the chunk settings
    the chain's decision uses. The chain sources the profile over its
    environment, so a key the profile sets wins, one it does not comes from
    the environment."""
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
    mg, dw, days = (setting("WP_CHUNK_MARGIN_MIN"), setting("WP_CHUNK_WALLTIME_MIN"),
                    setting("WP_CHAIN_QUEUE_DAYS"))
    val["margin_min"] = float(_whole(mg)) if mg is not None else float(DEF_MARGIN_MIN)
    val["default_wall_min"] = float(_whole(dw)) if dw is not None else float(DEF_WALLTIME_MIN)
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
    tw = parse_walltime_arg(sbatch_value(job, "time") or "")
    if tw:
        val["wall_min"] = tw
    return val, notes


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
def fmt_dur(s: Optional[float]) -> str:
    if s is None or (isinstance(s, float) and math.isnan(s)):
        return "--"
    s = float(s)
    if s < 60:
        return f"{s:.0f}s"
    if s < 3600:
        return f"{s / 60:.1f}m"
    if s < 86400:
        return f"{s / 3600:.1f}h"
    return f"{s / 86400:.1f}d"


def fmt_wall(m: float) -> str:
    m = float(m)
    return f"{m / 60:.0f} h" if m >= 60 and m % 60 == 0 else f"{m:.0f} min"


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


# Broad walltime bands for the table people read. Fine bins spread a month of
# history thin, one noisy row at a time; a few wide bands keep enough jobs in
# each to mean something.
BANDS = ((0, 60, "up to 1 h"), (60, 240, "1 to 4 h"), (240, 720, "4 to 12 h"),
         (720, 1440, "12 h to 1 day"), (1440, 2880, "1 to 2 days"),
         (2880, 5760, "2 to 4 days"), (5760, 10080, "4 to 7 days"),
         (10080, float("inf"), "more than 7 days"))
LEVEL_WORDS = {"nodes + cores + memory": "your size",
               "nodes + cores": "your node and core count",
               "nodes": "your node count",
               "whole partition": "any size"}


def band_of(limit_min: float) -> Optional[Tuple[float, float, str]]:
    for lo, hi, label in BANDS:
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
        rows = [{"label": label, "lo": lo, "hi": hi, "n": len(acc[label]),
                 "median_s": median(acc[label]), "p90_s": percentile(acc[label], 0.90)}
                for lo, hi, label in BANDS if len(acc.get(label, [])) >= min_jobs]
        if rows:
            return lname, rows
    return None, []


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


def chain_report(res: Dict, partition: str = "", days: int = 0) -> str:
    """What vasp-relax-loop shows at launch: its chunk walltime, and why."""
    L: List[str] = []
    sh = res["shape"]
    L.append(f"  partition        : {partition or '?'}"
             + (f"   (MaxTime {fmt_wall(res['max_time_min'])})" if res["max_time_min"]
                else "   (MaxTime unlimited or unknown)"))
    L.append(f"  your job         : {sh['nodes']} node(s), {sh['cpus']} cores, "
             f"{sh['mem_mb'] / 1024:.0f} GB requested")
    L.append(f"  ionic step       : ~{res['t_ion_s']:.0f} s (the chain's estimate)   start-up "
             f"{res['startup_s']:.0f} s   steps to do {res['steps']} (NSW -- a ceiling)")
    L.append(f"  accounting data  : {res['n_jobs']} started job(s) over the last {days} day(s)")
    L.append(f"  similarity level : {res['level'] or '-- not enough data at any level --'}")
    L.append("")
    L.append("  walltime   fits?  steps/chunk  chunks   jobs   median    p75      p90     expected total")
    L.append("  " + "-" * 92)
    for r in res["rows"]:
        if not r["n"] and res["chosen_min"] != r["wall_min"]:
            continue            # a row with no jobs says nothing
        fits = "yes" if r["feasible"] else "NO"
        tot = fmt_dur(r["total_s"]) if r["total_s"] is not None else "--"
        mark = "  <" if res["chosen_min"] == r["wall_min"] else ""
        L.append(f"  {fmt_wall(r['wall_min']):>8}   {fits:>4}   {r['steady_cap'] or '--':>9}   "
                 f"{r['chunks'] or '--':>6}   {r['n']:>5}   {fmt_dur(r['median_s']):>7}  "
                 f"{fmt_dur(r['p75_s']):>7}  {fmt_dur(r['p90_s']):>7}   {tot:>10}{mark}")
    L.append("")
    if res["source"] == "study":
        L.append(f"  PROPOSED CHUNK   : {fmt_wall(res['chosen_min'])}")
        L.append(f"  why              : {res['reason']}")
    else:
        L.append(f"  NO PROPOSAL      : {res['reason']}")
    return "\n".join(L)


def machine_line(res: Dict, fallback_min: float) -> str:
    if res["source"] == "study":
        wall, src = res["chosen_min"], "study"
    else:
        wall, src = fallback_min, "fallback"
    reason = res["reason"].replace('"', "'")
    sh = res["shape"]
    return (f'WP_BACKFILL_STUDY wall_min={int(round(wall))} source={src} '
            f'feasible_any={int(res["feasible_any"])} '
            f'min_feasible_min={int(res["min_feasible_min"] or 0)} '
            f't_ion_s={res["t_ion_s"]:.1f} steps={res["steps"]} nodes={sh["nodes"]} '
            f'cpus={sh["cpus"]} mem_mb={sh["mem_mb"]:.0f} '
            f'level="{res["level"] or ""}" reason="{reason}"')


def queue_report(where: str, val: Dict, notes: List[str], level: Optional[str],
                 rows: List[Dict], past: List[Dict], maxtime: Tuple[Optional[float], str],
                 max_asked_min: Optional[float], days: int, n_jobs: int) -> str:
    L: List[str] = []
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
            L.append(f"  Expected wait: about {fmt_h(row['median_s'])}. Of the {row['n']} jobs of "
                     f"{LEVEL_WORDS.get(level, level)} that asked for {row['label']},")
            L.append(f"  half started within {fmt_h(row['median_s'])}, and 9 in 10 within "
                     f"{fmt_h(row['p90_s'])}.")
        else:
            L.append(f"  Not enough jobs of {LEVEL_WORDS.get(level, 'your size')} asked for "
                     f"{b[2] if b else fmt_slurm_time(wall)} to estimate its wait "
                     f"(fewer than {MIN_JOBS}).")
    for pj in past:
        lim = f"asked for {fmt_walltime(pj['limit_min'])} and " if pj.get("limit_min") else ""
        if pj["pending"]:
            L.append(f"  Your job {pj['jid']} here {lim}has been waiting {fmt_h(pj['wait_s'])}.")
        else:
            L.append(f"  Your job {pj['jid']} here {lim}waited {fmt_h(pj['wait_s'])}.")
    L.append("")

    # ---- the table ---------------------------------------------------------
    if rows:
        L.append(f"HOW LONG JOBS OF {LEVEL_WORDS.get(level, level).upper()} WAITED, "
                 f"BY THE WALLTIME THEY ASKED FOR")
        L.append(f"  {'asked for':<18}{'half started within':>21}{'9 in 10 within':>17}{'jobs':>7}")
        for r in rows:
            L.append(f"  {r['label']:<18}{fmt_h(r['median_s']):>21}{fmt_h(r['p90_s']):>17}{r['n']:>7}")
        L.append(f"  {LEVEL_WORDS.get(level, level)} = {size_words(level, nodes, cpus, mem)}."
                 f" Bands with fewer than {MIN_JOBS} such jobs are not shown.")
    else:
        L.append(f"No walltime band has {MIN_JOBS}+ jobs comparable to yours in the last {days} days.")
    for n in notes:
        L.append(f"  note: {n}")
    return "\n".join(L)


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
    p.add_argument("--mine", action="store_true", help="only your own jobs")
    p.add_argument("--json", default="", help="also write the analysis as JSON here")
    # vasp-relax-loop's call: its own ionic-step estimate and chunk settings.
    hide = argparse.SUPPRESS
    p.add_argument("--machine", action="store_true", help=hide)
    p.add_argument("--t-ion-s", type=float, help=hide)
    p.add_argument("--steps", type=int, help=hide)
    p.add_argument("--startup-s", type=float, help=hide)
    p.add_argument("--margin-min", type=float, help=hide)
    p.add_argument("--max-time-min", type=float, help=hide)
    p.add_argument("--default-wall-min", type=float, help=hide)
    p.add_argument("--min-jobs", type=int, default=MIN_JOBS, help=hide)
    a = p.parse_args(argv)

    given = {"partition": a.partition, "nodes": a.nodes, "cpus": a.cpus, "mem_mb": a.mem_mb,
             "days": a.days}
    if a.wall:
        tw = parse_walltime_arg(a.wall)
        if not tw:
            print(f"backfill-study: --time {a.wall!r}: give minutes or D-HH:MM:SS",
                  file=sys.stderr)
            return 2
        given["wall_min"] = tw
    notes: List[str] = []
    where = os.path.abspath(a.folder)
    if all(given[k] is not None for k in CORE):
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

    if a.max_time_min is None:
        maxtime = partition_maxtime(val["partition"])
    else:
        maxtime = ((a.max_time_min, "set") if a.max_time_min > 0 else (None, "unlimited"))
    mt = maxtime[0]
    cands = candidates_for(mt)
    days = int(val["days"])
    lines, err = run_sacct(val["partition"], days, all_users=not a.mine)
    jobs = load_jobs(lines)
    nodes, cpus, mem = int(val["nodes"]), int(val["cpus"]), float(val["mem_mb"])

    if a.machine:
        # vasp-relax-loop: the chunk walltime for ITS ionic-step estimate.
        if a.t_ion_s is None or a.steps is None:
            print("backfill-study: --machine needs --t-ion-s and --steps", file=sys.stderr)
            return 2
        res = study(jobs, nodes=nodes, cpus=cpus, mem_mb=mem, t_ion_s=a.t_ion_s,
                    startup_s=a.startup_s if a.startup_s is not None else float(DEF_STARTUP_S),
                    margin_cfg_min=a.margin_min if a.margin_min is not None else val["margin_min"],
                    steps=a.steps, max_time_min=mt,
                    default_wall_min=(a.default_wall_min if a.default_wall_min is not None
                                      else val["default_wall_min"]),
                    min_jobs=a.min_jobs)
        if err and res["source"] != "study" and res["feasible_any"]:
            res["reason"] = err
        fb = res["default_wall_min"] if mt is None else min(res["default_wall_min"], mt)
        print(chain_report(res, val["partition"], days))
        print(machine_line(res, fb))
        return 0 if res["feasible_any"] else 3

    level, rows = band_table(jobs, nodes, cpus, mem)
    # The longest walltime ANY job on the partition asked for: past it, the
    # history has nothing to say, and a limit may be why.
    max_asked = max((j.limit_min for j in jobs), default=None)
    past = folder_job_waits(where) if is_calc_folder(where) else []
    if err:
        notes.insert(0, err)
    print(queue_report(where, val, notes, level, rows, past, maxtime, max_asked, days, len(jobs)))
    if a.json:
        with open(a.json, "w") as fh:
            json.dump({"inputs": val, "maxtime": maxtime, "level": level, "bands": rows,
                       "max_asked_min": max_asked, "sacct_error": err}, fh, indent=1, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
