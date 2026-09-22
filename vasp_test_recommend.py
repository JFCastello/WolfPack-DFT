#!/usr/bin/env python3
"""
vasp_test_recommend.py   (internal helper for vasp-test; not a user command)
===========================================================================
STAGE 3 of the dry-run -> recommend -> test pipeline.

vasp-recommend produced a FIXED parallel configuration (KPAR/NCORE/NSIM and a
target rank count, e.g. 120) and wrote it into slurm.sh. The benchmark cannot
fit 120 ranks on the 96-core debug partition, so vasp-test ran the SAME fixed
config at a smaller, debug-sized rank count and measured the real per-rank
memory (SLURM MaxRSS).

This helper then:
  * scales the measured per-rank memory from the TEST rank count to the
    PRODUCTION rank count using the VASP component-distribution rules
    (wavefunctions ~ 1/total_ranks, grid ~ 1/NPAR, projectors ~ 1/NCORE),
    anchored to the measurement;
  * sizes the production memory REQUEST to the cluster's utilisation policy
    (request = predicted_use / mem_util), and lays it out as one node if it fits
    else exactly KPAR nodes (one whole k-point group per node);
  * writes the DEFINITIVE production job (the path given to --update-slurm, i.e.
    slurm_vasptest.sh) with the refined mem-per-cpu / nodes / ntasks-per-node;
  * prints a VERDICT on whether the recommended config is adequate and appends
    a STAGE 3 section to report.out.

Stdlib only -- runs on any compute node with python3.
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path


# --------------------------------------------------------------------------- #
# OUTCAR memory breakdown (for the test -> production scaling)
# --------------------------------------------------------------------------- #
def parse_outcar_memory(text: str) -> dict:
    """Parse the rank-0 memory breakdown (base/wave/grid/...) from OUTCAR text."""
    out = dict(base=0.0, nonlr=0.0, fft=0.0, grid=0.0, one=0.0, wave=0.0, total=0.0)
    m = re.search(r"total amount of memory used by VASP MPI-rank0\s+([0-9.]+)\.?\s*k[bB]ytes", text)
    if m:
        out["total"] = float(m.group(1)) / 1024.0
    rows = {"base": "base", "nonlr-proj": "nonlr", "nonl-proj": "nonlr",
            "fftplans": "fft", "grid": "grid", "one-center": "one", "wavefun": "wave"}
    for label, key in rows.items():
        m = re.search(rf"(?:^|\s){re.escape(label)}\s*:\s*([0-9.]+)\.?\s*k[bB]ytes",
                      text, re.IGNORECASE | re.MULTILINE)
        if m:
            out[key] = float(m.group(1)) / 1024.0
    return out


def _outcar_encutgw(text):
    """ENCUTGW (eV) from the OUTCAR text, or None (the response-block memory lever)."""
    m = re.search(r"ENCUTGW\s*=\s*([0-9.]+)", text)
    try:
        return float(m.group(1)) if m else None
    except (TypeError, ValueError):
        return None


def _outcar_min_mem_per_rank(text):
    """VASP's OWN reported per-rank GW memory requirement (MB), or None.

        min. memory requirement per mpi rank  7282.6 MB, per node 873917.5 MB
        ... Available memory per mpi rank: 4961 MB, required memory: 7282 MB.

    This is the AUTHORITATIVE conventional-GW floor (printed during the response-
    function setup). We take the largest such number found."""
    vals = []
    for m in re.finditer(
        r"min\.?\s*memory requirement per mpi rank\s+([0-9]+(?:\.[0-9]+)?)\s*MB",
        text, flags=re.IGNORECASE):
        vals.append(float(m.group(1)))
    for m in re.finditer(
        r"required memory:\s*([0-9]+(?:\.[0-9]+)?)\s*MB", text, flags=re.IGNORECASE):
        vals.append(float(m.group(1)))
    return max(vals) if vals else None


# --- Conventional-GW per-rank memory FLOOR model (mirror of vasp_recommend_slurm) --- #
# The GW floor is NOMEGA-INDEPENDENT, ~ENCUTGW^3, and ~1/ranks-per-k-group. A short
# benchmark CANNOT measure it (it never reaches the GW response setup). PROVISION TO
# VASP's OWN printed "min. memory requirement per mpi rank" (anchor 7282 @ rpk=40,
# ENCUTGW=405) -- NO discount. An earlier 0.80 "real-RSS" discount (from a NOMEGA=25 run
# that fit 1 node at 96.6%) OOM'd the next NOMEGA=100 run; VASP's printed number is the
# number to trust. MAXMEM is DERIVED (mem-per-cpu - reserve), never chased. See the
# research notes in vasp_recommend_slurm.py.
GW_FLOOR_ANCHOR_MB = 7282.0
GW_FLOOR_ANCHOR_RPK = 40.0
GW_FLOOR_ANCHOR_ENCUTGW = 405.0
GW_VASP_REQ_TO_RSS = 1.00         # provision to VASP's FULL requirement (no discount)
# MAXMEM is a FROZEN INPUT. VASP fills whatever MAXMEM it gets and really uses
# ~MAXMEM + ~2 GB (measured: required 7282@MAXMEM 4961, 9566@7692, 9799@7692, 12083@10550,
# 15128@13300). The old rule (MAXMEM = mem-per-cpu - 15%) DIVERGED: every OOM harvest
# raised mem-per-cpu -> bigger MAXMEM -> bigger demand -> OOM again. Now: MAXMEM <=
# mem-per-cpu - OVERHEAD, and on a refine it can only stay or go DOWN (frozen to the
# INCAR's previous value), so the relaunch demand is pinned and converges in one step.
GW_MAXMEM_OVERHEAD_MB = 3000

# A benchmark measurement above this multiple of the a-priori model is treated as an
# accounting artifact, not physics. Genuine real-RSS overhead is ~1.5-3x; 10x leaves
# a wide margin so this never fires on legitimate data.
SANITY_MAX_MODEL_RATIO = 10.0


def gw_floor_per_rank_mb(rpk, encutgw, anchor_mb=GW_FLOOR_ANCHOR_MB,
                         anchor_rpk=GW_FLOOR_ANCHOR_RPK,
                         anchor_encutgw=GW_FLOOR_ANCHOR_ENCUTGW):
    """anchor_mb * (anchor_rpk/rpk) * (ENCUTGW/anchor_encutgw)^3 -- NOMEGA-independent."""
    rpk = max(1.0, float(rpk))
    e = float(encutgw or anchor_encutgw)
    return max(1.0, anchor_mb * (anchor_rpk / rpk) * (e / max(anchor_encutgw, 1.0)) ** 3)


def gw_maxmem_from_request(mem_per_cpu_mb, existing_mb=None):
    """MAXMEM (MB/rank): capped at mem-per-cpu - GW_MAXMEM_OVERHEAD_MB and FROZEN --
    never raised above the value the previous run used (`existing_mb`). VASP fills
    whatever MAXMEM it gets and uses ~MAXMEM + ~2 GB, so raising MAXMEM with the
    allocation is a divergent ratchet; freezing it pins the demand."""
    cap = mem_per_cpu_mb - GW_MAXMEM_OVERHEAD_MB
    if existing_mb and existing_mb > 0:
        cap = min(cap, existing_mb)
    return int(max(2800, cap))


def _incar_existing_maxmem(path):
    """The MAXMEM (MB) already in the INCAR -- the value the previous run USED -- or None."""
    try:
        m = re.search(r"(?im)^[ \t]*MAXMEM[ \t]*=[ \t]*([0-9]+)", Path(path).read_text())
        return int(m.group(1)) if m else None
    except (OSError, ValueError):
        return None


def make_estimator(anchor_mb, mem, nt, npar_t, ncore_t):
    """per_rank(ranks, npar, ncore) -> MB, anchored to a measured per-rank value.

    `anchor_mb` must be the MEAN per-rank memory (sacct AveRSS), not the peak of the
    heaviest rank (MaxRSS): SLURM enforces the NODE TOTAL (mem-per-cpu x ranks-per-node)
    and that total is mean x ranks. See the note in main() on the rank-imbalance trap."""
    def model_total(ranks, npar, ncore):
        """Modelled total per-rank MB at a layout (VASP component-distribution rules)."""
        return (mem["base"] + mem["fft"] + mem["one"]
                + mem["wave"] * nt / max(ranks, 1)
                + mem["grid"] * npar_t / max(npar, 1)
                + mem["nonlr"] * ncore_t / max(ncore, 1))
    m_test = model_total(nt, npar_t, ncore_t)
    have_table = m_test > 1.0 and (mem["wave"] > 0 or mem["grid"] > 0)
    corr = (anchor_mb / m_test) if (have_table and anchor_mb > 0) else None

    def per_rank(ranks, npar, ncore):
        """Per-rank MB at (ranks, npar, ncore), anchored to the measurement."""
        if corr is not None:
            return corr * model_total(ranks, npar, ncore)
        # No usable table: wavefunction-dominant 70%/30% split of the measurement.
        return anchor_mb * (0.30 + 0.70 * nt / max(ranks, 1))
    return per_rank, corr


def round_up(x, step=50):
    """Round `x` up to the next multiple of `step`."""
    return int(math.ceil(max(x, 1.0) / step) * step)


def geometry(total, cpn, prod_use, node_mem, mem_util=0.80, reserve=0, kpar=1,
             gw_node_frac=0.0):
    """(mem_per_cpu, nodes, ntasks_per_node) keeping WHOLE k-point groups on a node.

    Sizes the request for >= mem_util utilisation, but the per-node ceiling comes
    from the REAL predicted USAGE (prod_use), not the padded request -- so a whole
    k-group that fits a node at its actual RSS is kept together; the request is then
    TRIMMED (never below usage) to fit, instead of spilling onto an extra node and
    straddling the group. Each node holds g k-groups (g*rpk ranks), g the largest
    divisor of KPAR that fits; nodes = KPAR/g. Falls back to a plain split only when
    one group does not fit a node even at full usage (KPAR=1, or a huge group)."""
    usable = max(int(math.ceil(prod_use)), node_mem - max(reserve, 0))
    desired = max(200, round_up(prod_use / max(mem_util, 0.05)))
    by_use = max(1, usable // max(int(math.ceil(prod_use)), 1))   # ranks/node at REAL usage
    cap = max(1, min(cpn, by_use))
    kpar = max(1, int(kpar or 1))
    rpk = total // kpar if (kpar and total % kpar == 0) else 0
    if total <= cap:                                  # whole job fits ONE node
        nodes, ntpn = 1, total
    elif kpar > 1 and rpk and rpk <= cap:             # split across KPAR nodes (one group/node)
        nodes, ntpn = kpar, rpk
    else:                                             # memory-only fallback
        ntpn = min(cpn, total, cap)
        nodes = max(1, math.ceil(total / ntpn))
        ntpn = min(cpn, math.ceil(total / nodes))
    fit_req = usable // max(ntpn, 1)
    mem_per_cpu = max(200, min(desired, max(int(math.ceil(prod_use)), (fit_req // 50) * 50)))
    # GW SWEET raise: grow the request to the queue-friendly node share (gw_node_frac,
    # default 0.67 = leave ~1/3 of the node free for backfill) so the frozen MAXMEM
    # (= mem-per-cpu - 3 GB, set by the caller) is as large -- and the frequency
    # batching as fast -- as the queue allows. Safe at any level: VASP's demand is
    # ~MAXMEM + 2.1 GB (measured law), landing ~0.9 GB under the allocation.
    if gw_node_frac > 0:
        _avail = max(0, node_mem - max(reserve, 0))
        sweet = (int(gw_node_frac * _avail) // max(ntpn, 1)) // 50 * 50
        mem_per_cpu = max(mem_per_cpu, min(sweet, (fit_req // 50) * 50))
    return mem_per_cpu, nodes, ntpn


def _sub(text, pattern, repl):
    """Replace the first multiline match of `pattern` with `repl`."""
    return re.sub(pattern, repl, text, count=1, flags=re.MULTILINE)


def update_slurm(path, mem_per_cpu, nodes, ntpn):
    """Rewrite the production slurm.sh memory/geometry in place."""
    try:
        t = Path(path).read_text()
    except OSError:
        return False
    t = _sub(t, r"^#SBATCH --mem-per-cpu=.*$", f"#SBATCH --mem-per-cpu={mem_per_cpu}")
    t = _sub(t, r"^#SBATCH --nodes=.*$", f"#SBATCH --nodes={nodes}")
    t = _sub(t, r"^#SBATCH --ntasks-per-node=.*$", f"#SBATCH --ntasks-per-node={ntpn}")
    if "updated by vasp-test" not in t:
        t = t.replace("#!/bin/bash\n",
                      "#!/bin/bash\n# (memory updated by vasp-test from a real "
                      "benchmark; see report.out)\n", 1)
    try:
        Path(path).write_text(t)
        return True
    except OSError:
        return False


def write_incar_maxmem(path, maxmem):
    """Set MAXMEM (MB/rank) in the INCAR -- vasp-test OWNS the GW memory directive.
    DERIVED = mem-per-cpu - reserve (not chased). Replaces the value in place keeping
    any comment, else appends. Backup INCAR.bak once."""
    try:
        t = Path(path).read_text()
    except OSError:
        return False
    bak = Path(str(path) + ".bak")
    if not bak.exists():
        try:
            bak.write_text(t)
        except OSError:
            pass
    line = (f"MAXMEM = {maxmem}   # set by vasp-test: FROZEN budget (never raised on a refine; "
            f"VASP uses ~MAXMEM+2GB, which must fit inside mem-per-cpu). OOM fix = more "
            f"mem-per-cpu/nodes or lower ENCUTGW, NOT a bigger MAXMEM")
    if re.search(r"(?im)^[ \t]*MAXMEM[ \t]*=", t):
        t = re.sub(r"(?im)^[ \t]*MAXMEM[ \t]*=.*$", line, t, count=1)
    else:
        t = t + ("" if t.endswith("\n") else "\n") + line + "\n"
    try:
        Path(path).write_text(t)
        return True
    except OSError:
        return False


def main():
    """CLI entry: scale the measured memory to production, update slurm.sh and report.out."""
    p = argparse.ArgumentParser(description="vasp-test STAGE 3: scale + update slurm.sh")
    p.add_argument("outcar", type=Path)
    p.add_argument("--maxrss-mb", type=float, required=True,
                   help="sacct MaxRSS (MB): the HEAVIEST single rank. Diagnostics only -- "
                        "sizing uses --averss-mb, because rank 0 is often a big outlier.")
    p.add_argument("--averss-mb", type=float, default=0.0,
                   help="sacct AveRSS (MB): the MEAN rank. This is what sizes the request, "
                        "since the node total SLURM enforces = mean x ranks-per-node. "
                        "0 = unavailable -> fall back to MaxRSS (conservative).")
    p.add_argument("--ntasks-test", type=int, required=True)
    p.add_argument("--test-kpar", type=int, default=1)
    p.add_argument("--test-ncore", type=int, default=1)
    p.add_argument("--test-npar", type=int, default=1)
    # production (fixed) config from vasp-recommend
    p.add_argument("--prod-ranks", type=int, required=True)
    p.add_argument("--prod-kpar", type=int, default=1)
    p.add_argument("--prod-ncore", type=int, default=1)
    p.add_argument("--prod-npar", type=int, default=1)
    p.add_argument("--prod-nsim", type=int, default=4)
    p.add_argument("--prod-partition", default="main")
    p.add_argument("--cpus-per-node", type=int, required=True)
    p.add_argument("--node-mem-mb", type=int, required=True)
    p.add_argument("--mem-util", type=float, default=0.80)
    # GW: the benchmark only reaches the FLAT phase and CANNOT measure the GW floor, so
    # we use VASP's own reported requirement (--gw-floor-mb / parsed from OUTCAR) or an
    # anchored NOMEGA-independent floor -- NOT a flat x factor extrapolation.
    p.add_argument("--gw", action="store_true",
                   help="GW/RPA run: size from the per-rank FLOOR (NOMEGA-independent, ~ENCUTGW^3)")
    p.add_argument("--gw-floor-mb", type=float, default=0.0,
                   help="VASP's own per-rank requirement (MB) harvested from a real/failed run; "
                        "authoritative floor at the production layout (0 = use OUTCAR/anchor)")
    p.add_argument("--gw-peak-factor", type=float, default=8.0,
                   help="(deprecated/ignored: the floor model replaced flat x factor)")
    p.add_argument("--nomega", type=int, default=0,
                   help="(informational only: the GW floor is NOMEGA-independent)")
    p.add_argument("--gw-node-frac", type=float, default=0.67,
                   help="GW SWEET sizing: grow the per-node request to this fraction of "
                        "the node so the frozen MAXMEM buys batching speed while the "
                        "rest of the node stays free for queue backfill (0 = need-based)")
    # what vasp-recommend PREDICTED (for the predicted-vs-measured comparison)
    p.add_argument("--pred-peak-mb", type=float, default=0.0,
                   help="recommend's predicted per-rank peak (MB) at the prod layout")
    p.add_argument("--pred-flat-mb", type=float, default=0.0,
                   help="recommend's predicted flat/base per-rank (MB)")
    p.add_argument("--pred-mem-per-cpu", type=float, default=0.0,
                   help="recommend's first-pass --mem-per-cpu (MB)")
    p.add_argument("--pred-nodes", type=int, default=0,
                   help="recommend's first-pass node count")
    p.add_argument("--pred-ntpn", type=int, default=0,
                   help="recommend's first-pass ranks-per-node")
    # measured timing / efficiency (for the verdict + report)
    p.add_argument("--cpu-eff", type=float, default=0.0)
    p.add_argument("--avg-loop", type=float, default=0.0)
    p.add_argument("--nscf", type=int, default=0)
    p.add_argument("--wall", type=int, default=0)
    p.add_argument("--update-slurm", type=Path, default=None)
    p.add_argument("--incar", type=Path, default=None,
                   help="GW only: write MAXMEM (= request - max(200,18%%)) into this INCAR "
                        # %% is escaped: argparse runs every help string through
                        # %%-formatting, and a lone %% raises "badly formed help
                        # string" at PARSE time -- which killed the whole scaling
                        # step, so vasp-test measured the run and then wrote no
                        # predicted-vs-measured section at all.
                        "(vasp-test owns the GW memory directive).")
    p.add_argument("--report", type=Path, default=None)
    args = p.parse_args()

    text = ""
    try:
        text = Path(args.outcar).read_text(errors="replace")
    except OSError:
        pass
    mem = parse_outcar_memory(text)

    # WHICH MEASUREMENT SIZES THE REQUEST -- the rank-imbalance trap.
    # SLURM enforces the NODE TOTAL (mem-per-cpu x ranks-per-node), and that total is
    # (mean per rank) x ranks, i.e. sacct AveRSS x ranks -- never MaxRSS x ranks.
    # MaxRSS is the single heaviest rank; on k-point-parallel runs rank 0 holds the
    # gathered all-k-point arrays and dwarfs every other rank, so sizing from it
    # over-reserves by the whole imbalance factor.
    #   Measured 2026-08-05, KPAR=63 DOS run (63 ranks, 1 node):
    #     MaxRSS 7822 MB/rank  vs  AveRSS 1214 MB/rank   -> imbalance x6.4
    #     sized from MaxRSS: 9700 MB/cpu x 63 = 611 GB reserved for 76 GB used (12.5%)
    #     sized from AveRSS: 1500 MB/cpu x 63 =  94 GB reserved for 76 GB used (81%)
    #   (vasp-recommend had predicted 1166 MB/rank -- within 4% of the truth. The
    #    MaxRSS-based "refinement" is what broke it, not the a-priori model.)
    #   AveRSS is a mean over the very ranks MaxRSS is the max of, so AveRSS <= MaxRSS
    #   is an invariant. sacct can break it by reporting the two fields in different
    #   units (seen 2026-08-12: MaxRSS "576512K", AveRSS raw bytes -> AveRSS parsed
    #   1024x high, and the whole job was then sized at 554 GB/rank). Never trust an
    #   AveRSS above MaxRSS; fall back to MaxRSS, which is an upper bound.
    averss_mb = args.averss_mb
    if averss_mb > args.maxrss_mb > 0:
        averss_mb = 0.0
    anchor_mb = averss_mb if averss_mb > 0 else args.maxrss_mb
    rss_imbalance = (args.maxrss_mb / averss_mb) if averss_mb > 0 else 0.0
    per_rank, corr = make_estimator(anchor_mb, mem, args.ntasks_test,
                                    max(args.test_npar, 1), max(args.test_ncore, 1))

    # Per-rank memory at the PRODUCTION layout, scaled from the measurement.
    flat_use = per_rank(args.prod_ranks, max(args.prod_npar, 1),
                        max(args.prod_ncore, 1))
    # PLAUSIBILITY BACKSTOP. The measurement normally beats the a-priori model, which
    # is why we benchmark at all -- but real under-predictions are ~1.5-3x (the model
    # misses MPI/scaLAPACK/FFT/allocator overhead), never orders of magnitude. A
    # measurement 10x above the physics-based estimate is an ACCOUNTING artifact, not
    # physics (2026-08-12: sacct unit mismatch made AveRSS 1024x high -> the job was
    # sized at 554 GB/rank against a 1791 MB/rank model and laid out on 48 nodes at 1
    # rank each). Refuse to size the cluster request from a number the model cannot
    # remotely support; keep the model and say so loudly.
    sanity_note = ""
    if args.pred_peak_mb and flat_use > SANITY_MAX_MODEL_RATIO * args.pred_peak_mb:
        sanity_note = (
            f"measured {flat_use:.0f} MB/rank is x{flat_use/args.pred_peak_mb:.0f} the "
            f"a-priori estimate ({args.pred_peak_mb:.0f} MB) -- implausible for real RSS "
            f"overhead, so it was REJECTED as an accounting artifact and the estimate "
            f"was kept. Check `sacct -j <benchmark> -o MaxRSS,AveRSS`.")
        flat_use = float(args.pred_peak_mb)

    # THE OTHER HALF OF THE BACKSTOP: a measurement of zero, or absurdly below
    # the model.
    #
    # sacct returns an empty MaxRSS more often than it should -- accounting off,
    # a run finishing between samples, a cgroup the gatherer could not read --
    # and an empty field parses as 0. Zero then sailed through as if it were a
    # measurement: the report announced "recommend OVER-estimated the mean rank
    # ~x195", the sizing "trimmed" production to the 200 MB floor, and the
    # DEFINITIVE job script was written with a memory request nobody had
    # measured. That script OOMs on the first real run, and everything above it
    # reads like a successful benchmark.
    #
    # A real over-estimate is a factor of a few. Anything below a tenth of the
    # model -- zero included -- is an accounting artifact, and production keeps
    # the estimate.
    measurement_rejected = False
    if flat_use <= 0 or (args.pred_peak_mb
                         and flat_use < args.pred_peak_mb / SANITY_MAX_MODEL_RATIO):
        _why = ("sacct returned no memory for this job"
                if flat_use <= 0 else
                f"measured {flat_use:.0f} MB/rank is a {args.pred_peak_mb / max(flat_use, 1e-9):.0f}x "
                f"drop from the a-priori estimate ({args.pred_peak_mb:.0f} MB)")
        sanity_note = (
            f"{_why} -- production memory was NOT sized from it. The estimate is "
            f"kept, and it is only an estimate: re-run vasp-test once job "
            f"accounting reports MaxRSS (`sacct -j <benchmark> -o MaxRSS,AveRSS`), "
            f"or size the request by hand.")
        flat_use = float(args.pred_peak_mb or 0.0)
        measurement_rejected = True
        if flat_use <= 0:
            print("ERROR: no measured memory and no prediction to fall back on --",
                  file=sys.stderr)
            print("       refusing to write a production memory request.", file=sys.stderr)
            return 5

    # GW: the short benchmark only reaches the FLAT (DFT-setup) phase -- it NEVER gets
    # to the GW response setup, so its MaxRSS is NOT the GW peak and we must NOT
    # extrapolate from it. The per-rank memory needed to RUN is a FLOOR that is
    # NOMEGA-INDEPENDENT and ~ENCUTGW^3 / ~(1/ranks-per-k-group). We take, in order:
    #   1. VASP's OWN reported requirement (--gw-floor-mb, harvested from a real/failed
    #      run by vasp-diagnose, or parsed from this OUTCAR) -- authoritative;
    #   2. otherwise the anchored floor formula at the production layout.
    # (flat_use is kept for the report as the informational flat phase only.)
    gw_floor = 0.0
    gw_floor_src = ""
    if args.gw:
        rpk_prod = args.prod_ranks / max(1, args.prod_kpar)
        encutgw = _outcar_encutgw(text) or GW_FLOOR_ANCHOR_ENCUTGW
        gw_floor = gw_floor_per_rank_mb(rpk_prod, encutgw)
        gw_floor_src = (f"anchored real-RSS floor ({GW_FLOOR_ANCHOR_MB:.0f} MB @ "
                        f"{GW_FLOOR_ANCHOR_RPK:.0f} ranks/kgrp,{GW_FLOOR_ANCHOR_ENCUTGW:.0f} eV; "
                        f"NOMEGA-independent, ~ENCUTGW^3)")
        # Provision to VASP's OWN printed "min. memory requirement" (no discount).
        vasp_own = _outcar_min_mem_per_rank(text)
        if vasp_own:
            vasp_need = vasp_own * GW_VASP_REQ_TO_RSS
            if vasp_need > gw_floor:
                gw_floor = vasp_need
                gw_floor_src = f"VASP's own required memory {vasp_need:.0f} MB/rank (this OUTCAR)"
        # A harvested per-rank requirement (--gw-floor-mb, from vasp-diagnose) can only
        # push the floor UP, never below the anchored formula. This is the safety net for
        # the case where VASP did NOT print its "min. memory requirement" line and diagnose
        # could only fall back to a CAPPED value (sacct MaxRSS / the cgroup limit): we must
        # not let that under-provision below the anchored formula (7282). max(), not override.
        if args.gw_floor_mb and args.gw_floor_mb > gw_floor:
            gw_floor = args.gw_floor_mb
            gw_floor_src = "harvested per-rank requirement (>= anchored floor)"
        prod_use = gw_floor
    else:
        prod_use = flat_use
    mem_per_cpu, nodes, ntpn = geometry(args.prod_ranks, args.cpus_per_node,
                                        prod_use, args.node_mem_mb,
                                        mem_util=args.mem_util, kpar=args.prod_kpar,
                                        gw_node_frac=(args.gw_node_frac if args.gw else 0.0))
    # GW feasibility at the MEASURED memory: a whole k-group must fit one node. If
    # the real memory makes the group bigger than a node, this config can't run --
    # signal vasp-test to re-pick (it re-invokes recommend, calibrated to prod_use).
    rpk = args.prod_ranks // max(1, args.prod_kpar)
    gw_infeasible = bool(args.gw and
                         (rpk > args.cpus_per_node or rpk * prod_use > args.node_mem_mb))
    per_node_use = ntpn * prod_use / 1024.0
    per_node_req = ntpn * mem_per_cpu / 1024.0
    # MAXMEM = mem-per-cpu - 3 GB (the SWEET/speed-max value for this allocation). The
    # FREEZE (never raise above the INCAR's previous value) applies only when re-sizing
    # AFTER A FAILURE (--gw-floor-mb harvested from a dead run) -- that feedback path is
    # the ratchet. A healthy vasp-test pass is an open-loop policy choice and may raise
    # MAXMEM together with the allocation; the 3 GB gap (> worst measured overhead
    # 2.4 GB) keeps ANY such pair safe. See gw_maxmem_* and the SWEET notes.
    existing_maxmem = _incar_existing_maxmem(args.incar) if args.incar else None
    _freeze = existing_maxmem if (args.gw and args.gw_floor_mb) else None
    maxmem = gw_maxmem_from_request(mem_per_cpu, _freeze)
    if args.gw:
        # the expected use follows MAXMEM (demand = MAXMEM + ~2.1 GB), not the floor
        per_node_use = ntpn * (maxmem + 2100) / 1024.0

    # ------------------------------------------------------------------- #
    # Verdict on the recommended (fixed) parallel config
    # ------------------------------------------------------------------- #
    verdict, advice = [], []
    if args.cpu_eff > 0:
        if args.cpu_eff >= 85:
            verdict.append(f"parallel efficiency GOOD ({args.cpu_eff:.0f}%)")
        elif args.cpu_eff >= 70:
            verdict.append(f"parallel efficiency OK ({args.cpu_eff:.0f}%)")
            advice.append("efficiency is moderate; a different KPAR/NCORE might be faster.")
        else:
            verdict.append(f"parallel efficiency LOW ({args.cpu_eff:.0f}%)")
            advice.append("efficiency is poor; consider re-running vasp-recommend with "
                          "different --nsim-choices, or fewer ranks.")
    fits = mem_per_cpu * ntpn <= args.node_mem_mb
    if fits and nodes == 1:
        verdict.append("memory fits one node")
    elif fits:
        verdict.append(f"memory fits across {nodes} nodes")
        advice.append(f"production memory needs {nodes} nodes ({ntpn} ranks/node) to fit.")
    else:
        verdict.append("memory does NOT fit")
        advice.append("even one node can't hold this; reduce ranks or use a large-mem partition.")
    adequate = (args.cpu_eff == 0 or args.cpu_eff >= 70) and fits and not gw_infeasible
    if gw_infeasible:
        headline = (f"INFEASIBLE -- the MEASURED memory ({prod_use:.0f} MB/rank) makes "
                    f"the KPAR={args.prod_kpar} k-group ({rpk} ranks x {prod_use/1024:.0f} "
                    f"GB = {rpk*prod_use/1024:.0f} GB) bigger than one node "
                    f"({args.node_mem_mb/1024:.0f} GB). Re-picking a feasible config.")
        advice.append("a GW k-group cannot span nodes; vasp-test is re-selecting KPAR "
                      "(and will rewrite INCAR + the benchmark for you to resubmit).")
    else:
        headline = ("ADEQUATE -- the recommended config works; memory updated below."
                    if adequate else
                    "REVIEW -- see the notes; the recommended config may need tuning.")

    # ------------------------------------------------------------------- #
    # Build the STAGE 3 report section
    # ------------------------------------------------------------------- #
    L = []
    L.append("[BENCHMARK -- measured with the FIXED recommended config]")
    L.append(f"  ran at                  : {args.ntasks_test} ranks "
             f"(KPAR={args.test_kpar}, NCORE={args.test_ncore}, NPAR={args.test_npar})")
    L.append(f"  peak memory / rank      : {args.maxrss_mb:.0f} MB   (SLURM MaxRSS, "
             f"heaviest single rank)")
    if averss_mb > 0:
        L.append(f"  mean memory / rank      : {averss_mb:.0f} MB   (SLURM AveRSS) "
                 f"<- SIZES THE REQUEST")
        if rss_imbalance >= 1.5:
            L.append(f"  rank imbalance          : x{rss_imbalance:.1f}  (one rank -- usually "
                     f"rank 0 with the gathered")
            L.append(f"                            all-k-point arrays -- dominates. The node "
                     f"total SLURM")
            L.append(f"                            enforces is mean x ranks, so MaxRSS would "
                     f"over-reserve x{rss_imbalance:.1f}.)")
    else:
        L.append("  mean memory / rank      : (AveRSS unavailable -- sized from MaxRSS, "
                 "conservative)")
    if sanity_note:
        L.append("  !! MEASUREMENT REJECTED  : " + sanity_note.split(" -- ")[0])
        for _seg in sanity_note.split(" -- ")[1:]:
            L.append(f"                            {_seg}")
    if args.cpu_eff > 0:
        L.append(f"  CPU efficiency          : {args.cpu_eff:.1f} %")
    if args.avg_loop > 0:
        L.append(f"  wall per SCF step       : {args.avg_loop:.2f} s  "
                 f"({args.nscf} steps in {args.wall}s)")
    if mem["total"] > 0 and corr:
        L.append(f"  VASP table / measured   : x{corr:.2f}  (real RSS vs VASP's table)")
    L.append("")
    L.append(f"[PRODUCTION -- the FIXED config at {args.prod_ranks} ranks]")
    L.append(f"  KPAR / NCORE / NPAR     : {args.prod_kpar} / {args.prod_ncore} / {args.prod_npar}")
    L.append(f"  NSIM                    : {args.prod_nsim}")
    L.append(f"  layout                  : {nodes} node(s) x {ntpn} ranks-per-node "
             f"on '{args.prod_partition}'")
    L.append("")
    L.append("[MEMORY -- GW per-rank FLOOR, sized to the utilisation rule]"
             if args.gw else
             "[MEMORY -- measured, scaled to production, sized to the 80% rule]")
    if args.gw:
        L.append(f"  flat phase (benchmark)  : {flat_use:.0f} MB/rank  (DFT-setup only -- "
                 f"NOT the GW peak; informational)")
        L.append(f"  per-rank FLOOR (used)   : {prod_use:.0f} MB  (rpk="
                 f"{args.prod_ranks // max(1, args.prod_kpar)}; {gw_floor_src})")
    else:
        _src = "AveRSS" if averss_mb > 0 else "MaxRSS"
        L.append(f"  predicted use / rank    : {prod_use:.0f} MB  "
                 f"(mean/rank from {_src}, scaled {args.ntasks_test}->{args.prod_ranks} ranks)")
        L.append(f"  => node total           : {prod_use * ntpn / 1024.0:.0f} GB  "
                 f"({ntpn} ranks x {prod_use:.0f} MB) -- what SLURM enforces")
    _need_req = round_up(prod_use / max(args.mem_util, 0.05))
    if args.gw and mem_per_cpu > _need_req:
        L.append(f"  --mem-per-cpu (request) : {mem_per_cpu} MB  (SWEET: "
                 f"{args.gw_node_frac:.0%} of the node / {ntpn} ranks; need alone was "
                 f"{_need_req} -- the extra buys MAXMEM batching speed)")
    else:
        L.append(f"  --mem-per-cpu (request) : {mem_per_cpu} MB  "
                 f"(= {prod_use:.0f} / {args.mem_util:.2f})")
    if args.gw:
        _mm_how = (f"FROZEN at the previous run's {existing_maxmem}"
                   if _freeze and maxmem == existing_maxmem
                   else f"SWEET = mem-per-cpu - {GW_MAXMEM_OVERHEAD_MB}"
                        + (f", LOWERED from {existing_maxmem}" if existing_maxmem
                           and existing_maxmem > maxmem else ""))
        L.append(f"  MAXMEM for the INCAR    : {maxmem} MB/rank  ({_mm_how})")
        _dem = maxmem + 2100
        L.append(f"  expected VASP demand    : ~{_dem} MB/rank (= MAXMEM + ~2.1 GB law) "
                 f"-> ~{100.0 * _dem / max(mem_per_cpu, 1):.0f}% of the allocation")
    # Report the utilisation this request ACTUALLY achieves, not just the target it
    # aimed at: rounding mem-per-cpu UP to a 50 MB step always lands a point or two
    # below the target (671/0.81 = 828 -> 850 -> 78.9%, not 81%). Claiming ">= 81%"
    # while delivering 78.9% is how the report earns distrust it doesn't deserve.
    _ach = 100.0 * per_node_use / max(per_node_req, 1e-9)
    L.append(f"  per node                : {per_node_use:.0f} GB used of "
             f"{per_node_req:.0f} GB requested  ({_ach:.0f}% utilisation; "
             f"target >= {args.mem_util*100:.0f}%, the rest is the OOM safety margin)")
    if args.gw:
        L.append("")
        L.append("  NOTE -- the GW per-rank FLOOR is NOMEGA-INDEPENDENT and ~ENCUTGW^3.")
        L.append("     The short benchmark cannot measure it (it never reaches the GW response")
        L.append("     setup), so it is VASP's own reported requirement when available, else an")
        L.append("     anchored floor. If the first real run still OOMs, the fix is NOT a bigger")
        L.append("     MAXMEM -- it is FEWER ranks/node (more nodes) or a lower ENCUTGW. Harvest")
        L.append("     VASP's printed requirement from the failed run and re-size from that.")
    L.append("")
    L.append(f"[VERDICT]  {headline}")
    for v in verdict:
        L.append(f"  - {v}")
    for a in advice:
        L.append(f"  ! {a}")

    # ---- PREDICTED (recommend) vs MEASURED (vasp-test) ------------------ #
    # Show, sector by sector, where vasp-recommend's ESTIMATE was accurate and where
    # it was off, then a final validation of the chosen parallelization + node config.
    def _cmp(pred, meas):
        """Compare a prediction with a measurement, or say why we cannot.

        Both sides have to be present and positive. A MEASUREMENT of zero is
        not a measurement of nothing -- it is sacct having returned no MaxRSS
        at all (job accounting off, a run too short for the sampler, a cgroup
        the sampler could not read). Dividing by it raised ZeroDivisionError
        and took the whole predicted-vs-measured section down with it, so the
        report simply had no comparison in it and nothing said why.
        """
        try:
            pred = float(pred or 0.0)
            meas = float(meas or 0.0)
        except (TypeError, ValueError):
            return "n/a (unreadable)"
        if pred <= 0:
            return "n/a (nothing predicted)"
        if meas <= 0:
            return "NOT MEASURED (sacct returned no value)"
        r = meas / pred
        if 0.83 <= r <= 1.20:
            return f"ACCURATE (x{r:.2f})"
        return f"UNDER-predicted x{r:.2f}" if r > 1 else f"OVER-predicted /{1 / r:.2f}"

    if args.cpu_eff == 0:
        par_verdict = "VALIDATED (ran; no efficiency metric)"
    elif gw_infeasible:
        par_verdict = "NEEDS RE-PICK (measured memory infeasible -- see above)"
    elif args.cpu_eff >= 85:
        par_verdict = f"VALIDATED (parallel efficiency {args.cpu_eff:.0f}%)"
    elif args.cpu_eff >= 70:
        par_verdict = f"OK but not optimal (efficiency {args.cpu_eff:.0f}%)"
    else:
        par_verdict = f"POOR (efficiency {args.cpu_eff:.0f}% -- consider another KPAR/NCORE)"
    pred_layout = f"{args.pred_nodes}x{args.pred_ntpn}" if args.pred_nodes else "n/a"
    meas_layout = f"{nodes}x{ntpn}"
    layout_verdict = "confirmed" if pred_layout == meas_layout else "REFINED from benchmark"

    L.append("")
    L.append("[PREDICTED vs MEASURED]  (how accurate vasp-recommend's estimate was)")
    L.append("  sector                 recommend       vasp-test       verdict")
    # NO "flat / base per rank" ROW. It used to print recommend's base+one-center
    # SECTOR (~30 MB) against the measured per-rank TOTAL (~671 MB) and duly reported
    # "UNDER-predicted x22" on a run whose total was predicted to 0.4%. sacct returns
    # ONE number per rank and cannot be decomposed into VASP's sectors, so there is no
    # measured flat value to compare with -- the row could only ever mislead.
    if args.pred_peak_mb:
        _peak_label = "per-rank FLOOR" if args.gw else "peak per rank "
        if measurement_rejected:
            # prod_use IS the estimate here, because the measurement was thrown
            # out. Printing _cmp(estimate, estimate) would score it "ACCURATE
            # (x1.00)" -- the estimate validating itself, which is the most
            # misleading thing this table could say.
            L.append(f"  {_peak_label}        {args.pred_peak_mb:>9.0f} MB   "
                     f"{'--':>9}      NOT MEASURED (estimate kept; see above)")
        else:
            L.append(f"  {_peak_label}        {args.pred_peak_mb:>9.0f} MB   {prod_use:>9.0f} MB   "
                     f"{_cmp(args.pred_peak_mb, prod_use)}")
    if args.pred_mem_per_cpu:
        L.append(f"  mem-per-cpu (request) {args.pred_mem_per_cpu:>9.0f} MB   {mem_per_cpu:>9.0f} MB   "
                 f"{_cmp(args.pred_mem_per_cpu, mem_per_cpu)}")
    L.append(f"  KPAR/NCORE/NPAR       {args.prod_kpar}/{args.prod_ncore}/{args.prod_npar:<7}      "
             f"{args.prod_kpar}/{args.prod_ncore}/{args.prod_npar:<7}      {par_verdict}")
    L.append(f"  nodes x ranks/node    {pred_layout:>12}   {meas_layout:>12}   {layout_verdict}")

    L.append("")
    L.append("[VALIDATION OF THE CHOSEN PARALLELIZATION + NODE CONFIG]")
    L.append(f"  parallelization  : KPAR={args.prod_kpar} NCORE={args.prod_ncore} "
             f"NPAR={args.prod_npar}  ->  {par_verdict}")
    L.append(f"  node config      : recommend {pred_layout} @ {args.pred_mem_per_cpu:.0f} MB/cpu "
             f"->  vasp-test {meas_layout} @ {mem_per_cpu} MB/cpu  ({layout_verdict})")
    if measurement_rejected:
        L.append("  memory accuracy  : NOT ASSESSED -- there was no usable measurement, so "
                 "nothing here")
        L.append("                     validates the estimate. slurm_vasptest.sh carries the "
                 "ESTIMATE,")
        L.append("                     not a measured value. Treat its memory request as "
                 "provisional.")
    elif args.pred_peak_mb and prod_use / max(args.pred_peak_mb, 1) > 1.2:
        L.append(f"  memory accuracy  : recommend UNDER-estimated the mean rank ~x"
                 f"{prod_use/args.pred_peak_mb:.1f} (its formula misses real-RSS overhead: "
                 f"MPI/scaLAPACK/FFT/allocator). vasp-test's MEASURED value is authoritative")
        L.append("                     and is what slurm_vasptest.sh now uses.")
    elif args.pred_peak_mb and prod_use / max(args.pred_peak_mb, 1) < 0.8:
        L.append(f"  memory accuracy  : recommend OVER-estimated the mean rank ~x"
                 f"{args.pred_peak_mb/max(prod_use,1):.1f}; the measurement trims the request.")
    elif args.pred_peak_mb:
        L.append(f"  memory accuracy  : recommend's estimate was within ~"
                 f"{abs(prod_use/args.pred_peak_mb-1)*100:.0f}% of the measured mean rank.")
    if rss_imbalance >= 1.5:
        _naive = round_up(args.maxrss_mb / max(args.mem_util, 0.05))
        L.append(f"  imbalance guard  : sizing from MaxRSS ({args.maxrss_mb:.0f} MB) would have "
                 f"requested {_naive} MB/cpu")
        L.append(f"                     = {_naive * ntpn / 1024.0:.0f} GB/node instead of "
                 f"{mem_per_cpu * ntpn / 1024.0:.0f} GB -- x{_naive/max(mem_per_cpu,1):.1f} "
                 f"over-reservation avoided.")

    body = "\n".join(L)

    print(body)

    if args.report:
        bar = "#" * 78
        import datetime as _dt
        section = (f"\n{bar}\n#  STAGE 3/3 -- BENCHMARK + FINAL MEMORY (vasp-test)\n"
                   f"#  {_dt.datetime.now():%Y-%m-%d %H:%M:%S}\n{bar}\n\n{body}\n")
        try:
            with open(args.report, "a") as fh:
                fh.write(section)
        except OSError:
            pass

    if gw_infeasible:
        # Do NOT write the definitive job. Emit a machine-readable line so vasp-test
        # can re-invoke recommend calibrated to the measured memory, then return a
        # distinct code (7) so the caller knows to re-pick + resubmit.
        print(f"\nWP_REPICK measured_mb={prod_use:.0f} ref_ranks={args.prod_ranks} "
              f"ref_kpar={args.prod_kpar}")
        return 7

    if args.update_slurm and update_slurm(args.update_slurm, mem_per_cpu, nodes, ntpn):
        print(f"\n[FILES] updated production memory in {args.update_slurm} "
              f"-> --mem-per-cpu={mem_per_cpu}, --nodes={nodes}, "
              f"--ntasks-per-node={ntpn}")
    if args.gw and args.incar and write_incar_maxmem(args.incar, maxmem):
        print(f"[FILES] wrote MAXMEM={maxmem} into {args.incar} (backup INCAR.bak)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
