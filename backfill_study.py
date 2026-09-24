#!/usr/bin/env python3
"""backfill_study.py  (on PATH as: backfill-study)

What this cluster's queue has done to jobs shaped like yours, and which chunk
walltime that implies for a chunked relaxation.  A command of its own, and the
library vasp-relax-loop calls at launch.

    cd <calc folder>        # after vasp-dry-run -> vasp-recommend-slurm -> vasp-test
    backfill-study          # everything is read from the folder, as the chain would

    backfill-study --partition main --nodes 1 --cpus 40 --mem-mb 80000 \
                   --t-ion-s 115 --steps 100     # no folder: say it yourself

Any value given on the command line wins over the one read from the folder;
that is how vasp-relax-loop calls it, with its own numbers, so the walltime it
proposes is judged by the same arithmetic the chain then runs on.

The last line of the output is for programs, not people:
    WP_BACKFILL_STUDY wall_min=... source=study|fallback ... reason="..."

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
THE DECISION
==============================================================================
For each candidate walltime W the chain's own arithmetic is replayed:

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
def study(jobs: Sequence[Job], *, nodes: int, cpus: int, mem_mb: float,
          t_ion_s: float, startup_s: float, margin_cfg_min: float,
          steps: int, max_time_min: Optional[float],
          default_wall_min: float, min_jobs: int = MIN_JOBS,
          candidates: Sequence[float] = CANDIDATES_MIN) -> Dict:
    """The whole analysis, as a plain dict (the CLI prints it; tests read it)."""
    cands = sorted({float(c) for c in candidates
                    if max_time_min is None or c <= max_time_min})
    if max_time_min is not None and max_time_min > 0 and max_time_min not in cands:
        cands.append(float(max_time_min))
        cands.sort()

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

    # Bin edges: a job belongs to the smallest candidate >= its request.
    def bin_of(limit: float) -> Optional[float]:
        for w in cands:
            if limit <= w + 1e-9:
                return w
        return None

    chosen_level = None
    level_bins: Dict[float, List[float]] = {}
    for name, un, uc, um in LEVELS:
        bins: Dict[float, List[float]] = {w: [] for w in cands}
        for j in jobs:
            if not is_similar(j, nodes, cpus, mem_mb, un, uc, um):
                continue
            b = bin_of(j.limit_min)
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
            b = bin_of(j.limit_min)
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
        res["reason"] = (f"fewer than two feasible walltimes have {min_jobs}+ comparable "
                         f"jobs in the accounting data ({len(jobs)} started jobs seen)")
        return res

    res["level"] = chosen_level
    usable_rows = [r for r in res["rows"] if r["usable"]]
    best = min(usable_rows, key=lambda r: (r["total_s"], r["wall_min"]))
    res["chosen_min"] = best["wall_min"]
    res["source"] = "study"
    res["reason"] = (f"smallest expected time to finish {steps} ionic step(s): "
                     f"{best['chunks']} chunk(s) x median wait "
                     f"{fmt_dur(best['median_s'])} (n={best['n']}, level: {chosen_level})")
    return res


def sensitivity(jobs: Sequence[Job]) -> Dict[str, List[Tuple[str, int, float]]]:
    """How this partition treats job SHAPE, whatever the walltime. Context for
    the reader, not an input to the decision."""
    def table(keyfn, order):
        acc: Dict[str, List[float]] = {k: [] for k in order}
        for j in jobs:
            k = keyfn(j)
            if k in acc:
                acc[k].append(j.wait_s)
        return [(k, len(v), median(v)) for k, v in acc.items() if v]

    def cores_band(j):
        c = j.cpus
        for lim, lab in ((8, "1-8"), (32, "9-32"), (64, "33-64"), (128, "65-128"),
                         (256, "129-256")):
            if c <= lim:
                return lab
        return "257+"

    def mem_band(j):
        if j.mem_mb is None:
            return None
        g = j.mem_mb / j.cpus / 1024.0
        for lim, lab in ((1, "<=1 GB/core"), (2, "1-2 GB/core"), (4, "2-4 GB/core"),
                         (8, "4-8 GB/core")):
            if g <= lim:
                return lab
        return ">8 GB/core"

    def wall_band(j):
        m = j.limit_min
        for lim, lab in ((60, "<=1 h"), (240, "1-4 h"), (720, "4-12 h"),
                         (1440, "12-24 h"), (2880, "24-48 h")):
            if m <= lim:
                return lab
        return ">48 h"

    return {
        "nodes": table(lambda j: node_band(j.nodes), ["1", "2-4", "5-16", "17+"]),
        "cores": table(cores_band, ["1-8", "9-32", "33-64", "65-128", "129-256", "257+"]),
        "memory": table(mem_band, ["<=1 GB/core", "1-2 GB/core", "2-4 GB/core",
                                   "4-8 GB/core", ">8 GB/core"]),
        "walltime": table(wall_band, ["<=1 h", "1-4 h", "4-12 h", "12-24 h",
                                      "24-48 h", ">48 h"]),
    }


# --------------------------------------------------------------------------- #
# A calculation folder: the inputs vasp-relax-loop derives at launch
# --------------------------------------------------------------------------- #
# The same files, the same defaults and the same arithmetic as vasp_chain.sh.
# test_32 runs both on one folder and requires the same numbers from each.
CHAIN_STEP_OVERHEAD = 1.15   # the +15 % the chain adds to an ionic step
SPI_DEFAULT = 12.0           # electronic steps per ionic step, when unmeasured
SPI_MAX = 25.0
DEF_WALLTIME_MIN = 600       # DEF_WALLTIME_MIN in vasp_chain.sh
DEF_MARGIN_MIN = 5           # DEF_MARGIN_MIN
DEF_STARTUP_S = 120          # when vasp-test recorded no start-up time
DEF_DAYS = 30                # WP_CHAIN_QUEUE_DAYS


def read_kv(path: str) -> Dict[str, str]:
    """KEY="value" lines, as the profile and .wolfpack/state.env are written."""
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


def _num(v, default: float = 0.0) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _whole(v, default: int = 0) -> int:
    """vasp_chain.sh's int(): keep the digits of an integer field."""
    d = re.sub(r"[^0-9-]", "", str(v or ""))
    try:
        return int(d)
    except ValueError:
        return default


def partition_maxtime_min(partition: str) -> Optional[float]:
    """The partition's MaxTime in minutes; None when unlimited or unknown."""
    try:
        p = subprocess.run(["scontrol", "show", "partition", partition],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"MaxTime=(\S+)", p.stdout or "")
    if not m or m.group(1) in ("UNLIMITED", "INFINITE", "NONE"):
        return None
    v = parse_timelimit_min("", m.group(1))
    return v if v and v > 0 else None


def ionic_step_estimate(t_e: float, test_ranks: int, ranks: int, cpu_eff: float,
                        spi_measured: float, nelmin: int) -> Tuple[float, float, float, str]:
    """(cal, spi, t_ion, spi_source): vasp_chain.sh's launch estimate, rounded
    at the same places (%.3f, %.1f, %.1f) so both print the same number."""
    r = test_ranks / ranks if (test_ranks > 0 and ranks > 0) else 1.0
    e = min(max(cpu_eff / 100.0, 0.3), 1.0)
    cal = float("%.3f" % (t_e * r / e))
    nm = nelmin if nelmin >= 2 else 2
    src = "measured by vasp-test"
    s = spi_measured
    if s <= 0:
        s, src = SPI_DEFAULT, "ASSUMED -- vasp-test never finished an ionic step"
    s = min(max(s, float(nm)), SPI_MAX)
    spi = float("%.1f" % s)
    t_ion = float("%.1f" % (cal * spi * CHAIN_STEP_OVERHEAD))
    return cal, spi, t_ion, src


def from_folder(folder: str) -> Tuple[Dict, Dict[str, str], List[str]]:
    """(values, where-each-came-from, errors) for a calculation folder."""
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import wolfpack_incar as _incar          # the toolkit's own INCAR reader

    val: Dict = {}
    src: Dict[str, str] = {}
    err: List[str] = []
    conf_path = os.environ.get("WOLFPACK_CLUSTER_CONF") or \
        os.path.expanduser("~/.config/wolfpack-dft/cluster.conf")
    conf = read_kv(conf_path)
    state = read_kv(os.path.join(folder, ".wolfpack", "state.env"))

    job_path = os.path.join(folder, "slurm_vasptest.sh")
    try:
        job = open(job_path).read()
    except OSError:
        job = ""
        err.append("no slurm_vasptest.sh here: run vasp-dry-run -> vasp-recommend-slurm "
                   "-> vasp-test first, or give --nodes --cpus --mem-mb --t-ion-s")
    ranks = _whole(sbatch_value(job, "ntasks"))
    nodes = _whole(sbatch_value(job, "nodes"), 1) or 1
    memcpu = _whole(sbatch_value(job, "mem-per-cpu"))
    val["cpus"], src["cpus"] = ranks, "slurm_vasptest.sh --ntasks"
    val["nodes"], src["nodes"] = nodes, "slurm_vasptest.sh --nodes"
    val["mem_mb"], src["mem_mb"] = float(memcpu * ranks), "slurm_vasptest.sh --mem-per-cpu x --ntasks"
    part = sbatch_value(job, "partition")
    main_part = conf.get("WP_MAIN_PARTITION") or os.environ.get("WP_MAIN_PARTITION")
    if part:
        val["partition"], src["partition"] = part, "slurm_vasptest.sh --partition"
    elif main_part:
        val["partition"], src["partition"] = main_part, "profile WP_MAIN_PARTITION"
    if job and (ranks <= 0 or memcpu <= 0):
        err.append("slurm_vasptest.sh has no --ntasks or no --mem-per-cpu")

    t_e = _num(state.get("test_avg_loop"))
    if t_e <= 0:
        err.append("no measured per-step time (test_avg_loop) in .wolfpack/state.env: "
                   "run vasp-test here, or give --t-ion-s")
    incar_live = os.path.join(folder, "INCAR")
    incar_bak = os.path.join(folder, "INCAR.chain.bak")
    try:
        live = open(incar_live).read()
    except OSError:
        live = ""
    nelmin = _whole(_incar.get_tag(live, "NELMIN") or "")
    cal, spi, t_ion, spi_src = ionic_step_estimate(
        t_e, _whole(state.get("test_ranks")), ranks,
        _num(state.get("test_cpu_eff") or 100, 100.0),
        _num(state.get("test_scf_per_ionic")), nelmin)
    val["t_ion_s"] = t_ion
    src["t_ion_s"] = ("%.3f s/electronic step x %.1f per ionic step (%s) x %.2f"
                      % (cal, spi, spi_src, CHAIN_STEP_OVERHEAD))

    # NSW, the whole relaxation's steps. From the chain's backup of YOUR INCAR
    # when there is one: a chain rewrites NSW in the live INCAR every chunk.
    nsw_file = incar_bak if os.path.isfile(incar_bak) else incar_live
    try:
        nsw_text = open(nsw_file).read()
    except OSError:
        nsw_text = ""
    nsw = _whole(_incar.get_tag(nsw_text, "NSW") or "")
    val["steps"] = nsw
    src["steps"] = "NSW in %s" % os.path.basename(nsw_file)
    if nsw <= 1:
        err.append("NSW=%d in %s: there is no relaxation to chunk"
                   % (nsw, os.path.basename(nsw_file)))

    # Rounded, not truncated digit by digit: vasp-test writes "58.3".
    st = state.get("test_startup_s")
    val["startup_s"] = float(int(max(_num(st, 0.0), 0.0) + 0.5)) \
        if st not in (None, "") else float(DEF_STARTUP_S)
    src["startup_s"] = "vasp-test (test_startup_s)" if st not in (None, "") \
        else "default (vasp-test recorded none)"
    # The chain sources the profile over its environment: a key the profile
    # sets wins, one it does not set comes from the environment, else default.
    def setting(key):
        v = conf.get(key)
        return v if v not in (None, "") else os.environ.get(key) or None
    mg = setting("WP_CHUNK_MARGIN_MIN")
    val["margin_min"] = float(_whole(mg)) if mg is not None else float(DEF_MARGIN_MIN)
    src["margin_min"] = "profile WP_CHUNK_MARGIN_MIN" if mg is not None else "default"
    dw = setting("WP_CHUNK_WALLTIME_MIN")
    val["default_wall_min"] = float(_whole(dw)) if dw is not None else float(DEF_WALLTIME_MIN)
    src["default_wall_min"] = "profile WP_CHUNK_WALLTIME_MIN" if dw is not None else "default"
    days = setting("WP_CHAIN_QUEUE_DAYS")
    val["days"] = _whole(days, DEF_DAYS) or DEF_DAYS
    src["days"] = "WP_CHAIN_QUEUE_DAYS" if days else "default"
    return val, src, err


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


def report(res: Dict, sens: Optional[Dict] = None, partition: str = "",
           days: int = 0, sources: Optional[Dict[str, str]] = None) -> str:
    L: List[str] = []
    sh = res["shape"]
    if sources:
        L.append("  where the inputs came from:")
        for k in ("partition", "nodes", "cpus", "mem_mb", "t_ion_s", "steps",
                  "startup_s", "margin_min", "default_wall_min", "days"):
            if k in sources:
                L.append(f"    {k:<17}{sources[k]}")
        L.append("")
    L.append(f"  partition        : {partition or '?'}"
             + (f"   (MaxTime {fmt_wall(res['max_time_min'])})" if res["max_time_min"]
                else "   (MaxTime unlimited or unknown)"))
    L.append(f"  your job         : {sh['nodes']} node(s), {sh['cpus']} cores, "
             f"{sh['mem_mb'] / 1024:.0f} GB requested")
    L.append(f"  ionic step       : ~{res['t_ion_s']:.0f} s   start-up {res['startup_s']:.0f} s   "
             f"steps to do {res['steps']} (NSW remaining -- a ceiling, not a forecast)")
    L.append(f"  accounting data  : {res['n_jobs']} started job(s) over the last {days} day(s)")
    L.append(f"  similarity level : {res['level'] or '-- not enough data at any level --'}")
    L.append("")
    L.append("  walltime   fits?  steps/chunk  chunks   jobs   median    p75      p90     expected total")
    L.append("  " + "-" * 92)
    for r in res["rows"]:
        fits = "yes" if r["feasible"] else "NO"
        tot = fmt_dur(r["total_s"]) if r["total_s"] is not None else "--"
        mark = "  <" if res["chosen_min"] == r["wall_min"] else ""
        L.append(f"  {fmt_wall(r['wall_min']):>8}   {fits:>4}   {r['steady_cap'] or '--':>9}   "
                 f"{r['chunks'] or '--':>6}   {r['n']:>5}   {fmt_dur(r['median_s']):>7}  "
                 f"{fmt_dur(r['p75_s']):>7}  {fmt_dur(r['p90_s']):>7}   {tot:>10}{mark}")
    L.append("")
    if sens:
        L.append("  How this partition treats job shape (all walltimes, median wait):")
        for axis in ("nodes", "cores", "memory", "walltime"):
            cells = "   ".join(f"{k}: {fmt_dur(m)} (n={n})" for k, n, m in sens.get(axis, []))
            L.append(f"    {axis:<9} {cells or '--'}")
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


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(
        prog="backfill-study",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Which chunk walltime this queue rewards, for a chunked "
                    "relaxation shaped like this one. Reads the partition's own "
                    "accounting history (sacct) and replays vasp-relax-loop's "
                    "arithmetic. Launches nothing.",
        epilog="In a calculation folder after vasp-test, no option is needed: "
               "everything is read from slurm_vasptest.sh, .wolfpack/state.env, "
               "the INCAR and the cluster profile. Any option given wins over "
               "what the folder says.")
    p.add_argument("folder", nargs="?", default=".",
                   help="calculation folder (default: here)")
    p.add_argument("--partition")
    p.add_argument("--nodes", type=int)
    p.add_argument("--cpus", type=int, help="total cores (ranks) of the job")
    p.add_argument("--mem-mb", type=float, help="TOTAL requested memory, MB")
    p.add_argument("--t-ion-s", type=float, help="estimated ionic step, s")
    p.add_argument("--steps", type=int, help="ionic steps to do (NSW)")
    p.add_argument("--startup-s", type=float)
    p.add_argument("--margin-min", type=float,
                   help="chunk end margin (WP_CHUNK_MARGIN_MIN)")
    p.add_argument("--max-time-min", type=float,
                   help="partition MaxTime in minutes; 0 = unlimited. Default: ask scontrol")
    p.add_argument("--default-wall-min", type=float,
                   help="the walltime to fall back on when the study cannot decide")
    p.add_argument("--days", type=int, help="history to read (default 30)")
    p.add_argument("--min-jobs", type=int, default=MIN_JOBS)
    p.add_argument("--mine", action="store_true", help="only your own jobs")
    p.add_argument("--json", default="", help="also write the analysis as JSON here")
    a = p.parse_args(argv)

    given = {k: getattr(a, k) for k in ("partition", "nodes", "cpus", "mem_mb", "t_ion_s",
                                        "steps", "startup_s", "margin_min",
                                        "default_wall_min", "days")}
    needed = ("partition", "nodes", "cpus", "mem_mb", "t_ion_s", "steps")
    val: Dict = {}
    sources: Dict[str, str] = {}
    errors: List[str] = []
    if any(given[k] is None for k in needed):
        # Only read the folder when the command line does not say it all -- the
        # chain passes everything and must not depend on the folder parsing.
        val, sources, errors = from_folder(a.folder)
    for k, v in given.items():
        if v is not None:
            val[k] = v
            sources[k] = "command line"
    val.setdefault("startup_s", float(DEF_STARTUP_S))
    val.setdefault("margin_min", float(DEF_MARGIN_MIN))
    val.setdefault("default_wall_min", float(DEF_WALLTIME_MIN))
    val.setdefault("days", DEF_DAYS)
    missing = [k for k in needed if val.get(k) in (None, 0, 0.0, "")]
    if missing:
        for e in errors:
            print(f"backfill-study: {e}", file=sys.stderr)
        print("backfill-study: cannot study without: " + ", ".join(missing), file=sys.stderr)
        return 2

    if a.max_time_min is None:
        mt = partition_maxtime_min(val["partition"])
        if "partition" in sources and mt is not None:
            sources["max_time_min"] = "scontrol"
    else:
        mt = a.max_time_min if a.max_time_min > 0 else None

    lines, err = run_sacct(val["partition"], int(val["days"]), all_users=not a.mine)
    jobs = load_jobs(lines)
    res = study(jobs, nodes=int(val["nodes"]), cpus=int(val["cpus"]),
                mem_mb=float(val["mem_mb"]), t_ion_s=float(val["t_ion_s"]),
                startup_s=float(val["startup_s"]), margin_cfg_min=float(val["margin_min"]),
                steps=int(val["steps"]), max_time_min=mt,
                default_wall_min=float(val["default_wall_min"]), min_jobs=a.min_jobs)
    if err and res["source"] != "study" and res["feasible_any"]:
        res["reason"] = err
    sens = sensitivity(jobs) if jobs else None
    shown = {k: v for k, v in sources.items() if v != "command line"}
    print(report(res, sens, val["partition"], int(val["days"]), shown or None))
    if a.json:
        with open(a.json, "w") as fh:
            json.dump({"inputs": val, "sources": sources, "result": res,
                       "sensitivity": sens, "sacct_error": err}, fh, indent=1, default=str)
    fb = float(val["default_wall_min"])
    if mt is not None:
        fb = min(fb, mt)
    print(machine_line(res, fb))
    # 3 = not one ionic step fits at ANY walltime the partition allows. The
    # chain refuses on this rather than submit chunks that cannot progress.
    return 0 if res["feasible_any"] else 3


if __name__ == "__main__":
    sys.exit(main())
