#!/usr/bin/env python3
"""
vasp_recommend_slurm.py   (command: vasp-recommend-slurm)
========================================================

VASP parallelization recommender for SLURM clusters, rewritten from the
official VASP documentation.  The goal is to give configurations that (a)
follow the rules documented on https://vasp.at/wiki and (b) come with an honest
per-MPI-rank memory prediction so that the SLURM script you submit will
actually fit in the partition you target.

CLUSTER PROFILE
  The partition names, cores/node, memory/node, the module-load lines for your
  chosen VASP build, the notification email and the account core cap are read
  from the per-user profile written by `vasp-configure`
  (~/.config/wolfpack-dft/cluster.conf).  Without a profile, a built-in set of
  example partitions below is used as a sensible default.

Authoritative references (all consulted while writing this script):

  * https://vasp.at/wiki/Optimizing_the_parallelization
  * https://vasp.at/wiki/Category:Parallelization
  * https://vasp.at/wiki/NCORE
  * https://vasp.at/wiki/NPAR
  * https://vasp.at/wiki/KPAR
  * https://vasp.at/wiki/NSIM
  * https://vasp.at/wiki/LPLANE
  * https://vasp.at/wiki/Memory_requirements
  * https://vasp.at/wiki/Not_enough_memory
  * https://vasp.at/wiki/Performance_issues,_try_NCORE,_KPAR,_ALGO,_LREAL
  * https://docs.nersc.gov/applications/vasp/           (memory scaling, OUTCAR)

================================================================================
WHAT THIS REWRITE FIXES COMPARED TO THE OLD TOOL
================================================================================

1. Memory prediction is now anchored to VASP itself.
   ----------------------------------------------------------------------------
   The dry-run OUTCAR contains an authoritative memory table written by VASP:

       total amount of memory used by VASP MPI-rank0  457796. kBytes
       =======================================================================
         base      :  30000. kBytes
         nonlr-proj:  12085. kBytes
         fftplans  :  29652. kBytes
         grid      :  54584. kBytes
         one-center:    211. kBytes
         wavefun   : 331264. kBytes

   This is the per-rank memory VASP would actually use under the layout used
   for the dry run.  The new tool parses this table and rescales each line
   to the candidate (NCORE, NPAR, KPAR) layout using the distribution rules
   from the VASP wiki:

       wavefun     scales as 1 / total_ranks
                   (orbitals fully distributed across NPAR*NCORE*KPAR)
       grid        scales as 1 / NPAR
                   (z-slab distribution with LPLANE; replicated per k-group
                    so KPAR does NOT reduce per-rank grid memory)
       nonlr-proj  scales as 1 / NCORE
                   (PAW projectors are distributed across the band group)
       fftplans, base, one-center: ~ constant per rank
       scaLAPACK NBANDS^2 workspace: NBANDS^2 * 16 * KPAR / total_ranks
                   (distributed within the k-group; KPAR REPLICATES it)

   If the OUTCAR does not have a memory table (older builds, very short
   aborts), the tool falls back to the formulas given on
   https://vasp.at/wiki/Memory_requirements .

2. NCORE > 1 is now allowed (and often preferred).
   ----------------------------------------------------------------------------
   The VASP wiki explicitly states:

       "On massively parallel systems and modern multi-core machines we
        strongly recommend to set  NCORE = 2 up to number-of-cores-per-socket
        (or number-of-cores-per-node)."           (NCORE wiki page)

   and

       "Setting NCORE equal to the number of cores per NUMA domain is often
        a particularly good choice."              (NCORE wiki page)

   The old tool hard-coded NCORE = 1.  That follows a common SLURM template
   verbatim but contradicts the upstream VASP recipe and, for >100 atoms,
   leaves a factor-of-up-to-four performance on the table.  This rewrite
   enumerates NCORE in {1, 2, ..., min(cores_per_node, NUMA-size*2)} and
   lets the scoring choose.  The SLURM script still emits OMP_NUM_THREADS=1
   and --cpus-per-task=1, so the result is still pure MPI; only the INCAR's
   NCORE knob changes.

3. Special case for bulk systems with small unit cells.
   ----------------------------------------------------------------------------
   Per the VASP wiki: "For bulk systems with small unit cells (NBANDS is
   small, NKPTS is large), NCORE=1 and KPAR=NKPTS is optimal."  The scoring
   recognises this and gives that exact configuration a large bonus.

4. The parallelization identity is enforced correctly.
   ----------------------------------------------------------------------------
   The VASP wiki defines

           total_ranks = (ranks parallelising bands) * NCORE * KPAR * IMAGES
           NPAR        = (total_ranks / KPAR) / NCORE          (with IMAGES=1)

   The old tool had NPAR * KPAR ~ total_ranks (i.e. it silently fixed
   NCORE=1).  This rewrite uses the full identity NPAR*NCORE*KPAR = total
   and enumerates the divisor lattice properly.

5. The dry-run's actual NPAR/NCORE/KPAR are now parsed.
   ----------------------------------------------------------------------------
   VASP writes two unambiguous lines into the dry-run OUTCAR header:

       distrk: each k-point on   1 cores,    1 groups
       distr:  one band on  NCORE=   1 cores,    1 groups

   The first tells us KPAR_dry (number of k-point groups) and the rank count
   per k-group; the second gives NCORE_dry and NPAR_dry (number of band
   groups).  Without these we cannot rescale the memory table.

================================================================================
HOW TO USE THIS SCRIPT
================================================================================

Step 1 -- generate a dry-run OUTCAR
-----------------------------------
In your calculation directory with valid INCAR/POSCAR/POTCAR/KPOINTS, add
ALGO=None temporarily (or use the --dry-run command-line option of VASP),
then run VASP for a few seconds on any number of ranks (1 is fine):

    cp INCAR INCAR.production
    echo 'ALGO = None' >> INCAR
    srun -n 1 vasp_std         # ranks here only set the memory table layout
    cp OUTCAR dryrun_OUTCAR
    mv INCAR.production INCAR

A dry run on 1 rank is the most informative because it reports the FULL
arrays before any distribution; from that the tool can predict per-rank
memory for any candidate (KPAR, NCORE, NPAR) you might consider.

Step 2 -- run the recommender
-----------------------------
    python3 vasp_recommend_slurm.py dryrun_OUTCAR

That prints (a) the dry-run summary, (b) the top candidates table, and
(c) a ready-to-submit SLURM script for the best one.

Useful flags
------------
    --partition {main,debug,general,largemem}     default: main
    --max-cores N        account-wide MPI-rank cap (default 120)
    --min-cores N        smallest total_ranks to evaluate (default 8)
    --mem-headroom F     safety multiplier on memory estimate (default 1.15)
    --cores-per-node N   override the partition's CPUs-per-node
    --numa-cores N       override the NUMA-domain core count (for NCORE tuning)
    --top N              how many rows to print (default 10)
    --csv FILE           write the full ranked list as CSV
    --email user@host    inserted into the SLURM script
    --job-name NAME      SLURM --job-name (default: VASP)
    --executable EXE     force the VASP binary (else WP_VASP_STD/WP_VASP_GAM from
                         vasp-configure, else auto vasp_std/vasp_gam from the OUTCAR)
    --time D-HH:MM:SS    SLURM time limit (default: 7-00:00:00)
    --calc-type {auto,dft,gw,gw-low,rpa-low}
                         override automatic DFT/GW/RPA detection (default: auto)
    --nomega N           override NOMEGA parsed from OUTCAR (for GW grid split)
    --no-maxmem          suppress MAXMEM from the generated INCAR snippet
    --gw-mem-per-rank MB override the empirical GW per-rank anchor (MB)
    --gw-ref-ranks N     override the reference rank count used for GW scaling
    --gw-ref-encutgw EV  override the reference ENCUTGW used for GW scaling
    --strict-ncore-one   force NCORE=1 (strict legacy recipe; not recommended)
    --allow-kpar-above-irr  permit KPAR > NKPTS (off by default per wiki)
    --nsim-choices 1 2 4 8  enumerate these NSIM values (default 4 only; CPU)

================================================================================
PHILOSOPHICAL NOTE
================================================================================
This is still a candidate generator, not a proof of optimality.  The
official VASP recipe (https://vasp.at/wiki/Optimizing_the_parallelization)
remains: "Run a few test calculations varying the parallel setup and use
the optimal choice of parameters for the rest of the calculations."  Use
the top 2-3 candidates this tool prints as your starting point for a short
benchmark, then commit to the fastest.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wolfpack_geometry import node_layout   # noqa: E402
from typing import Dict, List, Optional, Sequence, Tuple


# ============================================================================
# Example partition catalogue (overridden by vasp-configure)
# ============================================================================
# Example numbers for a typical AMD/Intel SLURM cluster; override them with
# vasp-configure. ``mem_per_cpu_mb`` is the per-CPU RAM the scheduler grants.
# ``numa_cores`` is the typical NUMA-domain size; if you care about the
# exact number, run ``lstopo`` or ``numactl --hardware`` on a compute node
# and override with --numa-cores.
CLUSTER_PARTITIONS: Dict[str, Dict[str, object]] = {
    # -- AMD Zen4 (Genoa) partitions --------------------------------------
    "main": {
        "cpus_per_node": 256,
        "mem_per_cpu_mb": 2839,
        "numa_cores": 16,
        "arch": "amd-zen4",
        # Empty on purpose: a module list belongs to a site, and guessing one
        # loads a VASP the user did not choose. vasp-configure fills it in.
        "modules": [],
        "extra_env": [
            "export OMPI_MCA_mtl=ofi",
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
        ],
    },
    "debug": {
        "cpus_per_node": 48,
        "mem_per_cpu_mb": 7600,
        "numa_cores": 24,
        "arch": "amd-zen4",
        # Empty on purpose: a module list belongs to a site, and guessing one
        # loads a VASP the user did not choose. vasp-configure fills it in.
        "modules": [],
        "extra_env": [
            "export OMPI_MCA_mtl=ofi",
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
        ],
    },
    # -- Intel partitions --------------------------------------------------
    "general": {
        "cpus_per_node": 44,
        "mem_per_cpu_mb": 4200,
        "numa_cores": 22,
        "arch": "intel",
        "modules": [
            "ml purge",
            "ml intel/2022.00",
            "ml VASP/6.3.2",
        ],
        "extra_env": [
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
            "export MKL_DYNAMIC=FALSE",
        ],
    },
    "largemem": {
        "cpus_per_node": 44,
        "mem_per_cpu_mb": 16500,
        "numa_cores": 22,
        "arch": "intel",
        "modules": [
            "ml purge",
            "ml intel/2022.00",
            "ml VASP/6.3.2",
        ],
        "extra_env": [
            "export OMP_NUM_THREADS=1",
            "export MKL_NUM_THREADS=1",
            "export MKL_DYNAMIC=FALSE",
        ],
    },
}


# ============================================================================
# Data classes
# ============================================================================


@dataclass
class MemoryBreakdown:
    """The 'total amount of memory used by VASP MPI-rank0' table, in MB.

    All values are MB (the OUTCAR reports kBytes; we convert at parse time).
    A field is None when the dry-run OUTCAR does not contain the table.
    """
    base_mb: Optional[float] = None
    nonlr_proj_mb: Optional[float] = None
    fftplans_mb: Optional[float] = None
    grid_mb: Optional[float] = None
    one_center_mb: Optional[float] = None
    wavefun_mb: Optional[float] = None
    total_mb: Optional[float] = None        # the headline number from OUTCAR

    def has_data(self) -> bool:
        """True if the dry run captured the data needed to size the job."""
        return self.total_mb is not None


@dataclass
class DryRunSummary:
    """Quantities parsed from a previous VASP dry-run OUTCAR."""
    outcar_path: Path

    # --- System / electronic structure ---
    irr_kpoints: Optional[int] = None    # number of irreducible k-points
    nkpts: Optional[int] = None          # NKPTS as printed by VASP
    nbands: Optional[int] = None
    nions: Optional[int] = None
    nelect: Optional[float] = None
    ispin: int = 1
    nplwv: Optional[int] = None          # max plane waves over all k-points
    coarse_fft: Optional[Tuple[int, int, int]] = None   # NGX, NGY, NGZ
    fine_fft: Optional[Tuple[int, int, int]] = None     # NGXF, NGYF, NGZF
    is_gamma_only: bool = False
    is_noncollinear: bool = False

    # --- Algorithm settings (informational) ---
    algo: Optional[str] = None
    lreal: Optional[str] = None
    encut: Optional[float] = None

    # --- GW / RPA detection and tags ---
    # calc_type is one of: "DFT", "GW_CONVENTIONAL", "GW_LOWSCALING",
    # "RPA_LOWSCALING".  See detect_calculation_type().
    calc_type: str = "DFT"
    gw_algo: Optional[str] = None        # the ALGO string that triggered GW/RPA
    nomega: Optional[int] = None         # NOMEGA: number of (imaginary) frequencies
    nelmgw: Optional[int] = None         # NELMGW / (NELM for GW in 6.2 and older)
    encutgw: Optional[float] = None      # ENCUTGW: response-function cutoff
    nbandsgw: Optional[int] = None       # NBANDSGW: bands updated in self-consistency
    ntaupar_dry: Optional[int] = None    # NTAUPAR found in the OUTCAR (if any)
    nomegapar_dry: Optional[int] = None  # NOMEGAPAR found in the OUTCAR (if any)
    # Low-scaling-specific FFT grids (printed by VASP for space-time GW/RPA):
    #   "FFT grid for exact exchange (Hartree Fock)"  -> fft_exx
    #   "FFT grid for supercell:"                      -> fft_supercell
    fft_exx: Optional[Tuple[int, int, int]] = None
    fft_supercell: Optional[Tuple[int, int, int]] = None
    # VASP's own printed low-scaling estimate, if present in the OUTCAR:
    #   "min. memory requirement per mpi rank 1234 MB, per node 9872 MB"
    vasp_min_mem_per_rank_mb: Optional[float] = None
    vasp_min_mem_per_node_mb: Optional[float] = None

    # --- Parallel layout the DRY RUN itself used ---
    # These are essential for rescaling the memory table.
    dry_total_ranks: Optional[int] = None
    dry_kpar: Optional[int] = None
    dry_ncore: Optional[int] = None
    dry_npar: Optional[int] = None

    # --- Memory table reported by VASP for the dry-run layout ---
    memory: MemoryBreakdown = field(default_factory=MemoryBreakdown)


@dataclass
class MemoryEstimate:
    """Per-rank and per-job memory estimate, all in MB."""
    wavefun_mb: float = 0.0
    grid_mb: float = 0.0
    nonlr_proj_mb: float = 0.0
    fftplans_mb: float = 0.0
    base_mb: float = 0.0
    one_center_mb: float = 0.0
    scalapack_mb: float = 0.0
    safety_mb: float = 0.0

    per_rank_mb: float = 0.0
    total_job_mb: float = 0.0
    suggested_mem_per_cpu_mb: int = 0

    partition_mem_per_cpu_mb: int = 0
    fits_partition: bool = True

    model: str = "fallback"   # "rescaled-from-outcar" or "fallback-formulas"

    # --- Low-scaling GW/RPA extras (filled only for space-time GW/RPA) ---
    # The dominant low-scaling term: (Green's function + polarizability) on
    # the imaginary-time/-frequency grids.  See estimate_lowscaling_gw_memory.
    gw_grid_term_mb: float = 0.0         # per-rank cost of the imaginary-grid arrays
    gw_per_node_mb: float = 0.0          # per-node requirement (per_rank * ranks/node)
    maxmem_mb: int = 0                   # MAXMEM value we recommend putting in the INCAR
    gw_grid_source: str = ""             # "outcar-grids", "fine-fft-proxy", or "unknown"


@dataclass
class Candidate:
    """A complete (total_ranks, KPAR, NCORE, NPAR, NSIM, LPLANE) recipe."""
    score: float
    total_ranks: int
    kpar: int
    ncore: int
    npar: int
    nsim: int
    lplane: bool
    ranks_per_kgroup: int           # = total_ranks / KPAR = NPAR * NCORE
    bands_per_group: float          # = NBANDS / NPAR
    effective_nbands: int           # NBANDS rounded up to multiple of NPAR
    nodes: int
    ntasks_per_node: int
    cpu_bind: str
    memory: MemoryEstimate
    contributions: Dict[str, float] = field(default_factory=dict)
    reasons: List[str] = field(default_factory=list)

    # --- GW / RPA extras (defaults keep DFT candidates unchanged) ---
    calc_type: str = "DFT"
    nomega: Optional[int] = None       # echoed from the dry run, for the INCAR comment
    ntaupar: Optional[int] = None      # low-scaling: imaginary-time grid groups
    nomegapar: Optional[int] = None    # low-scaling: imaginary-frequency grid groups
    recommend_maxmem: bool = False     # whether the INCAR snippet should set MAXMEM

    @property
    def sort_key(self) -> Tuple[float, int, int, int]:
        """Highest score first; tie-break by larger total_ranks then KPAR."""
        return (-self.score, -self.total_ranks, -self.kpar, -self.ncore)

    @property
    def incar_snippet(self) -> str:
        """Return the INCAR parallelization snippet for this candidate's calc type."""
        if self.calc_type == "DFT":
            return self._incar_snippet_dft()
        if self.calc_type == "GW_CONVENTIONAL":
            return self._incar_snippet_gw_conventional()
        # GW_LOWSCALING or RPA_LOWSCALING
        return self._incar_snippet_gw_lowscaling()

    def _incar_snippet_dft(self) -> str:
        """INCAR snippet for a standard DFT / hybrid run."""
        return (
            "# --- Parallelization (VASP wiki recipe; pure MPI) ---\n"
            f"KPAR   = {self.kpar}\n"
            f"NCORE  = {self.ncore}\n"
            f"NSIM   = {self.nsim}\n"
            f"LPLANE = {format_bool(self.lplane)}\n"
            f"# Derived only: NPAR = {self.npar}  (do NOT set BOTH NCORE and NPAR)\n"
            "#\n"
            "# I/O hygiene -- COMMENTED OUT ON PURPOSE. Uncomment only for a\n"
            "# one-shot run you will never restart.\n"
            "#\n"
            "# vasp-chain restarts every chunk from the previous one: it sets\n"
            "# ISTART = 1 (continue from the previous chunk's WAVECAR). Turning\n"
            "# LWAVE off deletes exactly that file, so the chain silently starts\n"
            "# each chunk from scratch and burns the walltime it was meant to save.\n"
            "# LCHARG = .FALSE. does the same to a CHGCAR-based restart.\n"
            "# LVTOT is safe to leave off unless you want the local potential.\n"
            "# LWAVE  = .FALSE.\n"
            "# LCHARG = .FALSE.\n"
            "LVTOT  = .FALSE."
        )

    def _incar_snippet_gw_conventional(self) -> str:
        # Conventional (quartic-scaling) GW parallelizes ONLY over k-points.
        # NCORE / NPAR > 1 do not help the GW step itself, so we pin NCORE = 1
        # and drive everything through KPAR.
        # https://vasp.at/wiki/Practical_guide_to_GW_calculations
        """INCAR snippet for a conventional (cubic-scaling) GW run."""
        rpk = self.ranks_per_kgroup
        maxmem = self.memory.maxmem_mb
        maxmem_line = ""
        if self.recommend_maxmem and maxmem > 0:
            maxmem_line = (
                f"MAXMEM = {maxmem}   # MB/rank, FROZEN budget = mem-per-cpu - ~3 GB overhead room.\n"
                "#                VASP fills whatever MAXMEM it gets and USES ~MAXMEM + ~2 GB, so a\n"
                "#                bigger MAXMEM = a hungrier job (never raise it to fix an OOM --\n"
                "#                the pipeline keeps it FROZEN across relaunches). To CUT memory:\n"
                "#                lower ENCUTGW, or spread the same ranks over MORE NODES. An OOM is\n"
                "#                fixed by raising mem-per-cpu AROUND the frozen MAXMEM, not MAXMEM.\n"
            )
        return (
            "# --- Parallelization: CONVENTIONAL (quartic-scaling) GW ---\n"
            "# GW parallelizes only over k-points -> KPAR is the lever; NCORE = 1.\n"
            f"KPAR  = {self.kpar}    # k-point groups (divisor of NKPTS)\n"
            "NCORE = 1     # REQUIRED for the GW step (no band-FFT distribution)\n"
            f"# Each k-point group gets {rpk} rank(s); they parallelize the\n"
            "# internal DFT/Exact diagonalization. Do NOT set NPAR for GW.\n"
            + maxmem_line +
            "# GW essentials (keep consistent with your DFT/Exact pre-step):\n"
            "ISMEAR = 0 ; SIGMA = 0.05   # small SIGMA to avoid partial occupancies\n"
            "# LOPTICS = .TRUE.          # insulators/semiconductors; OMIT for metals\n"
            "# I/O: keep WAVECAR/WAVEDER from the DFT step; do not delete them."
        )

    def _incar_snippet_gw_lowscaling(self) -> str:
        # Low-scaling (space-time) GW/RPA: the imaginary-grid split via
        # NTAUPAR / NOMEGAPAR is the lever. VASP strongly recommends setting
        # MAXMEM and letting it pick NTAUPAR/NOMEGAPAR automatically.
        # https://vasp.at/wiki/Practical_guide_to_GW_calculations
        # https://vasp.at/wiki/NTAUPAR  https://vasp.at/wiki/NOMEGAPAR
        """INCAR snippet for a low-scaling (space-time) GW/RPA run."""
        is_rpa = self.calc_type == "RPA_LOWSCALING"
        head = "LOW-SCALING RPA" if is_rpa else "LOW-SCALING (space-time) GW"
        maxmem = self.memory.maxmem_mb
        nomega_cmt = (f"  # NOMEGA = {self.nomega} (must be divisible by both)"
                      if self.nomega else "")
        lines = [
            f"# --- Parallelization: {head} ---",
            "# Primary lever: the imaginary time/frequency grid split.",
            "# VASP recommends setting MAXMEM and letting it choose NTAUPAR/NOMEGAPAR.",
            f"KPAR     = {self.kpar}     # k-point groups (divisor of NKPTS)",
            "NCORE    = 1      # leave band-FFT distribution off; use the grid split",
        ]
        if self.recommend_maxmem and maxmem > 0:
            lines += [
                f"MAXMEM   = {maxmem}   # MB available to ONE mpi rank on a node;",
                "#                       VASP auto-selects NTAUPAR/NOMEGAPAR to fit.",
            ]
        if self.ntaupar and self.nomegapar:
            lines += [
                "# Explicit override (only if you do NOT trust the MAXMEM auto-pick):",
                f"# NTAUPAR   = {self.ntaupar}{nomega_cmt}",
                f"# NOMEGAPAR = {self.nomegapar}",
                "#   Both MUST be divisors of NOMEGA. Larger NTAUPAR = faster but more RAM.",
            ]
        elif self.ntaupar:
            lines += [
                f"# NTAUPAR = {self.ntaupar}{nomega_cmt}  (divisor of NOMEGA; larger=faster,more RAM)",
            ]
        lines += [
            "ISMEAR = 0 ; SIGMA = 0.05",
            "# LOPTICS = .TRUE.   # insulators/semiconductors; OMIT for metals",
        ]
        return "\n".join(lines)


# ============================================================================
# Small utilities
# ============================================================================


def positive_divisors(n: int) -> List[int]:
    """Return all positive divisors of n in ascending order."""
    if n <= 0:
        return []
    small: List[int] = []
    large: List[int] = []
    root = math.isqrt(n)
    for i in range(1, root + 1):
        if n % i == 0:
            small.append(i)
            j = n // i
            if j != i:
                large.append(j)
    return small + list(reversed(large))


def format_bool(value: bool) -> str:
    """Render a Python bool as a VASP INCAR flag (.TRUE./.FALSE.)."""
    return ".TRUE." if value else ".FALSE."


def round_up_to_multiple(n: int, m: int) -> int:
    """Smallest multiple of `m` that is >= `n` (returns `n` if m <= 0)."""
    if m <= 0:
        return n
    return ((n + m - 1) // m) * m


def round_up_mem(mb: float, step: int = 50) -> int:
    """Round memory up to a 'nice' multiple of `step` MB (min 100 MB)."""
    return int(math.ceil(max(mb, 100.0) / step) * step)


# ============================================================================
# OUTCAR parsing
# ============================================================================


def _read_text(path: Path) -> str:
    """Read a file as text, exiting with a clear message if it cannot be read."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise SystemExit(f"Could not read {path}: {exc}") from exc


def _first_int(patterns: Sequence[str], text: str) -> Optional[int]:
    """Return the first integer captured by any of `patterns` in `text`, else None."""
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
        if match:
            try:
                return int(match.group(1))
            except (ValueError, IndexError):
                continue
    return None


def _first_float(patterns: Sequence[str], text: str) -> Optional[float]:
    """Return the first float captured by any of `patterns` in `text`, else None."""
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
        if match:
            try:
                return float(match.group(1))
            except (ValueError, IndexError):
                continue
    return None


def _first_str(patterns: Sequence[str], text: str) -> Optional[str]:
    """Return the first string captured by any of `patterns` in `text`, else None."""
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
        if match:
            try:
                return match.group(1).strip()
            except IndexError:
                continue
    return None


def _parse_fft_grid(text: str, fine: bool) -> Optional[Tuple[int, int, int]]:
    """Parse 'dimension x,y,z NGX = .. NGY = .. NGZ = ..' or NGXF/.. line."""
    if fine:
        pattern = r"NGXF\s*=\s*(\d+)\s+NGYF\s*=\s*(\d+)\s+NGZF\s*=\s*(\d+)"
    else:
        # The 'NGX = ' line appears for the coarse grid; be careful not to match NGXF.
        pattern = r"(?<!F)NGX\s*=\s*(\d+)\s+NGY\s*=\s*(\d+)\s+NGZ\s*=\s*(\d+)"
    match = re.search(pattern, text, flags=re.MULTILINE | re.IGNORECASE)
    if match:
        return (int(match.group(1)), int(match.group(2)), int(match.group(3)))
    return None


def _parse_dry_distribution(text: str) -> Tuple[Optional[int], Optional[int],
                                                Optional[int], Optional[int]]:
    """Return (total_ranks_dry, kpar_dry, ncore_dry, npar_dry).

    VASP prints, near the top of the OUTCAR, two unambiguous lines:

        running on    1 total cores
        distrk:  each k-point on    1 cores,    1 groups
        distr:   one band on  NCORE=   1 cores,    1 groups

    The 'groups' field of distrk gives KPAR.
    The NCORE= field of distr gives NCORE.
    The 'groups' field of distr gives NPAR.
    """
    total = _first_int(
        [r"running on\s+(\d+)\s+total cores"],
        text,
    )
    kpar = None
    ncore = None
    npar = None

    m_kpar = re.search(
        r"distrk:\s*each k-point on\s+\d+\s+cores,\s*(\d+)\s+groups",
        text,
        flags=re.IGNORECASE,
    )
    if m_kpar:
        kpar = int(m_kpar.group(1))

    m_ncore = re.search(
        r"distr:\s*one band on\s+NCORE\s*=\s*(\d+)\s+cores,\s*(\d+)\s+groups",
        text,
        flags=re.IGNORECASE,
    )
    if m_ncore:
        ncore = int(m_ncore.group(1))
        npar = int(m_ncore.group(2))

    # Consistency: derive the missing field from the parallelization
    # identity total_ranks = NPAR * NCORE * KPAR (with IMAGES=1).
    if not total and kpar and ncore and npar:
        # 'running on N total cores' is sometimes missing (older builds,
        # short reports, certain MPI launchers).  This is the common case.
        total = kpar * ncore * npar
    if total and kpar and ncore and not npar:
        npar = max(1, (total // kpar) // ncore)
    if total and ncore and npar and not kpar:
        kpar = max(1, total // (ncore * npar))
    if total and kpar and npar and not ncore:
        ncore = max(1, total // (kpar * npar))

    return total, kpar, ncore, npar


def _parse_memory_table(text: str) -> MemoryBreakdown:
    """Parse the 'total amount of memory used by VASP MPI-rank0' table.

    Output is in MB.  Returns an empty MemoryBreakdown if the table is
    missing (e.g. very old VASP, aborted dry run).  Different VASP builds
    format this table slightly differently (column width, trailing dots,
    optional spaces), so we try a few patterns per row.
    """
    mb = MemoryBreakdown()

    # Headline number.  Match with or without trailing period after the value.
    m_total = re.search(
        r"total amount of memory used by VASP MPI-rank0"
        r"\s+([0-9]+(?:\.[0-9]+)?)\.?\s*k[bB]ytes",
        text,
    )
    if m_total:
        try:
            mb.total_mb = float(m_total.group(1)) / 1024.0
        except ValueError:
            pass

    # Per-row labels.  VASP has used several spellings over the years; map
    # them all to the same MemoryBreakdown attribute.
    row_keys = {
        "base":       "base_mb",
        "nonlr-proj": "nonlr_proj_mb",
        "nonl-proj":  "nonlr_proj_mb",    # older VASP spelling
        "nonl_proj":  "nonlr_proj_mb",    # very old variant
        "fftplans":   "fftplans_mb",
        "fft-plans":  "fftplans_mb",
        "grid":       "grid_mb",
        "one-center": "one_center_mb",
        "one_center": "one_center_mb",
        "wavefun":    "wavefun_mb",
        "wavefunctions": "wavefun_mb",    # defensive
    }
    for outcar_label, attr in row_keys.items():
        # Several alternative patterns; first match wins.  We do NOT use \b
        # at the start because some labels contain '-' or '_' which are not
        # word-character boundaries.  We anchor on at-least-one whitespace
        # before the label instead.
        patterns = [
            # Standard:    label  :   1234. kBytes
            rf"(?:^|\s){re.escape(outcar_label)}\s*:\s*"
            rf"([0-9]+(?:\.[0-9]+)?)\.?\s*k[bB]ytes",
            # Fortran overflow guard (rare): label : ******* kBytes -> skip
            # Sometimes the value sits on the next line:
            rf"(?:^|\s){re.escape(outcar_label)}\s*:\s*\n\s*"
            rf"([0-9]+(?:\.[0-9]+)?)\.?\s*k[bB]ytes",
        ]
        for pattern in patterns:
            m = re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE)
            if m:
                try:
                    setattr(mb, attr, float(m.group(1)) / 1024.0)
                except ValueError:
                    pass
                break

    return mb


# ----------------------------------------------------------------------------
# GW / RPA recognition
# ----------------------------------------------------------------------------
# ALGO values that select a GW or RPA calculation, split by implementation.
# Names are compared upper-cased and stripped.  VASP.5 aliases are included.
#   * Conventional (quartic-scaling) GW: parallelizes over k-points (KPAR) only.
#   * Low-scaling / space-time GW (names end in 'R'): use NTAUPAR / NOMEGAPAR.
#   * Low-scaling RPA (ACFDTR / RPAR): same imaginary-grid machinery as GW-R.
GW_CONVENTIONAL_ALGOS = {
    "G0W0", "GW0", "GW",
    "EVGW0", "EVGW", "QPGW0", "QPGW",
    "SCGW0", "SCGW",          # VASP.5 aliases for QPGW0 / QPGW
}
GW_LOWSCALING_ALGOS = {
    "G0W0R", "EVGW0R", "GW0R", "GWR",
    "SCGW0R", "SCGWR",        # aliases
}
RPA_LOWSCALING_ALGOS = {
    "ACFDTR", "RPAR",         # low-scaling RPA / ACFDT (space-time)
}


# ----------------------------------------------------------------------------
# Conventional-GW per-rank memory FLOOR model.
#
# Research conclusion (VASP wiki MAXMEM / Practical_guide_to_GW / Not_enough_memory;
# forum t=18931, t=19502; rehnd.github.io/tutorials/vasp/gw): the per-rank memory
# needed to RUN conventional GW is a FLOOR set by orbitals + exact exchange + ONE
# response-function block, and it is
#   * NOMEGA-INDEPENDENT -- NOMEGA only sets how many frequency blocks VASP BATCHES at
#     once (bounded by MAXMEM) for SPEED; the minimum is always one block, so lowering
#     NOMEGA does NOT lower the floor (this is why a NOMEGA sweep gave the same OOM);
#   * proportional to ENCUTGW^3 -- the response matrix ~ (N_G)^2 ~ ENCUTGW^3 is the #1
#     memory lever (ENCUTGW, NOT NOMEGA);
#   * proportional to 1/ranks-per-k-group -- the floor is distributed over the ranks of
#     a k-group, so MORE ranks per group => LESS per rank.
# KPAR REPLICATES the floor per k-group, so the cure for OOM is MORE NODES / FEWER
# RANKS-PER-NODE (undersaturation), never a bigger MAXMEM. MAXMEM is NOT a knob in this
# model: VASP fills whatever MAXMEM it is given and reports needing ~MAXMEM + a fixed
# ~uncounted overhead, so chasing MAXMEM upward never converges. We instead derive
# MAXMEM = (mem-per-cpu - reserve) so the batchable arrays + the overhead fit the cgroup.
#
# We ANCHOR the floor to VASP's OWN printed "min. memory requirement per mpi rank" and
# PROVISION TO IT (no discount). History (learn from it): an intermediate version tried a
# 0.80 "real-RSS discount" after ONE run (CuVS3 EVGW0 NOMEGA=25) reported 7282 but ran at
# ~5850/rank on 1 node at 96.6% (the response function is NCSHMEM-shared, so real RSS <
# the printed number). That discount OOM'd the very next run (NOMEGA=100, which holds more
# frequency arrays -> real peak back up near 7282) at only 3.7% margin. LESSON: VASP's
# printed requirement is the number to trust -- it is what VASP will try to allocate, it is
# NOMEGA-stable, and provisioning below it is a coin-flip that depends on NOMEGA/shmem/load
# balance. So anchor = 7282; the mem_util policy (~0.80) then adds the ~25% headroom, giving
# mem-per-cpu ~9100. CONSEQUENCE: 120 ranks x 7282 = 874 GB CANNOT fit one 727 GB node, so
# the job MUST split across KPAR nodes (one k-group/node, ~40 ranks/node) AND each rank must
# get >= 7282 -- more nodes alone does NOT help; you must raise mem-per-cpu with the split.
GW_FLOOR_ANCHOR_MB = 7282.0       # VASP's printed "min. memory requirement per mpi rank" ...
GW_FLOOR_ANCHOR_RPK = 40.0        # ... at this many ranks per k-group ...
GW_FLOOR_ANCHOR_ENCUTGW = 405.0   # ... and this ENCUTGW (eV). (empirical EVGW0 reference)
GW_VASP_REQ_TO_RSS = 1.00         # provision to VASP's FULL printed requirement (NO discount;
                                  #   the 0.80 discount OOM'd at NOMEGA=100 -- do not restore it)
# MAXMEM is a FROZEN INPUT, never re-derived from a bigger allocation. Measured on the
# user's cluster: VASP fills whatever MAXMEM it gets and its requirement/real peak lands
# at ~MAXMEM + 1.5-2.4 GB (required 7282@4961, 9566@7692 [6.4.3], 9799@7692 [6.4.2],
# 12083@10550, 15128@13300). The old rule MAXMEM = mem-per-cpu - 15% therefore DIVERGED:
# harvest required -> raise mem-per-cpu -> bigger MAXMEM -> bigger required -> OOM again
# (MAXMEM_next ~ 1.05 x MAXMEM + 2.5 GB). Fix: MAXMEM <= mem-per-cpu - OVERHEAD, and on
# any refine it may only stay or go DOWN (vasp_test_recommend freezes it to the INCAR's
# previous value). Then usage ~ MAXMEM + 2 GB is pinned and the relaunch converges.
GW_MAXMEM_OVERHEAD_MB = 3000      # cgroup room kept ABOVE MAXMEM for VASP's overhead
                                  #   (orbitals/exchange/FFT/MPI, observed <= ~2.4 GB)


def gw_floor_per_rank_mb(
    ranks_per_kgroup: float,
    encutgw: Optional[float],
    *,
    anchor_mb: float = GW_FLOOR_ANCHOR_MB,
    anchor_rpk: float = GW_FLOOR_ANCHOR_RPK,
    anchor_encutgw: float = GW_FLOOR_ANCHOR_ENCUTGW,
) -> float:
    """Conventional-GW per-rank memory FLOOR (MB), NOMEGA-independent.

        R(rpk, ENCUTGW) = anchor_mb * (anchor_rpk / rpk) * (ENCUTGW / anchor_encutgw)^3

    `anchor_mb` is VASP's own measured "min. memory requirement per mpi rank" at
    (`anchor_rpk`, `anchor_encutgw`); pass a harvested value to pin the level to a real
    run. NOMEGA does NOT appear by design (the floor is one response block)."""
    rpk = max(1.0, float(ranks_per_kgroup))
    e = float(encutgw or anchor_encutgw)
    return max(1.0, anchor_mb * (anchor_rpk / rpk) * (e / max(anchor_encutgw, 1.0)) ** 3)


def gw_maxmem_from_request(mem_per_cpu_mb: float,
                           existing_mb: Optional[int] = None) -> int:
    """MAXMEM (MB/rank): capped at mem-per-cpu - GW_MAXMEM_OVERHEAD_MB and FROZEN --
    never raised above the value a previous run already used (`existing_mb`).

    VASP fills whatever MAXMEM it gets and really uses ~MAXMEM + ~2 GB, so re-deriving
    a bigger MAXMEM from a bigger allocation makes every relaunch hungrier (divergent
    ratchet). Keeping MAXMEM fixed pins VASP's usage; only the headroom grows."""
    cap = mem_per_cpu_mb - GW_MAXMEM_OVERHEAD_MB
    if existing_mb and existing_mb > 0:
        cap = min(cap, existing_mb)
    return int(max(2800, cap))


def _parse_named_fft_grid(text: str, header: str) -> Optional[Tuple[int, int, int]]:
    """Parse a 'NGX = .. NGY = .. NGZ = ..' triple that follows a header line.

    Low-scaling GW/RPA OUTCARs print, e.g.:

        FFT grid for exact exchange (Hartree Fock)
          NGX =  30 NGY =  30 NGZ =  30
        FFT grid for supercell:
          NGX =  60 NGY =  60 NGZ =  60

    `header` is a regex fragment identifying the introductory line.  We then
    look for the first NGX/NGY/NGZ triple appearing after it.
    """
    m_head = re.search(header, text, flags=re.IGNORECASE)
    if not m_head:
        return None
    tail = text[m_head.end():m_head.end() + 400]
    m = re.search(
        r"NGX\s*=?\s*(\d+)\s+NGY\s*=?\s*(\d+)\s+NGZ\s*=?\s*(\d+)",
        tail,
        flags=re.IGNORECASE,
    )
    if m:
        return (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return None


def _parse_lowscaling_minmem(text: str) -> Tuple[Optional[float], Optional[float]]:
    """Parse VASP's own low-scaling memory estimate, if present.

        min. memory requirement per mpi rank 1234 MB, per node 9872 MB

    Returns (per_rank_mb, per_node_mb).  This is VASP's authoritative number
    for the chosen NTAUPAR; when present we surface it verbatim.
    """
    m = re.search(
        r"min\.?\s*memory requirement per mpi rank\s+([0-9]+(?:\.[0-9]+)?)\s*MB"
        r".*?per node\s+([0-9]+(?:\.[0-9]+)?)\s*MB",
        text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not m:
        return None, None
    try:
        return float(m.group(1)), float(m.group(2))
    except ValueError:
        return None, None


def detect_calculation_type(
    s: DryRunSummary,
    text: str,
    override: Optional[str] = None,
) -> Tuple[str, Optional[str]]:
    """Classify the dry run as DFT / conventional-GW / low-scaling-GW / RPA.

    Returns (calc_type, gw_algo_string).

    Recognition is deliberately robust because the recommended dry-run recipe
    (append ``ALGO = None``) MASKS the real GW ALGO in the OUTCAR.  We therefore
    look at several independent signals:

      1. The ALGO string itself (authoritative when not masked).
      2. Low-scaling fingerprints that ALGO=None does NOT remove:
         the "FFT grid for exact exchange / supercell" lines, the
         "min. memory requirement per mpi rank ... per node" line, or an
         NTAUPAR / NOMEGAPAR echo.
      3. Conventional-GW fingerprints: NOMEGA together with a GW-only tag
         (NELMGW, ENCUTGW, NBANDSGW, or LSPECTRALGW).

    A manual ``override`` (from --calc-type) always wins.
    """
    if override and override != "auto":
        mapping = {
            "dft": ("DFT", None),
            "gw": ("GW_CONVENTIONAL", s.algo),
            "gw-low": ("GW_LOWSCALING", s.algo),
            "rpa-low": ("RPA_LOWSCALING", s.algo),
        }
        if override in mapping:
            return mapping[override]

    algo_up = (s.algo or "").strip().upper()
    # When the dry run masked ALGO with None (the recommended recipe appends
    # 'ALGO = None'), s.algo is the literal string "None"; treat it as masked
    # so the fingerprint branches report a helpful label instead of "None".
    algo_masked = (not s.algo) or algo_up in ("NONE", "NOTHING")
    algo_display = None if algo_masked else s.algo

    # 1. Direct ALGO match (only meaningful if ALGO wasn't overwritten by None).
    if algo_up in RPA_LOWSCALING_ALGOS:
        return "RPA_LOWSCALING", s.algo
    if algo_up in GW_LOWSCALING_ALGOS:
        return "GW_LOWSCALING", s.algo
    if algo_up in GW_CONVENTIONAL_ALGOS:
        return "GW_CONVENTIONAL", s.algo

    # 2. Low-scaling fingerprints (survive ALGO=None). NOTE: the
    # "min. memory requirement per mpi rank ... per node" line is printed by BOTH
    # conventional and low-scaling GW, so it is NOT a low-scaling marker (using it as
    # one misclassifies a failed CONVENTIONAL GW run); the imaginary-time/-frequency
    # grids and NTAUPAR/NOMEGAPAR echoes are the genuine space-time fingerprints.
    lowscaling_markers = (
        s.fft_exx is not None
        or s.fft_supercell is not None
        or s.ntaupar_dry is not None
        or s.nomegapar_dry is not None
        or re.search(r"FFT grid for exact exchange", text, re.IGNORECASE) is not None
        or re.search(r"low.?scaling\s+(GW|RPA)", text, re.IGNORECASE) is not None
    )
    if lowscaling_markers:
        # Distinguish RPA from GW by other tags if we can; default to GW.
        if re.search(r"\bACFDT\b|\bRPA\b", text, re.IGNORECASE) \
                and not re.search(r"\bGW\b", text, re.IGNORECASE):
            return "RPA_LOWSCALING", algo_display or "(low-scaling RPA, ALGO masked)"
        return "GW_LOWSCALING", algo_display or "(low-scaling GW, ALGO masked)"

    # 3. Conventional-GW fingerprints: NOMEGA + a GW-only tag.
    has_gw_tag = (
        s.nelmgw is not None
        or s.encutgw is not None
        or s.nbandsgw is not None
        or re.search(r"\bLSPECTRALGW\b", text, re.IGNORECASE) is not None
        or re.search(r"\bNOMEGAR\b", text, re.IGNORECASE) is not None
    )
    if s.nomega is not None and has_gw_tag:
        return "GW_CONVENTIONAL", algo_display or "(GW, ALGO masked)"
    # ENCUTGW alone is a strong GW signal even without NOMEGA parsed.
    if s.encutgw is not None and (s.nomega is not None or has_gw_tag):
        return "GW_CONVENTIONAL", algo_display or "(GW, ALGO masked)"

    return "DFT", None


def parse_outcar(outcar_path: Path,
                 calc_type_override: Optional[str] = None) -> DryRunSummary:
    """Parse a dry-run OUTCAR into a DryRunSummary (sizes, k-points, GW tags, memory table)."""
    text = _read_text(outcar_path)
    s = DryRunSummary(outcar_path=outcar_path)

    # System dimensions
    s.irr_kpoints = _first_int(
        [
            r"irreducible k-points\s*[:=]\s*(\d+)",
            r"Found\s+(\d+)\s+irreducible k-points",
            r"number of irreducible k-points:\s*(\d+)",
        ],
        text,
    )
    s.nkpts = _first_int(
        [
            r"NKPTS\s*=\s*(\d+)",
            r"k-points\s+NKPTS\s*=\s*(\d+)",
        ],
        text,
    )
    s.nbands = _first_int(
        [
            r"NBANDS\s*=\s*(\d+)",
            r"number of bands\s+NBANDS\s*=\s*(\d+)",
        ],
        text,
    )
    s.nions = _first_int([r"NIONS\s*=\s*(\d+)"], text)
    s.nelect = _first_float([r"NELECT\s*=\s*([0-9]+(?:\.[0-9]+)?)"], text)
    s.ispin = _first_int([r"ISPIN\s*=\s*(\d+)"], text) or 1
    # NRPLWV -- the number of plane-wave COEFFICIENTS per band, which is what
    # the wavefunction memory is proportional to.
    #
    # VASP prints it per k-point, and the dry run prints it too:
    #     k-point   1 :  0.0000 0.0000 0.0000  plane waves:    8553
    # Take the maximum, because that is the array VASP dimensions.
    #
    # Do NOT read it from "total plane-waves  NPLWV = 57600".  Despite the
    # label, NPLWV is NGX*NGY*NGZ -- the FFT box, not the sphere inside it.
    # On the fixture above, 50*18*64 = 57600 against a true 8553: reading that
    # line put a 6.7x error into the dominant term of the memory model.
    _pw = [int(m) for m in re.findall(r"plane waves:\s*(\d+)", text)]
    s.nplwv = max(_pw) if _pw else _first_int(
        [
            r"\bNRPLWV\s*=\s*(\d+)",
            r"max plane-waves\s*=\s*(\d+)",
            r"maximum number of plane-waves\s*[:=]\s*(\d+)",
        ],
        text,
    )
    s.coarse_fft = _parse_fft_grid(text, fine=False)
    s.fine_fft = _parse_fft_grid(text, fine=True)
    # If NPLWV is not in the OUTCAR (or overflowed), estimate it from the
    # coarse FFT grid.  VASP sizes the FFT box so that 2|G_cut| just fits
    # inside it; the number of plane waves inside the sphere |G|<|G_cut| is
    # approximately (pi/48) * NGX*NGY*NGZ.  This is rough but in the right
    # order of magnitude; the memory model uses VASP's TOTAL anchor instead
    # whenever the OUTCAR provides it, so this fallback rarely matters.
    if s.nplwv is None and s.coarse_fft is not None:
        ngx, ngy, ngz = s.coarse_fft
        s.nplwv = max(1, int(ngx * ngy * ngz * math.pi / 48.0))
    s.is_gamma_only = (
        (s.irr_kpoints is not None and s.irr_kpoints == 1)
        or (s.nkpts is not None and s.nkpts == 1)
    )
    # Non-collinear / spin-orbit: needs the vasp_ncl binary, which vasp_std is not.
    s.is_noncollinear = re.search(
        r"\b(LNONCOLLINEAR|LSORBIT)\s*=\s*\.?T", text, re.IGNORECASE) is not None

    # Algorithm / cutoff.  Use \b to avoid matching IALGO when looking for ALGO.
    s.algo = _first_str([r"(?<![A-Z])ALGO\s*=\s*(\S+)"], text)
    s.lreal = _first_str([r"(?<![A-Z])LREAL\s*=\s*([^\s#]+)"], text)
    s.encut = _first_float([r"(?<![A-Z])ENCUT\s*=\s*([0-9.]+)"], text)

    # --- GW / RPA tags (informational + needed for the τ/ω grid split) ---
    s.nomega = _first_int([r"\bNOMEGA\s*=\s*(\d+)"], text)
    s.nelmgw = _first_int([r"\bNELMGW\s*=\s*(\d+)"], text)
    s.encutgw = _first_float([r"\bENCUTGW\s*=\s*([0-9.]+)"], text)
    s.nbandsgw = _first_int([r"\bNBANDSGW\s*=\s*(\d+)"], text)
    s.ntaupar_dry = _first_int([r"\bNTAUPAR\s*=\s*(\d+)"], text)
    s.nomegapar_dry = _first_int([r"\bNOMEGAPAR\s*=\s*(\d+)"], text)
    # Low-scaling FFT grids (printed only for space-time GW/RPA runs):
    s.fft_exx = _parse_named_fft_grid(
        text, r"FFT grid for exact exchange(?:\s*\(Hartree[ -]?Fock\))?")
    s.fft_supercell = _parse_named_fft_grid(text, r"FFT grid for supercell")
    # VASP's own printed low-scaling memory estimate, if present:
    (s.vasp_min_mem_per_rank_mb,
     s.vasp_min_mem_per_node_mb) = _parse_lowscaling_minmem(text)

    # Dry-run parallel layout (essential for rescaling memory)
    (s.dry_total_ranks, s.dry_kpar,
     s.dry_ncore, s.dry_npar) = _parse_dry_distribution(text)

    # VASP-reported memory breakdown for the dry-run layout
    s.memory = _parse_memory_table(text)

    # Classify DFT vs GW vs RPA from all available signals.
    s.calc_type, s.gw_algo = detect_calculation_type(
        s, text, override=calc_type_override)

    return s


# ============================================================================
# Memory model
# ============================================================================


def _fallback_wavefun_mb(summary: DryRunSummary, ncore: int, npar: int,
                         kpar: int) -> float:
    """Wavefunction storage per rank, from the wiki formula.

    Per https://vasp.at/wiki/Memory_requirements:
        NKDIM * NBANDS * NRPLWV * 16  bytes
    where NRPLWV is the max number of plane-wave COEFFICIENTS over k-points --
    the "plane waves:" count the dry run prints per k-point, NOT the NPLWV
    line, which is the FFT box.  Distributing over the rank lattice:

        per_rank = (NBANDS * NKPTS * NRPLWV * ISPIN * 16) / (NPAR*NCORE*KPAR)
    """
    if not (summary.nbands and summary.nplwv):
        return 0.0
    nkpts = summary.nkpts or summary.irr_kpoints or 1
    total = npar * ncore * kpar
    if total <= 0:
        return 0.0
    bytes_per_rank = (
        summary.nbands * nkpts * summary.nplwv * (summary.ispin or 1) * 16.0
    ) / total
    return bytes_per_rank / (1024.0 ** 2)


def _fallback_grid_mb(summary: DryRunSummary, npar: int) -> float:
    """Grid (charge density / potential) work-array memory per rank.

    Per https://vasp.at/wiki/Memory_requirements ~10 arrays of size
        4 * (NGXF/2 + 1) * NGYF * NGZF * 16  bytes
    are allocated.  With LPLANE=.TRUE. these are distributed in z-slabs
    over NPAR ranks within a k-group.  Each k-group has its own copy;
    KPAR does NOT reduce the per-rank cost.
    """
    grid = summary.fine_fft or summary.coarse_fft
    if grid is None:
        return 0.0
    ngxf, ngyf, ngzf = grid
    n_arrays = 10
    bytes_total = n_arrays * 4.0 * (ngxf // 2 + 1) * ngyf * ngzf * 16.0
    per_rank = bytes_total / max(1, npar)
    return per_rank / (1024.0 ** 2)


def _fallback_proj_mb(summary: DryRunSummary, ncore: int) -> float:
    """PAW projector memory per rank.

    Rough empirical scaling: ~ 0.5 MB per ion per total-projector unit,
    distributed across NCORE within the band group.  This is a rough
    upper bound; the rescaled-from-OUTCAR branch is far more accurate.
    """
    natoms = summary.nions or 0
    # ~50 MB per 100 atoms; ScaLAPACK in VASP 6 typically holds projectors
    # in a denser form than this, but better to over- than under-estimate.
    raw = 0.5 * natoms
    return raw / max(1, ncore)


def _scalapack_mb(summary: DryRunSummary, total_ranks: int, kpar: int) -> float:
    """ScaLAPACK NBANDS x NBANDS sub-space matrix per rank.

    Distributed within each k-group; replicated across k-groups:
        per_rank = NBANDS^2 * 16 * KPAR / total_ranks
    """
    if not summary.nbands:
        return 0.0
    bytes_per_rank = (
        (summary.nbands ** 2) * 16.0 * max(1, kpar) / max(1, total_ranks)
    )
    return bytes_per_rank / (1024.0 ** 2)


def estimate_memory(
    *,
    summary: DryRunSummary,
    total_ranks: int,
    kpar: int,
    ncore: int,
    npar: int,
    partition_mem_per_cpu_mb: int,
    safety_factor: float,
) -> MemoryEstimate:
    """Predict per-rank memory for a candidate layout.

    Three-tier strategy, from most-accurate to least:

      Tier 1  ("rescaled-from-outcar"):
        The dry-run OUTCAR contains the FULL memory breakdown
        (base / nonlr-proj / fftplans / grid / one-center / wavefun).
        Each row is rescaled to the candidate layout using the wiki
        distribution rules:
            wavefun     : scales as 1 / total_ranks    (fully distributed)
            grid        : scales as 1 / NPAR           (z-slab; per k-group)
            nonlr-proj  : scales as 1 / NCORE          (per k-group)
            fftplans, base, one-center : ~ constant per rank
        scaLAPACK NBANDS^2 workspace is added on top (it is NOT in the
        table): per_rank = NBANDS^2 * 16 * KPAR / total_ranks.

      Tier 2  ("rescaled-from-outcar-total-only"):
        The OUTCAR has the headline 'total amount of memory used by VASP
        MPI-rank0 X kBytes' line but not the per-row breakdown.  In this
        tier we DECOMPOSE the total assuming the typical VASP CPU mix
        (wavefun ~ 80%, grid ~ 15%, nonlr-proj ~ 5%, fixed ~100 MB
        overhead) and rescale each component by its own distribution
        rule.  This is far less accurate than Tier 1 but FAR more
        accurate than ignoring the OUTCAR's TOTAL and going to formulas.

      Tier 3  ("fallback-formulas"):
        No memory table at all.  Use the wiki's analytical formulas with
        whatever dimensions were parsed (NPLWV, FFT grid, NBANDS, NKPTS).
        If NPLWV is missing, NPLWV is approximated from the FFT grid by
        the inscribed-sphere ratio at the parse stage.
    """
    est = MemoryEstimate(partition_mem_per_cpu_mb=partition_mem_per_cpu_mb)

    if total_ranks <= 0 or kpar <= 0 or ncore <= 0 or npar <= 0:
        return est

    mem_table = summary.memory
    have_total = mem_table.total_mb is not None
    have_individual_rows = (
        mem_table.wavefun_mb is not None
        and mem_table.grid_mb is not None
    )
    have_dry_layout = (
        summary.dry_total_ranks is not None
        and summary.dry_kpar is not None
        and summary.dry_ncore is not None
        and summary.dry_npar is not None
    )

    # ------------------------------------------------------------------
    # Tier 1: full breakdown available (best case).
    # ------------------------------------------------------------------
    if have_individual_rows and have_dry_layout:
        est.model = "rescaled-from-outcar"
        m = mem_table
        d_total = max(1, summary.dry_total_ranks)
        d_ncore = max(1, summary.dry_ncore)
        d_npar = max(1, summary.dry_npar)

        est.wavefun_mb = (m.wavefun_mb or 0.0) * d_total / total_ranks
        est.grid_mb = (m.grid_mb or 0.0) * d_npar / npar
        est.nonlr_proj_mb = (m.nonlr_proj_mb or 0.0) * d_ncore / ncore
        est.base_mb = m.base_mb or 30.0
        est.fftplans_mb = m.fftplans_mb or 30.0
        est.one_center_mb = m.one_center_mb or 0.5
        est.scalapack_mb = _scalapack_mb(summary, total_ranks, kpar)

    # ------------------------------------------------------------------
    # Tier 2: only the headline TOTAL is available.
    # ------------------------------------------------------------------
    elif have_total and have_dry_layout:
        est.model = "rescaled-from-outcar-total-only"
        d_total = max(1, summary.dry_total_ranks)
        d_ncore = max(1, summary.dry_ncore)
        d_npar = max(1, summary.dry_npar)

        # Fixed per-rank overhead that does NOT redistribute with the layout
        # (base + fftplans + one_center + small libraries).  Typical VASP 6
        # values are: base ~30 MB, fftplans ~40 MB, one_center ~5-50 MB.
        # We use 100 MB as a conservative single number; the actual breakdown
        # is rebuilt below for the human-readable output.
        const_overhead_mb = 100.0

        # Everything else at dry layout (per rank)
        distributed_per_rank_dry = max(0.0,
                                       (mem_table.total_mb or 0.0) - const_overhead_mb)

        # Decompose into wavefun / grid / nonlr-proj using a generic split
        # observed in practice on VASP 6 CPU calculations of medium-large
        # systems.  These fractions are conservative biases, NOT precise.
        wavefun_frac = 0.80
        grid_frac = 0.15
        proj_frac = 0.05

        wavefun_dry = wavefun_frac * distributed_per_rank_dry   # per rank
        grid_dry = grid_frac * distributed_per_rank_dry         # per rank
        proj_dry = proj_frac * distributed_per_rank_dry         # per rank

        # Rescale each by its documented distribution rule.
        est.wavefun_mb = wavefun_dry * d_total / total_ranks
        est.grid_mb = grid_dry * d_npar / npar
        est.nonlr_proj_mb = proj_dry * d_ncore / ncore
        est.base_mb = 30.0
        est.fftplans_mb = 50.0
        est.one_center_mb = 20.0
        est.scalapack_mb = _scalapack_mb(summary, total_ranks, kpar)

    # ------------------------------------------------------------------
    # Tier 3: no memory information at all.  Pure formulas.
    # ------------------------------------------------------------------
    else:
        est.model = "fallback-formulas"
        est.wavefun_mb = _fallback_wavefun_mb(summary, ncore, npar, kpar)
        est.grid_mb = _fallback_grid_mb(summary, npar)
        est.nonlr_proj_mb = _fallback_proj_mb(summary, ncore)
        est.base_mb = 30.0
        est.fftplans_mb = 30.0
        est.one_center_mb = 0.5
        est.scalapack_mb = _scalapack_mb(summary, total_ranks, kpar)

    base_sum = (
        est.wavefun_mb
        + est.grid_mb
        + est.nonlr_proj_mb
        + est.fftplans_mb
        + est.base_mb
        + est.one_center_mb
        + est.scalapack_mb
    )

    # Sanity floor for Tiers 1 and 2: at the dry-run layout the prediction
    # must be at least 0.95 * TOTAL_dry per rank.  This guards against
    # accidental under-prediction (the failure mode that the user hit).
    if est.model.startswith("rescaled-from-outcar") and have_total \
            and have_dry_layout \
            and total_ranks == summary.dry_total_ranks \
            and kpar == summary.dry_kpar \
            and ncore == summary.dry_ncore \
            and npar == summary.dry_npar:
        # Force the dry-run point of the surface to match the OUTCAR TOTAL.
        # If our breakdown sums to less than what VASP actually reported,
        # raise it.  We never lower it (that would mask a real over-estimate).
        floor = 0.95 * (mem_table.total_mb or 0.0)
        if base_sum < floor:
            # Attribute the missing amount to "safety_mb" so the breakdown
            # printed to the user remains internally consistent.
            est.safety_mb = floor - base_sum
            base_sum = floor

    # Safety margin: (safety_factor - 1) of base + 100 MB floor for MPI
    # buffers, library overhead, FFT scratch, I/O caches not in the OUTCAR
    # memory table.  100 MB is enough to absorb the usual difference between
    # VASP's reported TOTAL and the kernel's RSS high-water-mark at runtime.
    est.safety_mb = (est.safety_mb if est.safety_mb else 0.0) \
        + (max(safety_factor, 1.0) - 1.0) * base_sum + 100.0

    est.per_rank_mb = base_sum + est.safety_mb
    est.total_job_mb = est.per_rank_mb * total_ranks
    est.suggested_mem_per_cpu_mb = round_up_mem(est.per_rank_mb)
    # "Fits" = within 1.5x of the partition default mem-per-cpu.  The SLURM
    # script asks for the suggested value explicitly, so it will SCHEDULE
    # even above default; but going much above default usually means you
    # have to give up cores per node and that's what we want to penalise.
    est.fits_partition = (
        est.suggested_mem_per_cpu_mb <= 1.5 * partition_mem_per_cpu_mb
    )
    return est


# ============================================================================
# Suggested rank counts
# ============================================================================


def suggest_total_ranks(
    *,
    min_cores: int,
    max_cores: int,
    cpus_per_node: int,
    irr_kpoints: Optional[int],
    nbands: Optional[int],
) -> List[int]:
    """The rank counts this CLUSTER can actually give, largest first.

    ==========================================================================
    THE CLUSTER DECIDES THE SHAPE; THE PHYSICS DECIDES WHICH SHAPE
    ==========================================================================
    This used to work the other way round. It generated rank counts from the
    physics -- multiples of NKPTS, NBANDS-friendly NPAR products, round numbers
    from benchmark papers -- and left the node split to cope afterwards. On a
    cluster of 48-core nodes that offered 190 ranks, because NKPTS was 190, and
    190 ranks do not fill 48-core nodes. Everything downstream then had to
    invent something: the geometry put one rank on each of 190 nodes, and the
    job script claimed a --ntasks-per-node that was not true.

    VASP is explicit that this is the wrong shape, not merely an awkward one:

        "VASP assumes the ranks first fill up a node before the next node is
         occupied... If the ranks are placed differently, communication between
         the nodes occurs for every parallel FFT. Because FFTs are essential to
         VASP's speed, this deteriorates the performance of the calculation."
        -- https://vasp.at/wiki/Category:Parallelization, "MPI setup"

    So the candidate rank counts are WHOLE NODES, full stop, plus the sub-node
    sizes that still live inside one node for a small job. KPAR, NCORE and NPAR
    are then chosen as divisors of a count the cluster can hand out whole --
    which is the physics mapped onto the machine, rather than the machine asked
    to contort around the physics.

    `irr_kpoints` and `nbands` are no longer used to invent rank counts. They
    still decide everything that matters: which KPAR, NCORE and NPAR to use
    within each of these, scored by the wiki's rules.
    """
    cpn = max(1, int(cpus_per_node))
    out: set[int] = set()

    # Whole nodes.
    n = cpn
    while n <= max_cores:
        if n >= min_cores:
            out.add(n)
        n += cpn

    # Sub-node sizes, for a job too small to earn a node. These never straddle
    # a boundary, so the rule above is not violated.
    f = cpn
    while f > 1:
        f //= 2
        if min_cores <= f <= max_cores:
            out.add(f)

    # If the cap is not a whole number of nodes, the largest usable count is
    # the last whole node under it -- asking for the remainder would allocate
    # the node anyway and leave part of it idle.
    if not out and min_cores <= max_cores:
        out.add(max(min_cores, min(max_cores, cpn)))

    return sorted(out)


# ============================================================================
# Scoring
# ============================================================================


def kpar_terms(kpar: int, irr_k: Optional[int],
               coverage_weight: float) -> Dict[str, float]:
    """The VASP-wiki KPAR rules, as scoring terms.

    Two sentences from https://vasp.at/wiki/index.php/Optimizing_the_parallelization
    carry the whole thing:

        "increase KPAR up to the number of irreducible k points.  Keep in
         mind that KPAR should factorize the number of k points."

    The first is a DIRECTIVE, and it is the only part that earns points here.
    The second is a CONSTRAINT on how to obey the first, so it is scored as
    the cost of breaking it and nothing else.  Scoring it as a reward instead
    -- which is what this function replaces -- handed the full bonus to
    KPAR = 1, because every integer divides by 1: the one setting that obeys
    the constraint precisely by refusing the directive.

    The cost is arithmetic, not a judgement.  https://vasp.at/wiki/index.php/KPAR
    says the k-points go out "in a round-robin fashion", so the busiest group
    ends up with ceil(NKPTS / KPAR) of them and every other group waits for
    it.  The fraction of the allocated core-time that buys nothing is then

        1 - NKPTS / (ceil(NKPTS / KPAR) * KPAR)

    which is zero exactly when KPAR factorizes NKPTS -- KPAR = 1 and
    KPAR = NKPTS included -- and rises as the split gets more lopsided.  It
    also scales the penalty with the damage: NKPTS = 190 over KPAR = 3 leaves
    groups of 64/63/63 and wastes 1 % of the job, while KPAR = 128 leaves
    groups of 2 and 1 and wastes 26 %.  The old pass/fail test could not tell
    those apart.

    `coverage_weight` is the peak value of the directive term, reached at
    KPAR = NKPTS.  It is engineering, not documentation: the wiki gives no
    numbers.  It is set to the weight the old divisibility bonus carried, so
    the scale of the total score is unchanged.
    """
    if not irr_k or irr_k <= 0 or kpar <= 0:
        return {}
    parts: Dict[str, float] = {}

    per_group = -(-irr_k // kpar)                 # ceil, in integers
    idle = 1.0 - irr_k / float(per_group * kpar)
    if idle > 1e-12:
        parts["kpar_does_NOT_factorise_nkpts"] = -60.0 * idle

    # "increase KPAR up to the number of irreducible k points" -- saturating,
    # because the same page warns that "the parallel efficiency of each level
    # drops near its limit" and that "the k-point parallelization ... requires
    # additional memory" (the memory terms below price that separately).
    parts["kpar_kpoint_coverage"] = coverage_weight * math.sqrt(
        min(1.0, kpar / float(irr_k))
    )
    return parts


def score_candidate(
    *,
    summary: DryRunSummary,
    partition_info: Dict[str, object],
    cpus_per_node: int,
    numa_cores: Optional[int],
    max_cores: int,
    candidate: Candidate,
) -> Tuple[float, Dict[str, float]]:
    """Compute a transparent score with named contributions (each in 'points').

    Larger is better.  The weights are calibrated so that:
      * a HARD wiki violation (e.g. KPAR > NKPTS) -> very large negative
      * the recommended setting (NCORE ~ sqrt(rpk), NCORE | NUMA) -> ~+25
      * KPAR at the wiki's ceiling of NKPTS -> +18 (see kpar_terms)
      * a memory-light layout that fits the partition default -> +5
      * throughput term: up to +5 for using the full account allowance
    """
    parts: Dict[str, float] = {}

    irr_k = summary.irr_kpoints or summary.nkpts
    nbands = summary.nbands
    natoms = summary.nions
    ngz = (summary.coarse_fft or summary.fine_fft or (0, 0, 0))[2] or None

    rpk = candidate.ranks_per_kgroup       # = total_ranks / KPAR = NPAR*NCORE

    # ---- 1. KPAR rules ---------------------------------------------------
    # KPAR must divide total_ranks (the enumerator guarantees this).
    if candidate.total_ranks % candidate.kpar != 0:
        parts["KPAR_must_divide_total_ranks_(HARD_RULE)"] = -1000.0

    # "increase KPAR up to the number of irreducible k points.  Keep in mind
    # that KPAR should factorize the number of k points."  See kpar_terms().
    parts.update(kpar_terms(candidate.kpar, irr_k, coverage_weight=18.0))

    # Gamma-only / NKPTS = 1: KPAR must be 1.
    if summary.is_gamma_only and candidate.kpar != 1:
        parts["gamma_only_requires_kpar_1_(HARD_RULE)"] = -200.0

    # The wiki's other sentence -- "For bulk systems with small unit cells,
    # NCORE = 1 and KPAR = NKPTS is optimal" -- used to be a +25 term of its
    # own, gated on NBANDS <= 64.  Both halves are gone deliberately.
    #
    # The gate was wrong: NBANDS counts electrons, not cell size, so it fired
    # on a heavy metal in a tiny cell and missed a light one in a big cell.
    # Cell VOLUME is not the fix either -- a 20-atom slab carrying 15 A of
    # vacuum is enormous by volume and small by every parallelization measure.
    # The honest proxy is the atom count, and the branch that uses it
    # (small_system_ncore_1_recipe, NIONS < 50) already exists below.
    #
    # And the term itself is now double-counting: "KPAR = NKPTS" is exactly
    # where kpar_terms() pays its ceiling, and "NCORE = 1" is what
    # small_system_ncore_1_recipe pays.  Scoring the conjunction a third time
    # said nothing new, it only shouted.  It existed as a counterweight to the
    # bonus KPAR = 1 used to collect for nothing; that bonus is gone, so the
    # counterweight goes with it.

    # ---- 2. NCORE rules --------------------------------------------------
    # NCORE should divide cores per node (FFTs stay intra-node).
    if cpus_per_node % candidate.ncore == 0:
        parts["ncore_divides_cpus_per_node"] = 8.0
    else:
        parts["ncore_does_NOT_divide_cpus_per_node"] = -15.0

    # Wiki recommendation (NCORE wiki page): NCORE ~ sqrt(available_ranks).
    if rpk > 0 and candidate.ncore > 0:
        ideal = max(1, int(round(math.sqrt(rpk))))
        delta = abs(candidate.ncore - ideal)
        # Bell-shaped reward; ideal -> +12, drops off quickly.
        parts["ncore_near_sqrt_available"] = 12.0 * math.exp(-delta * delta / 4.0)

    # NUMA-aware setting (NCORE wiki: "particularly good choice").
    if numa_cores and numa_cores > 0:
        if candidate.ncore == numa_cores:
            parts["ncore_equals_numa_size"] = 14.0
        elif candidate.ncore == numa_cores // 2 and numa_cores >= 4:
            parts["ncore_half_numa_size"] = 5.0

    # Wiki "Performance issues" guidance: NCORE for large atom counts.
    if natoms:
        if natoms > 400 and 12 <= candidate.ncore <= 16:
            parts["large_system_high_ncore_recipe"] = 10.0
        elif 100 <= natoms <= 400 and 4 <= candidate.ncore <= 12:
            parts["medium_system_moderate_ncore_recipe"] = 8.0
        elif natoms < 50 and candidate.ncore == 1:
            parts["small_system_ncore_1_recipe"] = 5.0

    # NCORE = available_ranks (== NPAR=1) is essentially never optimal.
    if candidate.npar == 1 and rpk > 1:
        parts["npar_1_no_band_parallelism_(HARD_PENALTY)"] = -60.0

    # ---- 3. NPAR / NBANDS load balance ----------------------------------
    if nbands and candidate.npar > 0:
        if candidate.npar > nbands:
            parts["npar_exceeds_nbands_(HARD_PENALTY)"] = -120.0
        elif nbands % candidate.npar == 0:
            parts["nbands_divisible_by_npar"] = 10.0
        else:
            padding = round_up_to_multiple(nbands, candidate.npar) - nbands
            parts["nbands_padding_penalty"] = -1.0 * padding

        bpg = candidate.bands_per_group
        if 4.0 <= bpg <= 16.0:
            parts["bands_per_group_sweet_spot"] = 10.0
        elif 2.0 <= bpg < 4.0 or 16.0 < bpg <= 32.0:
            parts["bands_per_group_acceptable"] = 4.0
        elif bpg < 1.0:
            parts["bands_per_group_too_few"] = -15.0
        elif bpg > 64.0:
            parts["bands_per_group_too_many"] = -6.0

    # ---- 4. k-group placement vs node / NUMA -----------------------------
    if numa_cores and numa_cores > 0:
        if rpk == numa_cores:
            parts["kgroup_equals_numa"] = 8.0
        elif rpk < numa_cores and numa_cores % rpk == 0:
            parts["kgroup_fits_inside_one_numa"] = 4.0
        elif rpk > numa_cores and rpk % numa_cores == 0:
            parts["kgroup_spans_integer_numas"] = 3.0
        elif rpk > numa_cores and numa_cores % rpk != 0 and rpk % numa_cores != 0:
            parts["kgroup_awkward_numa_layout"] = -4.0

    if rpk == cpus_per_node:
        parts["kgroup_equals_one_node"] = 6.0
    elif rpk < cpus_per_node and cpus_per_node % rpk == 0:
        parts["kgroup_fits_inside_one_node"] = 4.0
    elif rpk > cpus_per_node:
        if rpk % cpus_per_node == 0:
            parts["kgroup_spans_integer_nodes"] = 2.0
        else:
            parts["kgroup_straddles_node_boundary"] = -8.0

    # ---- 5. LPLANE / NGZ rule -------------------------------------------
    if ngz and candidate.npar > 0:
        threshold = 3.0 * candidate.nodes / candidate.npar
        if candidate.lplane:
            if ngz >= threshold:
                parts["lplane_TRUE_satisfies_ngz_rule"] = 3.0
            else:
                parts["lplane_TRUE_violates_ngz_rule_(PENALTY)"] = -10.0
            if ngz % candidate.npar == 0:
                parts["lplane_perfect_load_balance"] = 3.0
            if candidate.nodes >= 16:
                parts["lplane_TRUE_many_nodes_penalty"] = -3.0
        else:
            if candidate.nodes >= 16 or ngz < threshold:
                parts["lplane_FALSE_appropriate_for_layout"] = 3.0
            else:
                parts["lplane_FALSE_unnecessary_(SMALL_PENALTY)"] = -1.5
    else:
        # Default-on LPLANE is the VASP-wiki default.
        parts["lplane_default_preference"] = 1.5 if candidate.lplane else -1.5

    # ---- 6. NSIM ---------------------------------------------------------
    if candidate.nsim == 4:
        parts["nsim_4_cpu_default"] = 4.0
    elif candidate.nsim in (2, 8):
        parts["nsim_acceptable"] = 2.0
    elif candidate.nsim == 1:
        parts["nsim_1_slow_network_recipe"] = 1.0
    else:
        parts["nsim_unusual"] = -1.0

    # ---- 7. Memory feasibility ------------------------------------------
    # Memory cost is the binding constraint on clusters with small per-CPU RAM
    # budget (2839 MB on `main`).  The VASP wiki explicitly conditions the
    # "increase KPAR up to NKPTS" advice on "given sufficient memory" -- so
    # the penalties below have to be strong enough to overcome the +6
    # kpar_coverage bonus when KPAR maxing forces a memory-heavy layout.
    # Memory that exceeds the SLURM per-cpu DEFAULT is NOT penalised: a job that
    # can't fit one node is split across more nodes (compute_request_geometry), so
    # "exceeds partition default" is just a non-default allocation, not a failure.
    # (The old -40 MEMORY_EXCEEDS_PARTITION hard penalty is removed.) We keep only a
    # small REWARD for memory-light layouts that comfortably fit the default.
    mem = candidate.memory
    if mem.suggested_mem_per_cpu_mb > mem.partition_mem_per_cpu_mb:
        pass
    elif mem.suggested_mem_per_cpu_mb > 0.85 * mem.partition_mem_per_cpu_mb:
        pass
    elif mem.suggested_mem_per_cpu_mb < 0.5 * mem.partition_mem_per_cpu_mb:
        # Memory-efficient configurations get an explicit bonus.  This
        # rewards layouts (typically KPAR=1, moderate NCORE) that leave
        # plenty of headroom on the per-CPU RAM budget.
        parts["memory_well_below_partition_default"] = 5.0
    elif mem.suggested_mem_per_cpu_mb < 0.7 * mem.partition_mem_per_cpu_mb:
        parts["memory_comfortably_below_partition_default"] = 3.0

    # ---- 7b. The layout must be SUBMITTABLE ------------------------------
    # SLURM allocates whole nodes and charges nodes x cpus_per_node, so a
    # memory-hungry layout that needs few ranks per node can need more CORES
    # than the account allows even while its RANK count looks fine. That is how
    # a 48-rank GW job came out needing 6 nodes = 288 cores against a 48-core
    # cap: submittable nowhere, and nothing said so.
    #
    # Mirror the node split that compute_request_geometry will do, and price
    # the result. A candidate that cannot be submitted is worse than any
    # candidate that can, whatever its parallel efficiency.
    if max_cores and cpus_per_node > 0:
        _usage = max(float(mem.per_rank_mb), 1.0) * DEFAULT_RSS_OVERHEAD
        _node_mb = float(partition_info.get("mem_per_node_mb") or 0) or \
            float(mem.partition_mem_per_cpu_mb or 0) * cpus_per_node
        _by_use = max(1, int(_node_mb // max(_usage, 1.0)))
        _rpn = max(1, min(cpus_per_node, _by_use))
        _nodes = math.ceil(candidate.total_ranks / _rpn)
        _alloc = _nodes * cpus_per_node
        if _alloc > max_cores:
            parts["layout_EXCEEDS_account_core_cap_(HARD_RULE)"] = -500.0

    # ---- 8. Compactness / SLURM accounting -------------------------------
    if candidate.total_ranks % cpus_per_node == 0:
        parts["full_nodes_only"] = 3.0
    elif candidate.nodes >= 2 and candidate.total_ranks % candidate.ntasks_per_node != 0:
        parts["uneven_last_node"] = -2.0

    # ---- 9. Throughput term ----------------------------------------------
    # Reward using more ranks, sub-linearly (avoid blindly maximising cores
    # at huge memory cost; the memory penalty takes care of that case).
    parts["throughput_scaling"] = 5.0 * math.sqrt(
        candidate.total_ranks / max(1, max_cores)
    )

    score = float(sum(parts.values()))
    return score, parts


# ============================================================================
# Explanation strings (for the human-friendly "[WHY]" section)
# ============================================================================


def explain_contributions(parts: Dict[str, float], top: int = 10) -> List[str]:
    """Return human-readable lines explaining a candidate's score breakdown."""
    ordered = sorted(parts.items(), key=lambda kv: abs(kv[1]), reverse=True)[:top]
    out: List[str] = []
    for key, value in ordered:
        sign = "+" if value >= 0 else "-"
        label = key.replace("_", " ")
        out.append(f"  {sign}{abs(value):6.2f}  {label}")
    return out


# ============================================================================
# Candidate enumeration
# ============================================================================


def build_candidates(
    *,
    summary: DryRunSummary,
    min_cores: int,
    max_cores: int,
    partition_name: str,
    cpus_per_node: int,
    numa_cores: Optional[int],
    safety_factor: float,
    limit_kpar_to_irr: bool,
    nsim_choices: Sequence[int],
    strict_ncore_one: bool,
) -> List[Candidate]:
    """Enumerate all valid (total_ranks, KPAR, NCORE, NPAR, NSIM, LPLANE)."""
    if max_cores < min_cores or max_cores < 1:
        raise SystemExit("--max-cores must be >= --min-cores and >= 1.")

    partition_info = CLUSTER_PARTITIONS[partition_name]
    part_mem_per_cpu = int(partition_info["mem_per_cpu_mb"])  # type: ignore[arg-type]

    irr_k = summary.irr_kpoints or summary.nkpts

    rank_choices = suggest_total_ranks(
        min_cores=min_cores,
        max_cores=max_cores,
        cpus_per_node=cpus_per_node,
        irr_kpoints=irr_k,
        nbands=summary.nbands,
    )

    # Upper bound on NCORE: number of cores per node (intra-node FFTs).
    # We don't let NCORE exceed cpus_per_node (each band group should fit on
    # one node).
    ncore_cap = cpus_per_node

    candidates: List[Candidate] = []
    for total_ranks in rank_choices:
        ntasks_per_node = min(total_ranks, cpus_per_node)
        nodes = max(1, math.ceil(total_ranks / ntasks_per_node))

        # KPAR enumeration: divisors of total_ranks; capped to NKPTS by default.
        kpar_choices = positive_divisors(total_ranks)
        if summary.is_gamma_only:
            kpar_choices = [1]
        elif limit_kpar_to_irr and irr_k:
            filtered = [k for k in kpar_choices if k <= max(1, irr_k)]
            if filtered:
                kpar_choices = filtered

        for kpar in kpar_choices:
            rpk = total_ranks // kpar
            if rpk <= 0:
                continue

            # NCORE choices: divisors of rpk, up to ncore_cap.
            if strict_ncore_one:
                ncore_choices = [1]
            else:
                ncore_choices = [c for c in positive_divisors(rpk) if c <= ncore_cap]
                # Cap to a sensible upper bound: 2x NUMA size, else cores/node.
                if numa_cores and numa_cores > 0:
                    soft_cap = min(ncore_cap, 2 * numa_cores)
                    ncore_choices = [c for c in ncore_choices if c <= soft_cap]

            for ncore in ncore_choices:
                npar = rpk // ncore
                if npar <= 0 or rpk % ncore != 0:
                    continue
                # Cannot have more band groups than bands.
                if summary.nbands and npar > summary.nbands:
                    continue

                bpg = (summary.nbands / npar) if summary.nbands else 0.0
                effective_nbands = (
                    round_up_to_multiple(summary.nbands, npar)
                    if summary.nbands else 0
                )

                memory = estimate_memory(
                    summary=summary,
                    total_ranks=total_ranks,
                    kpar=kpar,
                    ncore=ncore,
                    npar=npar,
                    partition_mem_per_cpu_mb=part_mem_per_cpu,
                    safety_factor=safety_factor,
                )

                for nsim in nsim_choices:
                    for lplane in (True, False):
                        cand = Candidate(
                            score=0.0,
                            total_ranks=total_ranks,
                            kpar=kpar,
                            ncore=ncore,
                            npar=npar,
                            nsim=nsim,
                            lplane=lplane,
                            ranks_per_kgroup=rpk,
                            bands_per_group=bpg,
                            effective_nbands=effective_nbands,
                            nodes=nodes,
                            ntasks_per_node=ntasks_per_node,
                            cpu_bind="cores",
                            memory=memory,
                        )
                        score, parts = score_candidate(
                            summary=summary,
                            partition_info=partition_info,
                            cpus_per_node=cpus_per_node,
                            numa_cores=numa_cores,
                            max_cores=max_cores,
                            candidate=cand,
                        )
                        cand.score = score
                        cand.contributions = parts
                        cand.reasons = explain_contributions(parts)
                        candidates.append(cand)

    candidates.sort(key=lambda c: c.sort_key)
    return candidates


def best_per_total_ranks(candidates: Sequence[Candidate]) -> List[Candidate]:
    """Keep only the highest-scoring candidate per total_ranks value."""
    seen: Dict[int, Candidate] = {}
    for c in candidates:
        prev = seen.get(c.total_ranks)
        if prev is None or c.score > prev.score:
            seen[c.total_ranks] = c
    return sorted(seen.values(), key=lambda c: c.sort_key)


# ============================================================================
# GW / RPA memory model and candidate enumeration
# ============================================================================
#
# Two regimes, recognised automatically (see detect_calculation_type):
#
#   * CONVENTIONAL (quartic-scaling) GW -- ALGO in {G0W0, GW0, EVGW0, QPGW0,
#     GW, EVGW, QPGW}.  The GW step parallelises ONLY over k-points (KPAR).
#     NCORE / NPAR > 1 do not accelerate the GW part, so we pin NCORE = 1 and
#     enumerate KPAR over the divisors of total_ranks (capped to NKPTS).  The
#     per-rank memory profile is close enough to the DFT one that we reuse the
#     existing OUTCAR-anchored estimate_memory() with ncore=1.
#       Refs: https://vasp.at/wiki/Practical_guide_to_GW_calculations
#             https://vasp.at/wiki/NCORE  (band-FFT distribution unused for GW)
#
#   * LOW-SCALING / space-time GW & RPA -- ALGO in {G0W0R, EVGW0R, GW0R, GWR}
#     or {ACFDTR, RPAR}.  The imaginary time/frequency grid NOMEGA is split
#     into NTAUPAR * NOMEGAPAR groups (both must divide NOMEGA); NTAUPAR drives
#     memory and runtime.  VASP recommends setting MAXMEM and letting it pick
#     NTAUPAR/NOMEGAPAR.  Per-rank memory follows the wiki formula
#         bytes ~ (Pi_exx * Pi_supercell) / (NCPU / NTAUPAR) * 16
#     with Pi_* the products of the two reported FFT grids.
#       Refs: https://vasp.at/wiki/Practical_guide_to_GW_calculations
#             https://vasp.at/wiki/NTAUPAR  https://vasp.at/wiki/NOMEGAPAR


def estimate_lowscaling_gw_memory(
    *,
    summary: DryRunSummary,
    total_ranks: int,
    ntaupar: int,
    ranks_per_node: int,
    partition_mem_per_cpu_mb: int,
    safety_factor: float,
) -> MemoryEstimate:
    """Per-rank / per-node memory for a low-scaling GW or RPA layout.

    Implements the VASP-documented estimate
    (https://vasp.at/wiki/Practical_guide_to_GW_calculations):

        bytes_per_rank ~ (NGX*NGY*NGZ)_exx * (NGX*NGY*NGZ)_supercell
                         / ( NCPU / NTAUPAR ) * 16

    The two grids are the "FFT grid for exact exchange (Hartree Fock)" and the
    "FFT grid for supercell" lines.  If the dry run was produced with
    ALGO=None (the grids are then absent), we fall back to a coarse proxy
    built from the fine FFT grid and flag it; in that case the user should do
    a brief REAL low-scaling dry run so VASP prints the grids and its own
    "min. memory requirement per mpi rank ... per node ..." line, which is
    authoritative.
    """
    est = MemoryEstimate(partition_mem_per_cpu_mb=partition_mem_per_cpu_mb)
    est.model = "gw-lowscaling-formula"
    if total_ranks <= 0 or ntaupar <= 0:
        return est

    # Determine the two grid-point products.
    if summary.fft_exx is not None and summary.fft_supercell is not None:
        ex = summary.fft_exx
        sc = summary.fft_supercell
        prod_exx = float(ex[0] * ex[1] * ex[2])
        prod_sc = float(sc[0] * sc[1] * sc[2])
        est.gw_grid_source = "outcar-grids"
    else:
        # Proxy: use the fine (or coarse) FFT grid for both factors.  This is
        # only an order-of-magnitude stand-in until a real GW dry run is done.
        grid = summary.fine_fft or summary.coarse_fft
        if grid is None:
            est.gw_grid_source = "unknown"
            return est
        prod = float(grid[0] * grid[1] * grid[2])
        # The supercell grid is typically smaller than the HF grid; assume the
        # HF grid ~ this grid and the supercell grid ~ (this grid)/8 as a rough,
        # deliberately conservative-ish proxy.
        prod_exx = prod
        prod_sc = prod / 8.0
        est.gw_grid_source = "fine-fft-proxy"

    cores_per_tau_group = max(1.0, total_ranks / float(ntaupar))
    bytes_per_rank = prod_exx * prod_sc / cores_per_tau_group * 16.0
    grid_term_mb = bytes_per_rank / (1024.0 ** 2)

    est.gw_grid_term_mb = grid_term_mb
    # Fixed overhead per rank (orbitals, projectors, FFT plans, MPI buffers).
    fixed_overhead_mb = 250.0
    base_sum = grid_term_mb + fixed_overhead_mb

    # If VASP already printed its own per-rank number for THIS layout, trust it
    # as a floor (never predict below VASP's own estimate).
    if summary.vasp_min_mem_per_rank_mb is not None:
        base_sum = max(base_sum, summary.vasp_min_mem_per_rank_mb)

    est.wavefun_mb = grid_term_mb          # reuse the slot for display continuity
    est.base_mb = fixed_overhead_mb
    est.safety_mb = (max(safety_factor, 1.0) - 1.0) * base_sum + 100.0
    est.per_rank_mb = base_sum + est.safety_mb
    est.gw_per_node_mb = est.per_rank_mb * max(1, ranks_per_node)
    est.total_job_mb = est.per_rank_mb * total_ranks
    est.suggested_mem_per_cpu_mb = round_up_mem(est.per_rank_mb)
    # MAXMEM is the per-rank memory budget VASP should assume.  Recommend the
    # partition's per-CPU RAM (slightly discounted for safety) so VASP's own
    # NTAUPAR/NOMEGAPAR auto-selection lands inside the node budget.
    est.maxmem_mb = int(max(200, math.floor(0.92 * partition_mem_per_cpu_mb)))
    est.fits_partition = (
        est.suggested_mem_per_cpu_mb <= 1.5 * partition_mem_per_cpu_mb
    )
    return est


def estimate_conventional_gw_memory(
    *,
    summary: DryRunSummary,
    total_ranks: int,
    kpar: int,
    ncore: int,
    npar: int,
    partition_mem_per_cpu_mb: int,
    safety_factor: float,
    mem_util: float = 0.80,
    gw_peak_factor: float = 8.0,
    ref: Optional[Dict[str, float]] = None,
    ref_ranks_override: Optional[int] = None,
    ref_encutgw_override: Optional[float] = None,
    anchor_override: Optional[float] = None,
) -> MemoryEstimate:
    """Per-rank memory FLOOR for a CONVENTIONAL (quartic-scaling) GW layout.

    NOT flat x factor (that model is gone -- it ignored that the GW floor is
    NOMEGA-independent and under-counted the response block, causing repeated OOM).
    The floor is anchored to VASP's own measured "min. memory requirement per mpi
    rank" and scaled by the physical exponents (see gw_floor_per_rank_mb):

        R(rpk, ENCUTGW) = anchor_mb * (anchor_rpk / rpk) * (ENCUTGW / anchor_encutgw)^3

    NOMEGA does NOT appear (the floor is one response block; NOMEGA only batches more
    for SPEED, bounded by MAXMEM). If VASP already printed its own per-rank number for
    THIS OUTCAR (a real/failed GW run), we take max(formula, VASP's number) -- never
    predict below VASP's own floor. `anchor_override` (a harvested measured floor) and
    `ref_encutgw_override` pin the level to reality; `gw_peak_factor`/`ref_ranks`/`ref`
    are accepted for call-site compatibility but unused by the floor model.
    """
    rpk = max(1.0, total_ranks / float(max(1, kpar)))
    encutgw = float(summary.encutgw or summary.encut or GW_FLOOR_ANCHOR_ENCUTGW)
    anchor_mb = float(anchor_override or GW_FLOOR_ANCHOR_MB)
    anchor_encutgw = float(ref_encutgw_override or GW_FLOOR_ANCHOR_ENCUTGW)

    floor = gw_floor_per_rank_mb(rpk, encutgw, anchor_mb=anchor_mb,
                                 anchor_encutgw=anchor_encutgw)
    src = (f"real-RSS floor {floor:.0f} MB/rank = anchor {anchor_mb:.0f} MB @ "
           f"{GW_FLOOR_ANCHOR_RPK:.0f} ranks/kgrp,{anchor_encutgw:.0f} eV "
           f"x ({GW_FLOOR_ANCHOR_RPK:.0f}/{rpk:.0f}) x ({encutgw:.0f}/{anchor_encutgw:.0f})^3 "
           f"(NOMEGA-independent)")
    # If this OUTCAR is a real/failed GW run, PROVISION TO VASP's printed requirement
    # (GW_VASP_REQ_TO_RSS = 1.0, no discount -- a discount OOM'd at NOMEGA=100).
    if summary.vasp_min_mem_per_rank_mb:
        vasp_need = summary.vasp_min_mem_per_rank_mb * GW_VASP_REQ_TO_RSS
        if vasp_need > floor:
            src = (f"VASP's own required memory {vasp_need:.0f} MB/rank "
                   f"(formula floor was {floor:.0f})")
            floor = vasp_need

    est = MemoryEstimate(partition_mem_per_cpu_mb=partition_mem_per_cpu_mb)
    est.model = "gw-conventional-floor (anchored, NOMEGA-independent)"
    est.gw_grid_source = src
    est.base_mb = floor
    est.gw_grid_term_mb = 0.0
    est.safety_mb = 0.0
    est.per_rank_mb = floor
    # MAXMEM is DERIVED from the per-rank allocation (= floor / mem_util request), NOT
    # chased. See gw_maxmem_from_request. compute_request_geometry/vasp-test recompute it
    # from the final mem-per-cpu; this is just the first-pass value for the INCAR snippet.
    _req = floor / max(mem_util, 0.05)
    est.maxmem_mb = gw_maxmem_from_request(_req)
    # Per-node need: a whole k-group (rpk ranks) on one node -- this is what must fit.
    est.gw_per_node_mb = floor * rpk
    est.total_job_mb = floor * total_ranks
    est.suggested_mem_per_cpu_mb = round_up_mem(floor)
    est.fits_partition = est.suggested_mem_per_cpu_mb <= 1.5 * partition_mem_per_cpu_mb
    return est


def _gw_divisor_pairs(nomega: int) -> List[Tuple[int, int]]:
    """All (NTAUPAR, NOMEGAPAR) pairs that both divide NOMEGA.

    Per the wiki both tags must be divisors of NOMEGA.  We return every such
    pair (the product need not equal NOMEGA); the builder filters them against
    the available rank count.
    """
    divs = positive_divisors(nomega)
    return [(t, w) for t in divs for w in divs]


def score_gw_candidate(
    *,
    summary: DryRunSummary,
    partition_info: Dict[str, object],
    cpus_per_node: int,
    numa_cores: Optional[int],
    max_cores: int,
    candidate: Candidate,
) -> Tuple[float, Dict[str, float]]:
    """Transparent score for a GW / RPA candidate (larger is better).

    The lever depends on the regime:
      * conventional GW -> KPAR (NCORE pinned to 1).
      * low-scaling GW/RPA -> KPAR plus NTAUPAR/NOMEGAPAR (divisors of NOMEGA).
    Memory feasibility uses the same partition-budget penalties as the DFT
    path so a layout that does not fit is strongly down-ranked.
    """
    parts: Dict[str, float] = {}
    irr_k = summary.irr_kpoints or summary.nkpts
    low = candidate.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")

    # ---- KPAR rules (shared) --------------------------------------------
    if candidate.total_ranks % candidate.kpar != 0:
        parts["KPAR_must_divide_total_ranks_(HARD_RULE)"] = -1000.0
    if summary.is_gamma_only and candidate.kpar != 1:
        parts["gamma_only_requires_kpar_1_(HARD_RULE)"] = -200.0
    # Same wiki rules as the DFT path (see kpar_terms()).  The directive is
    # worth more here: with NCORE pinned to 1, conventional GW has no FFT
    # level to fall back on, so KPAR is nearly the whole parallelization.
    # Low-scaling GW/RPA shares the budget with NTAUPAR/NOMEGAPAR, scored
    # below, so its KPAR directive is weighted lower.
    parts.update(kpar_terms(candidate.kpar, irr_k,
                            coverage_weight=20.0 if not low else 12.0))

    # ---- NCORE must be 1 for GW -----------------------------------------
    if candidate.ncore != 1:
        parts["gw_requires_ncore_1_(HARD_RULE)"] = -300.0
    else:
        parts["gw_ncore_1_ok"] = 4.0

    # ---- Conventional GW: cores per k-group ------------------------------
    rpk = candidate.ranks_per_kgroup
    if not low:
        # Each k-point group's ranks parallelise the internal Exact/diagonalisation
        # over the (typically hundreds of) GW bands. Too FEW ranks per group is the
        # killer: it's slow AND memory-heavy per rank, which is why a high KPAR with
        # a tiny k-group (e.g. rpk=3) is a bad layout. So penalise small k-groups and
        # reward bigger ones (up to ~a NUMA-to-node size), which steers KPAR to a
        # sane value rather than the largest divisor of NKPTS.
        if rpk < 8 and (irr_k or 0) > 1:
            parts["gw_kgroup_too_small_(few_band_ranks)"] = -10.0
        elif rpk <= cpus_per_node:
            parts["gw_healthy_kgroup_size"] = 6.0 + 8.0 * min(1.0, rpk / 32.0)
        if rpk <= cpus_per_node:
            parts["gw_kgroup_fits_one_node"] = 3.0
        elif rpk % cpus_per_node != 0:
            parts["gw_kgroup_straddles_node_(PENALTY)"] = -8.0

    # ---- Low-scaling GW/RPA: NTAUPAR / NOMEGAPAR -------------------------
    if low:
        nomega = candidate.nomega or summary.nomega
        t = candidate.ntaupar or 1
        w = candidate.nomegapar or 1
        if nomega:
            if nomega % t == 0:
                parts["ntaupar_divides_nomega"] = 10.0
            else:
                parts["ntaupar_NOT_divisor_of_nomega_(HARD)"] = -80.0
            if nomega % w == 0:
                parts["nomegapar_divides_nomega"] = 6.0
            else:
                parts["nomegapar_NOT_divisor_of_nomega_(HARD)"] = -60.0
        # The τ/ω groups partition the available ranks: NTAUPAR*NOMEGAPAR must
        # divide the per-k-group rank count.
        if rpk % max(1, t * w) == 0:
            parts["tau_omega_groups_partition_ranks"] = 8.0
        else:
            parts["tau_omega_groups_do_NOT_fit_ranks_(HARD)"] = -120.0
        # Larger NTAUPAR is faster (VASP defaults to the largest that fits in
        # MAXMEM); reward it, but only when memory actually fits (handled by
        # the memory penalties below).
        if nomega:
            parts["ntaupar_speed_preference"] = 6.0 * math.sqrt(
                min(1.0, t / max(1, nomega))
            )

    # ---- Conventional GW: node PACKING (memory feasibility per node) -------
    # The GW floor per rank scales as 1/ranks-per-k-group, so a small k-group
    # (large KPAR with few total ranks) blows the per-rank memory up and forces
    # the job onto many nodes (1 rank/node in the worst case). Strongly favour
    # layouts that pack MANY ranks per node; this is what makes a sane KPAR
    # (big k-groups) beat a memory-infeasible high-KPAR layout.
    if not low and candidate.memory.suggested_mem_per_cpu_mb > 0:
        _node_mb = 0.0
        try:
            _node_mb = float(partition_info.get("node_mem_mb") or 0)
        except (TypeError, ValueError):
            _node_mb = 0.0
        if _node_mb > 0:
            ranks_fit = 0.95 * _node_mb / candidate.memory.suggested_mem_per_cpu_mb
            if ranks_fit < 1.0:
                parts["gw_per_rank_too_big_for_node_(HARD)"] = -60.0
            else:
                parts["gw_node_packing"] = 22.0 * min(1.0, ranks_fit / 24.0)

    # ---- Memory: NO partition-default penalty for GW --------------------
    # GW per-rank memory is large by nature and always exceeds the SLURM per-cpu
    # default; that is NOT a problem -- a job that can't fit one node is split
    # across KPAR nodes (see group_fits_node + compute_request_geometry). The real
    # constraint (a whole k-group must fit a node) is the hard FEASIBILITY filter in
    # main(); here we do not penalise high memory at all.

    # ---- Compactness / SLURM accounting ---------------------------------
    if candidate.total_ranks % cpus_per_node == 0:
        parts["full_nodes_only"] = 3.0
    elif candidate.nodes >= 2 and candidate.total_ranks % candidate.ntasks_per_node != 0:
        parts["uneven_last_node"] = -2.0

    # ---- Throughput term -------------------------------------------------
    parts["throughput_scaling"] = 5.0 * math.sqrt(
        candidate.total_ranks / max(1, max_cores)
    )

    # ---- the layout must be SUBMITTABLE (same rule as the DFT path) -------
    # GW is where this bites hardest: the per-rank floor is large, so few ranks
    # fit a node, so the job spreads over many -- and SLURM charges whole nodes.
    # A 48-rank job on 6 nodes is 288 cores against a 48-core cap: it cannot be
    # submitted anywhere, however good its k-point parallelism looks.
    if max_cores and cpus_per_node > 0:
        _usage = max(float(candidate.memory.per_rank_mb), 1.0)
        _node_mb = float(partition_info.get("mem_per_node_mb") or 0) or \
            float(candidate.memory.partition_mem_per_cpu_mb or 0) * cpus_per_node
        _rpn = max(1, min(cpus_per_node, int(_node_mb // max(_usage, 1.0))))
        if math.ceil(candidate.total_ranks / _rpn) * cpus_per_node > max_cores:
            parts["layout_EXCEEDS_account_core_cap_(HARD_RULE)"] = -500.0

    score = float(sum(parts.values()))
    return score, parts


def build_gw_candidates(
    *,
    summary: DryRunSummary,
    min_cores: int,
    max_cores: int,
    partition_name: str,
    cpus_per_node: int,
    numa_cores: Optional[int],
    safety_factor: float,
    limit_kpar_to_irr: bool,
    recommend_maxmem: bool,
    gw_anchor_override: Optional[float] = None,
    gw_ref_ranks_override: Optional[int] = None,
    gw_ref_encutgw_override: Optional[float] = None,
) -> List[Candidate]:
    """Enumerate GW / RPA layouts (NCORE pinned to 1).

    Conventional GW: vary total_ranks and KPAR (divisor of total_ranks, capped
    to NKPTS by default).  Low-scaling GW/RPA: additionally vary the
    (NTAUPAR, NOMEGAPAR) divisor pair of NOMEGA, keeping NTAUPAR*NOMEGAPAR a
    divisor of the per-k-group rank count.
    """
    if max_cores < min_cores or max_cores < 1:
        raise SystemExit("--max-cores must be >= --min-cores and >= 1.")

    partition_info = CLUSTER_PARTITIONS[partition_name]
    part_mem_per_cpu = int(partition_info["mem_per_cpu_mb"])  # type: ignore[arg-type]
    irr_k = summary.irr_kpoints or summary.nkpts
    low = summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")

    rank_choices = suggest_total_ranks(
        min_cores=min_cores,
        max_cores=max_cores,
        cpus_per_node=cpus_per_node,
        irr_kpoints=irr_k,
        nbands=summary.nbands,
    )

    # NOMEGA is required to enumerate τ/ω splits for low-scaling.  If it was
    # not parsed, fall back to MAXMEM-only (no explicit NTAUPAR/NOMEGAPAR).
    nomega = summary.nomega
    pairs = _gw_divisor_pairs(nomega) if (low and nomega) else [(1, 1)]

    candidates: List[Candidate] = []
    for total_ranks in rank_choices:
        ntasks_per_node = min(total_ranks, cpus_per_node)
        nodes = max(1, math.ceil(total_ranks / ntasks_per_node))

        kpar_choices = positive_divisors(total_ranks)
        if summary.is_gamma_only:
            kpar_choices = [1]
        elif limit_kpar_to_irr and irr_k:
            filtered = [k for k in kpar_choices if k <= max(1, irr_k)]
            if filtered:
                kpar_choices = filtered

        for kpar in kpar_choices:
            rpk = total_ranks // kpar          # ranks per k-point group
            if rpk <= 0:
                continue
            ncore = 1
            npar = rpk                          # NCORE=1 => NPAR = available

            if not low:
                # One conventional-GW candidate per (total_ranks, KPAR).
                memory = estimate_conventional_gw_memory(
                    summary=summary,
                    total_ranks=total_ranks,
                    kpar=kpar,
                    ncore=ncore,
                    npar=npar,
                    partition_mem_per_cpu_mb=part_mem_per_cpu,
                    safety_factor=safety_factor,
                    ref_ranks_override=gw_ref_ranks_override,
                    ref_encutgw_override=gw_ref_encutgw_override,
                    anchor_override=gw_anchor_override,
                )
                cand = Candidate(
                    score=0.0, total_ranks=total_ranks, kpar=kpar, ncore=ncore,
                    npar=npar, nsim=4, lplane=True, ranks_per_kgroup=rpk,
                    bands_per_group=(summary.nbands / npar) if summary.nbands else 0.0,
                    effective_nbands=(round_up_to_multiple(summary.nbands, npar)
                                      if summary.nbands else 0),
                    nodes=nodes, ntasks_per_node=ntasks_per_node, cpu_bind="cores",
                    memory=memory, calc_type=summary.calc_type, nomega=summary.nomega,
                    recommend_maxmem=recommend_maxmem,
                )
                score, p = score_gw_candidate(
                    summary=summary, partition_info=partition_info,
                    cpus_per_node=cpus_per_node, numa_cores=numa_cores,
                    max_cores=max_cores, candidate=cand)
                cand.score = score
                cand.contributions = p
                cand.reasons = explain_contributions(p)
                candidates.append(cand)
                continue

            # Low-scaling: enumerate (NTAUPAR, NOMEGAPAR) divisor pairs that
            # partition the per-k-group rank count.
            for (t, w) in pairs:
                if rpk % (t * w) != 0:
                    continue
                # If NOMEGA is unknown we only iterate the (1,1) sentinel and
                # present a MAXMEM-only recommendation (knobs shown as None).
                knob_t: Optional[int] = t if summary.nomega else None
                knob_w: Optional[int] = w if summary.nomega else None
                memory = estimate_lowscaling_gw_memory(
                    summary=summary,
                    total_ranks=total_ranks,
                    ntaupar=t,
                    ranks_per_node=ntasks_per_node,
                    partition_mem_per_cpu_mb=part_mem_per_cpu,
                    safety_factor=safety_factor,
                )
                cand = Candidate(
                    score=0.0, total_ranks=total_ranks, kpar=kpar, ncore=ncore,
                    npar=npar, nsim=4, lplane=True, ranks_per_kgroup=rpk,
                    bands_per_group=0.0, effective_nbands=0, nodes=nodes,
                    ntasks_per_node=ntasks_per_node, cpu_bind="cores",
                    memory=memory, calc_type=summary.calc_type, nomega=summary.nomega,
                    ntaupar=knob_t, nomegapar=knob_w, recommend_maxmem=recommend_maxmem,
                )
                score, p = score_gw_candidate(
                    summary=summary, partition_info=partition_info,
                    cpus_per_node=cpus_per_node, numa_cores=numa_cores,
                    max_cores=max_cores, candidate=cand)
                cand.score = score
                cand.contributions = p
                cand.reasons = explain_contributions(p)
                candidates.append(cand)

    candidates.sort(key=lambda c: c.sort_key)
    return candidates


# ============================================================================
# SLURM template
# ============================================================================


def pick_executable(summary: DryRunSummary, override: Optional[str],
                    std_default: Optional[str] = None,
                    gam_default: Optional[str] = None,
                    ncl_default: Optional[str] = None) -> str:
    """Choose the VASP binary: --executable override > the vasp-configure profile
    (WP_VASP_STD / WP_VASP_GAM -- a custom build configured ONCE is inherited by every
    generated job + state.env, so vasp-test/magic run the same binary) > auto."""
    if override:
        return override
    # Non-collinear is checked FIRST: vasp_ncl is required regardless of how many
    # k-points there are, and there is no gamma-only non-collinear binary.
    if summary.is_noncollinear:
        return ncl_default or "vasp_ncl"
    if summary.is_gamma_only:
        return gam_default or "vasp_gam"
    return std_default or "vasp_std"


def _node_mem_mb(partition_info: Dict[str, object], fallback_mem_per_cpu: int) -> int:
    """Total RAM per node (MB): from the profile, else cpus_per_node x mem/cpu."""
    nm = partition_info.get("node_mem_mb")
    if nm:
        return int(nm)                                       # type: ignore[arg-type]
    cpn = int(partition_info.get("cpus_per_node", 1))        # type: ignore[arg-type]
    mpc = int(partition_info.get("mem_per_cpu_mb", fallback_mem_per_cpu))  # type: ignore[arg-type]
    return cpn * mpc


def _node_reserve_mb(partition_info: Dict[str, object], margin: float) -> int:
    """RAM (MB) to keep FREE on each node = margin x node RAM.

    `margin` is the fraction from vasp-configure (WP_MAIN_MEM_MARGIN): 0.02 leaves
    2% of the node free, i.e. 98% is usable. Expressed as a fraction rather than an
    absolute figure so one profile fits nodes of any size."""
    if margin <= 0:
        return 0
    nm = _node_mem_mb(partition_info, 0)
    return int(max(0.0, min(margin, 0.5)) * nm)


def group_fits_node(candidate: "Candidate", node_mem_mb: int,
                    cpus_per_node: int) -> bool:
    """Can a WHOLE k-point group run on one node? For GW this is MANDATORY: a
    k-group split across nodes means cross-node chi/W traffic, so a config whose
    group cannot fit a node is INFEASIBLE on this cluster. DFT has no such
    constraint (it may spread by memory freely), so it is always 'feasible' here.

    A group of `rpk` ranks fits iff it fits by cores AND by memory at the model's
    per-rank estimate (real RSS; vasp-test re-checks this with MEASURED memory)."""
    if candidate.calc_type == "DFT":
        return True
    rpk = max(1, candidate.ranks_per_kgroup
              or (candidate.total_ranks // max(1, candidate.kpar)))
    usage = max(1.0, candidate.memory.per_rank_mb)
    return rpk <= cpus_per_node and rpk * usage <= node_mem_mb


def calibrate_gw_memory(candidates: Sequence["Candidate"], measured_mb: float,
                        ref_ranks: int, ref_kpar: Optional[int],
                        mem_util: float) -> bool:
    """Scale every GW candidate's memory so the candidate matching the reference
    layout (ref_ranks, ref_kpar) predicts the MEASURED per-rank peak. Used by
    vasp-test's auto-recovery: the model SHAPE (how memory scales with the layout)
    is trusted, but the absolute level is pinned to the real measurement, so the
    re-pick's feasibility/sizing reflect reality. Returns True if calibrated."""
    refs = [c for c in candidates if c.total_ranks == ref_ranks
            and (ref_kpar is None or c.kpar == ref_kpar) and c.calc_type != "DFT"]
    if not refs or refs[0].memory.per_rank_mb <= 0:
        return False
    cal = measured_mb / refs[0].memory.per_rank_mb
    if cal <= 0:
        return False
    for c in candidates:
        if c.calc_type == "DFT":
            continue
        m = c.memory
        m.per_rank_mb *= cal
        m.base_mb *= cal
        m.gw_grid_term_mb *= cal
        rpk = c.ranks_per_kgroup or (c.total_ranks // max(1, c.kpar))
        m.gw_per_node_mb = m.per_rank_mb * max(1, rpk)
        m.total_job_mb = m.per_rank_mb * c.total_ranks
        m.suggested_mem_per_cpu_mb = round_up_mem(m.per_rank_mb)
        # MAXMEM stays DERIVED (mem-per-cpu - reserve), consistent with the floor model.
        m.maxmem_mb = gw_maxmem_from_request(m.per_rank_mb / max(mem_util, 0.05))
    return True


# Real resident memory (RSS) is consistently LARGER than the per-rank figure
# VASP reports in the OUTCAR: FFTW plans/scratch, MPI/UCX communication buffers,
# the scaLAPACK/ELPA workspace and the allocator's high-water mark are not in
# VASP's table. Across DFT runs this gap is ~1.3-2x; for GW/RPA it is much
# larger (the chi/W arrays dwarf the DFT table). We therefore scale the model's
# per-rank estimate by this factor before sizing the request, so the dry-run
# recommendation is a *safe* starting point. vasp-test then replaces it with the
# measured value. Override with --rss-overhead / WP_RSS_OVERHEAD.
DEFAULT_RSS_OVERHEAD = 1.4


def compute_request_geometry(candidate: "Candidate",
                             partition_info: Dict[str, object],
                             mem_util: float = 0.80,
                             reserve_mb: int = 0,
                             rss_overhead: float = DEFAULT_RSS_OVERHEAD,
                             gw_node_frac: float = 0.0,
                             max_cores: Optional[int] = None):
    """Size the memory request and node layout for the cluster policy.

    Returns (mem_per_cpu, nodes, ntasks_per_node, node_mem_mb).

      * the model per-rank estimate is first multiplied by `rss_overhead` (the
        documented gap between VASP's reported memory and real RSS);
      * mem_per_cpu then honours the minimum memory-UTILISATION policy: we
        request so predicted usage is `mem_util` of the allocation
        (request = usage / mem_util). With mem_util=0.80 the job is sized to use
        ~80% of what it asks for (and keeps ~20% safety headroom);
      * if a single node cannot hold its ranks at that mem-per-cpu, the job is
        SPLIT across more nodes (fewer ranks per node) so every node fits --
        per https://www.vasp.at/wiki/index.php/Category:Parallelization the
        rank count is unchanged; only the rank-to-node mapping spreads out;
      * `reserve_mb` keeps that much RAM free per node (e.g. debug/login nodes);
      * GW SWEET sizing (`gw_node_frac` > 0, non-DFT only): the per-rank request
        is RAISED to gw_node_frac x node_mem / ranks-per-node -- spending the
        queue-friendly share of the node on a bigger frozen MAXMEM (= mem-per-cpu
        - 3 GB), which buys frequency-block batching speed. Safe at any level:
        VASP's demand is ~MAXMEM + 2.1 GB (measured law), so it always lands
        ~0.9 GB under the allocation. The fraction (default 0.67 from
        WP_GW_NODE_FRAC) keeps ~1/3 of each node free so the job still backfills
        in the queue; 0 disables (pure need-based sizing).
    """
    # GW floors are already REAL RSS (anchored to measured runs), so do NOT apply
    # the table->RSS overhead that the DFT table-based estimate needs.
    _over = 1.0 if candidate.calc_type != "DFT" else max(rss_overhead, 1.0)
    usage = max(float(candidate.memory.per_rank_mb), 1.0) * _over   # predicted REAL RSS/rank
    desired = max(200, round_up_mem(usage / max(mem_util, 0.05)))   # >= mem_util-utilisation request
    if getattr(candidate, "recommend_maxmem", False) and candidate.memory.maxmem_mb:
        desired = max(desired, candidate.memory.maxmem_mb + 150)

    cpn = int(partition_info.get("cpus_per_node", candidate.ntasks_per_node) or 1)
    node_mem = _node_mem_mb(partition_info, desired)
    usable = max(desired, node_mem - max(reserve_mb, 0))
    total = max(candidate.total_ranks, 1)

    # Per-node ceiling from the REAL predicted USAGE, not the padded request: a whole
    # k-group can fit a node at its actual RSS even when request*ranks would overflow
    # it. We then TRIM the request (never below usage) so the group fits, instead of
    # spilling onto an extra node and straddling the k-group.
    by_use = max(1, usable // max(int(math.ceil(usage)), 1))
    cap = max(1, min(cpn, by_use))                           # ranks-per-node ceiling at REAL usage

    # Node layout rule: if the WHOLE job fits one node, use one node; otherwise split
    # across exactly KPAR nodes -- one whole k-point group per node (never straddle a
    # group: for GW that means cross-node chi/W communication). Only when even that is
    # impossible (DFT KPAR=1 too big, or a single group larger than a node) fall back
    # to a plain memory split.
    kpar = max(1, int(getattr(candidate, "kpar", 1) or 1))

    # The layout comes from wolfpack_geometry.node_layout, which vasp-test's
    # helper uses too. It was written out here AND there, and the two copies
    # were wrong in the same way -- so fixing this one left the DEFINITIVE
    # script (slurm_vasptest.sh, the one the pipeline says to submit) still
    # asking for one node per MPI rank.
    if max_cores is None:
        try:
            max_cores = int(partition_info.get("max_cores") or 0) or None
        except (TypeError, ValueError):
            max_cores = None
    nodes, ntpn = node_layout(total, kpar, cpn, usable, usage, max_cores=max_cores)

    # Size the request: the mem_util sizing, but trimmed so ntpn ranks fit the node
    # (keeps the whole-group layout rather than adding a node). Stays in
    # [usage, desired] -> utilisation in [mem_util, 100%]: policy-compliant AND no OOM.
    fit_req = usable // max(ntpn, 1)
    mem_per_cpu = max(200, min(desired, max(int(math.ceil(usage)), (fit_req // 50) * 50)))

    # GW SWEET raise: grow the request to the queue-friendly node share so the frozen
    # MAXMEM (mem-per-cpu - 3 GB) is as big -- and the frequency batching as fast -- as
    # the queue allows. Never exceeds what ntpn ranks can actually have on the node.
    if gw_node_frac > 0 and candidate.calc_type != "DFT":
        _avail = max(0, node_mem - max(reserve_mb, 0))
        sweet = (int(gw_node_frac * _avail) // max(ntpn, 1)) // 50 * 50
        mem_per_cpu = max(mem_per_cpu, min(sweet, (fit_req // 50) * 50))
    return mem_per_cpu, nodes, ntpn, node_mem


def slurm_script(
    *,
    candidate: Candidate,
    partition_name: str,
    partition_info: Dict[str, object],
    summary: DryRunSummary,
    email: Optional[str],
    job_name: str,
    executable: str,
    time_limit: str,
    mem_util: float = 0.80,
    reserve_mb: int = 0,
    rss_overhead: float = DEFAULT_RSS_OVERHEAD,
    gw_node_frac: float = 0.0,
) -> str:
    """Render the production SLURM script for a candidate (80% memory + node split)."""
    mem_per_cpu, nodes, ntpn, node_mem = compute_request_geometry(
        candidate, partition_info, mem_util, reserve_mb, rss_overhead, gw_node_frac)
    modules: List[str] = list(partition_info["modules"])     # type: ignore[arg-type]
    extra_env: List[str] = list(partition_info["extra_env"]) # type: ignore[arg-type]

    lines = [
        "#!/bin/bash",
        f'#SBATCH --job-name="{job_name}"',
        f"#SBATCH --partition={partition_info.get('slurm_name', partition_name)}",
        f"#SBATCH --time={time_limit}",
        f"#SBATCH --nodes={nodes}",
        f"#SBATCH --ntasks={candidate.total_ranks}",
    ]
    # --ntasks-per-node only when it is ARITHMETICALLY TRUE.
    #
    # SLURM reads --nodes, --ntasks and --ntasks-per-node as three claims about
    # the same allocation, and if they disagree it keeps two and drops one with
    # a warning: "can't honor --ntasks-per-node set to 48 which doesn't match
    # the requested tasks 190 with the number of requested nodes 4". 190 ranks
    # do not divide over 4 nodes of 48, so the flag was a lie the scheduler had
    # to correct. Say it only when nodes x ntasks-per-node is exactly the rank
    # count; otherwise let SLURM distribute and record why in a comment.
    if nodes * ntpn == candidate.total_ranks:
        lines.append(f"#SBATCH --ntasks-per-node={ntpn}")
    else:
        lines.append(
            f"# no --ntasks-per-node: {candidate.total_ranks} ranks do not divide"
            f" evenly over {nodes} node(s) ({nodes} x {ntpn} = {nodes * ntpn}),"
            f" so SLURM distributes them")
    lines += [
        "#SBATCH --cpus-per-task=1",                    # pure MPI
        f"#SBATCH --mem-per-cpu={mem_per_cpu}",
        "#SBATCH --output=%x-%j.out",
        "#SBATCH --error=%x-%j.err",
    ]
    if email:
        lines.append(f"#SBATCH --mail-user={email}")
        lines.append("#SBATCH --mail-type=ALL")

    note = (f"# memory sized for >= {mem_util*100:.0f}% utilisation "
            f"({mem_per_cpu} MB/cpu x {ntpn}/node = {mem_per_cpu*ntpn/1024:.0f} GB "
            f"of {node_mem/1024:.0f} GB)")
    if nodes > 1:
        note += f"; spread over {nodes} nodes so each node's RAM fits"
    if gw_node_frac > 0 and candidate.calc_type != "DFT":
        note += (f"\n# GW SWEET: request raised toward {gw_node_frac:.0%} of the node so the "
                 f"frozen MAXMEM (= mem-per-cpu - 3 GB) buys max frequency-batching speed")
    lines.extend(["", note])
    lines.extend(["", "# --- Modules (from your cluster profile) ---", *modules])
    lines.extend(["", "# --- Pure-MPI environment ---", *extra_env])
    lines.extend([
        "",
        '# Optional housekeeping:',
        '# rm -f DOSCAR PROCAR XDATCAR OSZICAR OUTCAR vasprun.xml REPORT',
        "",
        'echo "Inicio: $(date)"',
        f"/usr/bin/time -v srun --cpu-bind={candidate.cpu_bind} {executable}",
        'echo "Fin:    $(date)"',
    ])
    return "\n".join(lines)


# ============================================================================
# Output / pretty printing
# ============================================================================


def print_dryrun_summary(summary: DryRunSummary) -> None:
    """Print the parsed dry-run summary block."""
    print("=" * 78)
    print(" VASP PARALLELIZATION RECOMMENDER (pure MPI) ".center(78, "="))
    print("=" * 78)
    print("Built from the VASP wiki rules at https://vasp.at/wiki/Category:Performance.")
    print("Final answer is the result of a SHORT benchmark: take the top 2-3 candidates")
    print("from this tool, run a few SCF steps with each, and keep the fastest.\n")

    print("[DRY-RUN SUMMARY]")
    print(f"  OUTCAR                  : {summary.outcar_path}")
    _calc_label = {
        "DFT": "DFT / standard SCF",
        "GW_CONVENTIONAL": "GW (conventional / quartic-scaling)",
        "GW_LOWSCALING": "GW (low-scaling / space-time)",
        "RPA_LOWSCALING": "RPA (low-scaling / space-time)",
    }.get(summary.calc_type, summary.calc_type)
    print(f"  detected calculation    : {_calc_label}")
    if summary.calc_type != "DFT":
        print(f"  GW/RPA ALGO             : {summary.gw_algo}")
    print(f"  ALGO                    : {summary.algo}"
          f"   LREAL : {summary.lreal}   ENCUT : {summary.encut}")
    print(f"  irreducible k-points    : {summary.irr_kpoints}")
    print(f"  NKPTS                   : {summary.nkpts}")
    print(f"  NBANDS                  : {summary.nbands}")
    print(f"  NIONS                   : {summary.nions}")
    print(f"  NELECT                  : {summary.nelect}")
    print(f"  ISPIN                   : {summary.ispin}")
    print(f"  NPLWV (max plane waves) : {summary.nplwv}")
    print(f"  gamma-only / NKPTS=1    : {summary.is_gamma_only}")
    if summary.calc_type != "DFT":
        print(f"  NOMEGA                  : {summary.nomega}"
              f"   NELMGW : {summary.nelmgw}   ENCUTGW : {summary.encutgw}")
        if summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING"):
            print(f"  FFT grid (exact exch.)  : {summary.fft_exx}")
            print(f"  FFT grid (supercell)    : {summary.fft_supercell}")
            if summary.vasp_min_mem_per_rank_mb is not None:
                print(f"  VASP min mem / rank     : "
                      f"{summary.vasp_min_mem_per_rank_mb:.0f} MB"
                      f"   / node : {summary.vasp_min_mem_per_node_mb:.0f} MB"
                      "   (authoritative)")
    if summary.coarse_fft is not None:
        x, y, z = summary.coarse_fft
        print(f"  coarse FFT (NGX,Y,Z)    : {x} x {y} x {z}")
    if summary.fine_fft is not None:
        x, y, z = summary.fine_fft
        print(f"  fine FFT (NGXF,YF,ZF)   : {x} x {y} x {z}")
    print()
    print("[DRY-RUN PARALLEL LAYOUT  (essential for memory rescaling)]")
    print(f"  total ranks in dry run  : {summary.dry_total_ranks}")
    print(f"  KPAR  (dry run)         : {summary.dry_kpar}")
    print(f"  NCORE (dry run)         : {summary.dry_ncore}")
    print(f"  NPAR  (dry run)         : {summary.dry_npar}")
    print()
    if summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING"):
        print("[MEMORY MODEL]  low-scaling GW/RPA -> per-rank cost is set by the")
        print("  imaginary-time/-frequency grid split (NTAUPAR), estimated from the")
        print("  HF/supercell FFT grids via the VASP wiki formula. The DFT-style")
        print("  rank0 memory table is not used here.")
        if summary.vasp_min_mem_per_rank_mb is None:
            print("  TIP: the dry run did not print VASP's own")
            print("       'min. memory requirement per mpi rank ... per node' line.")
            print("       Do a brief REAL low-scaling run (not ALGO=None) to get it;")
            print("       that number is authoritative and the tool will honour it.")
        print()
        return
    print("[VASP MEMORY TABLE  (from the dry-run OUTCAR; per MPI rank)]")
    m = summary.memory
    if m.has_data():
        def _row(label: str, value: Optional[float]) -> str:
            return f"  {label:<22}: {value:8.1f} MB" if value is not None \
                else f"  {label:<22}:    (not reported)"
        print(_row("base", m.base_mb))
        print(_row("nonlr-proj", m.nonlr_proj_mb))
        print(_row("fftplans", m.fftplans_mb))
        print(_row("grid", m.grid_mb))
        print(_row("one-center", m.one_center_mb))
        print(_row("wavefun", m.wavefun_mb))
        if m.total_mb is not None:
            print(f"  {'TOTAL (rank 0)':<22}: {m.total_mb:8.1f} MB")
        # Tell the user which prediction tier we will use.
        rows_present = all(
            getattr(m, f) is not None
            for f in ("wavefun_mb", "grid_mb", "nonlr_proj_mb")
        )
        if rows_present:
            print("  Model: TIER 1 (per-row rescaling -- most accurate).")
        else:
            print("  Model: TIER 2 (TOTAL anchor + 80/15/5 wavefun/grid/proj split).")
            print("         Less accurate than Tier 1 but ANCHORED to VASP's own number.")
            print("         To get Tier 1, run the dry run on a recent VASP 6 build")
            print("         that prints the full breakdown rows.")
    else:
        print("  No memory table found in the dry-run OUTCAR -- and there never is one.")
        print("  `vasp_std --dry-run` exits BEFORE it allocates, so it cannot print")
        print("  a memory table. That is also why the dry run is free, which is the")
        print("  point of it: it is there to measure DIMENSIONS, not memory.")
        print("  -> Falling back to https://vasp.at/wiki/Memory_requirements formulas")
        print("     (TIER 3). Against the 23 real memory tables in Test/, these")
        print("     UNDER-estimate in 19 cases, by up to 10x -- they are good enough")
        print("     to RANK layouts, not to size a job.")
        print("  -> vasp-test measures the real per-rank RSS from sacct. That is the")
        print("     number production is sized from.")
    print()


def print_partition_summary(
    *,
    partition_name: str,
    partition_info: Dict[str, object],
    cpus_per_node: int,
    numa_cores: Optional[int],
    min_cores: int,
    max_cores: int,
) -> None:
    """Print the partition / core-and-memory limits block."""
    real = partition_info.get("slurm_name", partition_name)
    label = f"{partition_name} -> {real}" if real != partition_name else partition_name
    print("[TARGET HARDWARE]")
    print(f"  partition               : {label}"
          f" ({partition_info.get('arch')})")
    print(f"  CPUs per node           : {cpus_per_node}")
    print(f"  NUMA cores              : {numa_cores}")
    print(f"  partition mem/CPU       : {partition_info.get('mem_per_cpu_mb')} MB"
          " (SLURM default)")
    print(f"  account core cap        : {max_cores}"
          f"  (range scanned: {min_cores}..{max_cores})")
    print(f"  parallel mode           : pure MPI (OMP=1, -c 1)")
    print()


def print_candidate_table(candidates: Sequence[Candidate], top: int) -> None:
    """Print the ranked table of the best candidate per rank count."""
    print("[TOP CANDIDATES]  (best INCAR shown for each total_ranks; sorted by score)")
    calc_type = candidates[0].calc_type if candidates else "DFT"
    low = calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")
    if low:
        header = (
            " rk |  score | ranks | nodes | ntpn |KPAR| rpk |NTAUPAR|NOMEGAPAR"
            "|  mem/CPU(MB) | MAXMEM"
        )
        print(header)
        print("-" * len(header))
        for idx, c in enumerate(candidates[:top], start=1):
            print(
                f" {idx:>2} | {c.score:>6.1f} | {c.total_ranks:>5} | {c.nodes:>5} |"
                f" {c.ntasks_per_node:>4} |{c.kpar:>4}| {c.ranks_per_kgroup:>3} |"
                f" {str(c.ntaupar):>5} | {str(c.nomegapar):>7} |"
                f" {c.memory.suggested_mem_per_cpu_mb:>10} | {c.memory.maxmem_mb:>6}"
            )
        print()
        return
    if calc_type == "GW_CONVENTIONAL":
        header = (
            " rk |  score | ranks | nodes | ntpn |KPAR| rpk (ranks/k-group)"
            " |  mem/CPU(MB)"
        )
        print(header)
        print("-" * len(header))
        for idx, c in enumerate(candidates[:top], start=1):
            print(
                f" {idx:>2} | {c.score:>6.1f} | {c.total_ranks:>5} | {c.nodes:>5} |"
                f" {c.ntasks_per_node:>4} |{c.kpar:>4}| {c.ranks_per_kgroup:>18} |"
                f" {c.memory.suggested_mem_per_cpu_mb:>10}"
            )
        print()
        return
    header = (
        " rk |  score | ranks | nodes | ntpn |KPAR|NCORE|NPAR | b/grp | NSIM | LPL "
        "|  mem/CPU(MB)"
    )
    print(header)
    print("-" * len(header))
    for idx, c in enumerate(candidates[:top], start=1):
        bpg = f"{c.bands_per_group:.2f}" if c.bands_per_group else "-"
        lpl = "T" if c.lplane else "F"
        print(
            f" {idx:>2} | {c.score:>6.1f} | {c.total_ranks:>5} | {c.nodes:>5} |"
            f" {c.ntasks_per_node:>4} |{c.kpar:>4}|{c.ncore:>5}|{c.npar:>4} |"
            f" {bpg:>5} | {c.nsim:>4} | {lpl:>3} |"
            f" {c.memory.suggested_mem_per_cpu_mb:>10}"
        )
    print()


def print_best_candidate(
    *,
    candidate: Candidate,
    partition_name: str,
    partition_info: Dict[str, object],
    summary: DryRunSummary,
    email: Optional[str],
    job_name: str,
    executable: str,
    time_limit: str,
    gw_node_frac: float = 0.0,
) -> None:
    """Print the full recommendation for the top candidate (layout, memory, INCAR, SLURM)."""
    print("=" * 78)
    print(" BEST CANDIDATE ".center(78, "="))
    print("=" * 78)
    low = candidate.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING")
    conv = candidate.calc_type == "GW_CONVENTIONAL"
    print(f"score                   : {candidate.score:.1f}")
    print(f"calculation type        : {candidate.calc_type}")
    print(f"total MPI ranks         : {candidate.total_ranks}")
    print(f"nodes                   : {candidate.nodes}")
    print(f"ntasks-per-node         : {candidate.ntasks_per_node}")
    print(f"KPAR                    : {candidate.kpar}")
    if low or conv:
        print(f"NCORE                   : 1    (REQUIRED: GW has no band-FFT split)")
        print(f"ranks per k-point group : {candidate.ranks_per_kgroup}")
    else:
        print(f"NCORE                   : {candidate.ncore}")
        print(f"NPAR (derived)          : {candidate.npar}"
              "    (do NOT set both NCORE and NPAR)")
        print(f"NSIM                    : {candidate.nsim}")
        print(f"LPLANE                  : {format_bool(candidate.lplane)}")
        print(f"effective NBANDS        : {candidate.effective_nbands}"
              f"  (raw dry-run: {summary.nbands})")
        print(f"bands per band-group    : {candidate.bands_per_group:.2f}")
    if low:
        print(f"NOMEGA                  : {candidate.nomega}")
        print(f"NTAUPAR (time grid)     : {candidate.ntaupar}"
              "    (divisor of NOMEGA; larger = faster, more RAM)")
        print(f"NOMEGAPAR (freq grid)   : {candidate.nomegapar}"
              "    (divisor of NOMEGA)")
        print(f"recommended MAXMEM      : {candidate.memory.maxmem_mb} MB/rank")
    print()

    if low:
        print(f"[MEMORY ESTIMATE  ({candidate.memory.model};"
              f" grids: {candidate.memory.gw_grid_source})]")
        m = candidate.memory
        print(f"  imaginary-grid arrays : {m.gw_grid_term_mb:9.1f} MB  (per rank)")
        print(f"  fixed overhead        : {m.base_mb:9.1f} MB")
        print(f"  safety buffer         : {m.safety_mb:9.1f} MB")
        print(f"  ---")
        print(f"  per-rank total        : {m.per_rank_mb:9.1f} MB")
        print(f"  per-node total        : {m.gw_per_node_mb / 1024.0:9.2f} GB"
              f"  ({candidate.ntasks_per_node} ranks/node)")
        print(f"  whole-job total       : {m.total_job_mb / 1024.0:9.2f} GB")
        print(f"  suggested --mem-per-cpu : {m.suggested_mem_per_cpu_mb} MB  "
              f"(partition default: {m.partition_mem_per_cpu_mb} MB)")
        print("  node layout             : sized to the utilisation policy; if it "
              "exceeds one node it splits across KPAR nodes (see SLURM script)")
        if m.gw_grid_source == "fine-fft-proxy":
            print("  NOTE: grids estimated from the fine FFT mesh (ALGO=None dry run).")
            print("        For an accurate number, do a brief REAL low-scaling run so")
            print("        VASP prints its HF/supercell grids and its own")
            print("        'min. memory requirement per mpi rank ... per node' line.")
        print()
    elif conv:
        m = candidate.memory
        rpk = candidate.ranks_per_kgroup or (candidate.total_ranks // max(1, candidate.kpar))
        print(f"[MEMORY ESTIMATE  ({m.model})]")
        print(f"  {m.gw_grid_source}")
        print(f"  per-rank FLOOR          : {m.per_rank_mb:9.1f} MB  "
              f"(NOMEGA-INDEPENDENT; ~ENCUTGW^3; ~1/ranks-per-k-group)")
        print(f"  per-node need           : {m.gw_per_node_mb / 1024.0:9.2f} GB  "
              f"(one k-group = {rpk} ranks/node -- this is what must fit a node)")
        print(f"  first-pass MAXMEM       : {m.maxmem_mb} MB/rank  "
              f"(DERIVED = mem-per-cpu - reserve; vasp-test sets the final value)")
        print(f"  suggested --mem-per-cpu : {m.suggested_mem_per_cpu_mb} MB  "
              f"(partition default: {m.partition_mem_per_cpu_mb} MB)")
        print("  node layout             : KPAR k-groups, ONE per node (undersaturated); "
              "OOM is cured by MORE nodes / lower ENCUTGW, NOT a bigger MAXMEM")
        # ENCUTGW is the dominant (cubic) memory knob; flag the default=ENCUT trap.
        if summary.encutgw is None and summary.encut is not None:
            print(f"  WARNING: ENCUTGW is unset -> defaults to ENCUT = "
                  f"{summary.encut:.0f} eV. The GW floor ~ ENCUTGW^3, so this is")
            print(f"           the OOM-prone choice. Set ENCUTGW explicitly "
                  f"(e.g. 200-400) and converge it; halving ENCUTGW cuts the")
            print(f"           floor ~8x -- the single most effective memory lever.")
        print()
    else:
        print(f"[MEMORY ESTIMATE  ({candidate.memory.model})]")
        m = candidate.memory
        print(f"  wavefun (per rank)    : {m.wavefun_mb:9.1f} MB")
        print(f"  grid    (per rank)    : {m.grid_mb:9.1f} MB")
        print(f"  nonlr-proj (per rank) : {m.nonlr_proj_mb:9.1f} MB")
        print(f"  fftplans (per rank)   : {m.fftplans_mb:9.1f} MB")
        print(f"  base + one-center     : {(m.base_mb + m.one_center_mb):9.1f} MB")
        print(f"  scaLAPACK workspace   : {m.scalapack_mb:9.1f} MB")
        print(f"  safety buffer         : {m.safety_mb:9.1f} MB")
        print(f"  ---")
        print(f"  per-rank total        : {m.per_rank_mb:9.1f} MB")
        print(f"  whole-job total       : {m.total_job_mb / 1024.0:9.2f} GB")
        print(f"  suggested --mem-per-cpu : {m.suggested_mem_per_cpu_mb} MB  "
              f"(partition default: {m.partition_mem_per_cpu_mb} MB)")
        print("  node layout             : sized to the utilisation policy; if it "
              "exceeds one node it splits across more nodes (see SLURM script)")
        if m.model == "fallback-formulas":
            print()
            print("  !! THIS IS A GUESS, NOT A MEASUREMENT.")
            print("     The dry run brought no memory table, so every number above")
            print("     comes from formulas. Checked against the 23 real VASP memory")
            print("     tables in Test/, those formulas UNDER-estimate in 19 cases,")
            print("     by up to 10x. The dominant term (nonl-proj) is the worst.")
            print("     Do NOT size a production job from this. Run vasp-test: it")
            print("     measures the real per-rank RSS and that value is the one")
            print("     that goes into the definitive job script.")
        print()

    # The wiki's own tip for exactly this situation. Worth saying out loud,
    # because it is the only way out and it is not obvious:
    #
    #   "If the number of k points is a prime number (or does not factorize
    #    well), copy the IBZKPT file to KPOINTS and add zero-weigthed points."
    #   -- https://vasp.at/wiki/Optimizing_the_parallelization
    #
    # It fires when NO rank count this cluster can hand out whole has a KPAR
    # that divides NKPTS exactly. 190 k-points on 48-core nodes is that case:
    # 190 = 2 x 5 x 19 shares only a factor 2 with any multiple of 48, so every
    # usable KPAR leaves the k-point groups uneven and some ranks idle at the
    # end of each pass.
    _irr = summary.irr_kpoints or summary.nkpts
    _cpn = int(partition_info.get("cpus_per_node") or 0)
    if (_irr and _irr > 1 and candidate.calc_type == "DFT"
            and candidate.kpar > 1 and _irr % candidate.kpar != 0):
        _idle = 100.0 * (1.0 - _irr / (math.ceil(_irr / candidate.kpar)
                                       * candidate.kpar))
        print("[K-POINT COUNT]  the chosen KPAR does not divide NKPTS exactly")
        print(f"  NKPTS = {_irr}, KPAR = {candidate.kpar}: the k-points go out "
              f"round-robin, so the")
        print(f"  busiest group gets {math.ceil(_irr / candidate.kpar)} of them "
              f"and every other group waits for it --")
        print(f"  {_idle:.1f}% of the allocated core-time buys nothing.")
        if _cpn:
            print(f"  This cluster hands out whole nodes of {_cpn} cores, so every "
                  f"rank count it can")
            print(f"  give is a multiple of {_cpn}, and no KPAR dividing one of "
                  f"those factorizes {_irr}.")
            print("  The VASP wiki's way out, if that matters for your run:")
            print("     cp IBZKPT KPOINTS     # then add zero-weighted points")
            print("  until NKPTS factorizes over the rank counts above.")
            print("  (https://vasp.at/wiki/Optimizing_the_parallelization)")
            print()

    print("[WHY]  (top score contributions)")
    for line in candidate.reasons:
        print(line)
    print()

    print("[INCAR SNIPPET]  (copy into your INCAR)")
    print("-" * 78)
    print(candidate.incar_snippet)
    print("-" * 78)
    print()

    print("[SLURM SCRIPT]  (copy into job.sh; submit with `sbatch job.sh`)")
    print("-" * 78)
    print(slurm_script(
        candidate=candidate,
        partition_name=partition_name,
        partition_info=partition_info,
        summary=summary,
        email=email,
        job_name=job_name,
        executable=executable,
        time_limit=time_limit,
        gw_node_frac=gw_node_frac,
    ))
    print("-" * 78)
    print()


def write_csv(path: Path, candidates: Sequence[Candidate]) -> None:
    """Write the full ranked candidate list to a CSV file."""
    fieldnames = [
        "score", "total_ranks", "nodes", "ntasks_per_node",
        "kpar", "ncore", "npar", "nsim", "lplane",
        "ranks_per_kgroup", "bands_per_group", "effective_nbands",
        "mem_model",
        "mem_per_cpu_suggested_mb", "mem_per_rank_mb", "mem_total_gb",
        "wavefun_mb", "grid_mb", "nonlr_proj_mb", "fftplans_mb",
        "base_one_center_mb", "scalapack_mb", "safety_mb",
        "fits_partition", "incar_snippet", "reasons", "contributions",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for c in candidates:
            m = c.memory
            writer.writerow({
                "score": f"{c.score:.3f}",
                "total_ranks": c.total_ranks,
                "nodes": c.nodes,
                "ntasks_per_node": c.ntasks_per_node,
                "kpar": c.kpar,
                "ncore": c.ncore,
                "npar": c.npar,
                "nsim": c.nsim,
                "lplane": c.lplane,
                "ranks_per_kgroup": c.ranks_per_kgroup,
                "bands_per_group": f"{c.bands_per_group:.4f}",
                "effective_nbands": c.effective_nbands,
                "mem_model": m.model,
                "mem_per_cpu_suggested_mb": m.suggested_mem_per_cpu_mb,
                "mem_per_rank_mb": f"{m.per_rank_mb:.1f}",
                "mem_total_gb": f"{m.total_job_mb / 1024.0:.2f}",
                "wavefun_mb": f"{m.wavefun_mb:.1f}",
                "grid_mb": f"{m.grid_mb:.1f}",
                "nonlr_proj_mb": f"{m.nonlr_proj_mb:.1f}",
                "fftplans_mb": f"{m.fftplans_mb:.1f}",
                "base_one_center_mb": f"{(m.base_mb + m.one_center_mb):.1f}",
                "scalapack_mb": f"{m.scalapack_mb:.1f}",
                "safety_mb": f"{m.safety_mb:.1f}",
                "fits_partition": m.fits_partition,
                "incar_snippet": c.incar_snippet.replace("\n", " | "),
                "reasons": " ; ".join(r.strip() for r in c.reasons),
                "contributions": " ; ".join(
                    f"{k}={v:+.2f}" for k, v in sorted(
                        c.contributions.items(), key=lambda kv: -abs(kv[1])
                    )
                ),
            })


# ============================================================================
# CLI
# ============================================================================


def build_arg_parser() -> argparse.ArgumentParser:
    """Build and return the argparse parser for the recommender CLI."""
    parser = argparse.ArgumentParser(
        description=(
            "VASP parallelization recommender for SLURM clusters (pure MPI). "
            "Reads a dry-run OUTCAR, follows the VASP wiki recipe to enumerate "
            "candidate (KPAR, NCORE, NPAR, NSIM, LPLANE) tuples, rescales "
            "VASP's own memory table to predict per-rank RAM for each, and "
            "prints INCAR + SLURM for the best one."
        )
    )
    parser.add_argument("outcar", type=Path, nargs="?", default=None,
                        help="Path to a dry-run OUTCAR. If omitted, auto-find "
                             "the one produced by vasp-dry-run "
                             "(.wolfpack/dryrun_OUTCAR, ./dryrun_OUTCAR or "
                             "./OUTCAR) so the dry-run -> recommend chain needs "
                             "no arguments.")
    parser.add_argument("--max-cores", type=int, default=None,
                        help="Account-wide MPI-rank cap (default: from the "
                             "cluster profile written by vasp-configure, else "
                             "120).")
    parser.add_argument("--min-cores", type=int, default=8,
                        help="Smallest total_ranks to evaluate (default 8).")
    parser.add_argument("--partition",
                        choices=sorted(CLUSTER_PARTITIONS.keys()),
                        default="main",
                        help="Logical partition: 'main' or 'debug' (mapped to "
                             "your real partition names by vasp-configure; "
                             "default: main).")
    parser.add_argument("--cores-per-node", type=int, default=None,
                        help="Override CPUs/node (defaults to the cluster "
                             "profile / built-in table).")
    parser.add_argument("--numa-cores", type=int, default=None,
                        help="NUMA-domain size in cores (defaults to the "
                             "profile/table; verify with lstopo / numactl "
                             "--hardware).")
    parser.add_argument("--mem-headroom", type=float, default=1.15,
                        help="Safety multiplier on the RAM estimate "
                             "(default 1.15).  At default, Tier 1 predictions "
                             "(per-row rescaling of VASP's own memory table) "
                             "end up about 15-20%% above actual peak usage. "
                             "Raise to 1.30-1.50 if you have hit OOM kills "
                             "or if you trust VASP's numbers less; lower to "
                             "1.05 for a very tight ask.")
    parser.add_argument("--mem-util", type=float, default=None,
                        help="Minimum memory-utilisation fraction your cluster "
                             "requires (default: WP_MEM_UTIL from the profile, "
                             "else 0.80). The SLURM request is sized to "
                             "need/util so the job uses ~this fraction of its "
                             "allocation.")
    parser.add_argument("--rss-overhead", type=float, default=None,
                        help="Multiplier on VASP's reported per-rank memory to "
                             "approximate real RSS (FFT/MPI/scaLAPACK/allocator "
                             "overhead not in VASP's table). Default: "
                             "WP_RSS_OVERHEAD from the profile, else 1.4. "
                             "vasp-test supersedes this with the measured value.")
    parser.add_argument("--gw-node-frac", type=float, default=None,
                        help="GW SWEET sizing: grow the per-node memory request to "
                             "this fraction of the node so the frozen MAXMEM "
                             "(= mem-per-cpu - 3 GB) buys frequency-batching speed, "
                             "while ~1-frac of the node stays free for queue "
                             "backfill. Default: WP_GW_NODE_FRAC from the profile, "
                             "else 0.67. 0 = pure need-based (SAFE) sizing.")
    parser.add_argument("--top", type=int, default=10,
                        help="Number of top candidates to print (default 10).")
    parser.add_argument("--csv", type=Path, default=None,
                        help="Optional path: write the full ranked list as CSV.")
    parser.add_argument("--write-slurm", type=Path, default=Path("slurm.sh"),
                        metavar="FILE",
                        help="Write the recommended production SLURM script here "
                             "(default: ./slurm.sh). vasp-test later updates its "
                             "memory from the benchmark. Use --no-write to skip.")
    parser.add_argument("--write-incar", type=Path, default=None,
                        metavar="FILE",
                        help="Also write the INCAR snippet to a separate file "
                             "(default: none; the snippet is embedded as comments "
                             "in slurm.sh and shown in report.out).")
    parser.add_argument("--report", type=Path, default=Path("report.out"),
                        metavar="FILE",
                        help="Append the recommendation to this combined report "
                             "(default: ./report.out). Use --no-report to skip.")
    parser.add_argument("--no-report", action="store_true",
                        help="Do not append to report.out.")
    parser.add_argument("--state", type=Path,
                        default=Path(".wolfpack/state.env"),
                        help="Machine-readable state file for the dry-run -> "
                             "recommend -> test chain (default: "
                             ".wolfpack/state.env).")
    parser.add_argument("--no-write", action="store_true",
                        help="Do not write any files; only print to stdout.")
    parser.add_argument("--email", type=str, default=None,
                        help="Email injected into the SLURM script (default: "
                             "from the cluster profile written by "
                             "vasp-configure; empty -> no --mail-user line).")
    parser.add_argument("--job-name", type=str, default="VASP",
                        help="SLURM --job-name value (default: VASP).")
    parser.add_argument("--executable", type=str, default=None,
                        choices=["vasp_std", "vasp_gam", "vasp_ncl"],
                        help="VASP executable. Auto-detected from dry run if "
                             "omitted.")
    parser.add_argument("--strict-ncore-one", action="store_true",
                        help="Force NCORE=1 in all candidates (strict legacy "
                             "template).  By default we enumerate NCORE > 1 "
                             "as well, following the VASP wiki recommendation "
                             "of NCORE ~ sqrt(available_ranks) on modern "
                             "multi-core nodes.")
    parser.add_argument("--allow-kpar-above-irr", action="store_true",
                        help="Allow KPAR > NKPTS in the enumeration "
                             "(off by default per VASP wiki).")
    parser.add_argument("--nsim-choices", type=int, nargs="+",
                        default=[4],
                        help="NSIM values to enumerate (default: 4 only; "
                             "VASP wiki gives 4 as the CPU default. Pass "
                             "e.g. --nsim-choices 2 4 8 to widen the sweep).")
    parser.add_argument("--time", type=str, default="7-00:00:00",
                        help="SLURM --time value (default: 7-00:00:00).")
    parser.add_argument("--calc-type", choices=["auto", "dft", "gw", "gw-low",
                                                "rpa-low"],
                        default="auto",
                        help="Force the calculation type instead of detecting "
                             "it from the OUTCAR. 'gw' = conventional "
                             "(quartic-scaling) GW (KPAR-only, NCORE=1); "
                             "'gw-low' = low-scaling/space-time GW "
                             "(NTAUPAR/NOMEGAPAR); 'rpa-low' = low-scaling RPA. "
                             "Default 'auto' inspects ALGO and GW fingerprints "
                             "(useful when the dry run masked ALGO with None).")
    parser.add_argument("--nomega", type=int, default=None,
                        help="Override NOMEGA for low-scaling GW/RPA "
                             "(number of imaginary grid points). Only needed "
                             "if it could not be parsed from the OUTCAR; "
                             "NTAUPAR and NOMEGAPAR must both divide it.")
    parser.add_argument("--no-maxmem", action="store_true",
                        help="For low-scaling GW/RPA, do NOT emit a MAXMEM line "
                             "in the INCAR snippet (only show explicit "
                             "NTAUPAR/NOMEGAPAR instead). By default the tool "
                             "recommends MAXMEM, per the VASP wiki.")
    parser.add_argument("--no-apply-incar", action="store_true",
                        help="Do NOT write the recommended KPAR/NCORE/NPAR into "
                             "the INCAR (by default they are applied, backup at "
                             "INCAR.bak, so vasp-test + production match).")
    parser.add_argument("--gw-mem-per-rank", type=float, default=None,
                        metavar="MB",
                        help="CONVENTIONAL GW only: a MEASURED per-rank peak (MB) "
                             "to calibrate the GW memory model to reality. The "
                             "whole model is scaled so the candidate matching "
                             "--gw-ref-ranks/--gw-ref-kpar predicts this value; "
                             "vasp-test passes it to re-pick a feasible config.")
    parser.add_argument("--gw-ref-ranks", type=int, default=None, metavar="N",
                        help="CONVENTIONAL GW only: total MPI ranks of the run "
                             "that produced --gw-mem-per-rank (the calibration "
                             "reference layout).")
    parser.add_argument("--gw-ref-kpar", type=int, default=None, metavar="K",
                        help="CONVENTIONAL GW only: KPAR of the --gw-mem-per-rank "
                             "reference layout (with --gw-ref-ranks identifies the "
                             "candidate whose prediction is pinned to the measurement).")
    parser.add_argument("--gw-ref-encutgw", type=float, default=None,
                        metavar="EV",
                        help="CONVENTIONAL GW only: the ENCUTGW (eV) actually "
                             "used in the anchor run. The GW memory scales as "
                             "ENCUTGW^3, so this is essential for an ENCUTGW "
                             "convergence sweep. Default assumes 608 (=ENCUT).")
    return parser


# ============================================================================
# Cluster profile (written by vasp-configure)
# ============================================================================
# The toolkit ships with the example partitions above as a built-in default, but
# `vasp-configure` writes a per-user profile describing the ACTUAL cluster
# (partition names, cores/node, memory/node, the module-load lines for the
# chosen VASP build, the notification email and the account core cap). When
# that profile exists we fold it into the 'main' and 'debug' partitions so the
# emitted SLURM script targets the real partitions and loads the real modules.


def _config_path() -> Path:
    """Path to the user's cluster profile (WOLFPACK_CLUSTER_CONF or the default)."""
    env = os.environ.get("WOLFPACK_CLUSTER_CONF")
    if env:
        return Path(env).expanduser()
    return Path.home() / ".config" / "wolfpack-dft" / "cluster.conf"


def load_cluster_profile() -> Dict[str, str]:
    """Parse the KEY="value" profile from vasp-configure; {} if none exists."""
    path = _config_path()
    prof: Dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError:
        return prof
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        prof[key.strip()] = val.strip().strip('"').strip("'")
    return prof


def _profile_module_lines(prof: Dict[str, str]) -> List[str]:
    """Build the module-load command lines from the profile."""
    mods = (prof.get("WP_VASP_MODULES") or "").split()
    if not mods:
        return []
    cmd = (prof.get("WP_MODULE_CMD") or "ml").strip()
    purge = str(prof.get("WP_MODULE_PURGE", "1")).strip().lower() \
        not in ("0", "", "false", "no")
    if cmd == "module":
        lines = ["module purge"] if purge else []
        lines.append("module load " + " ".join(mods))
    else:
        lines = ["ml purge"] if purge else []
        lines.append("ml " + " ".join(mods))
    return lines


def _profile_extra_env(prof: Dict[str, str]) -> List[str]:
    """Split the profile's WP_EXTRA_ENV ';'-list into individual shell statements."""
    return [e.strip() for e in (prof.get("WP_EXTRA_ENV") or "").split(";")
            if e.strip()]


def apply_cluster_profile(prof: Dict[str, str]) -> None:
    """Fold the user's cluster profile into CLUSTER_PARTITIONS['main'/'debug']."""
    if not prof:
        return
    mods = _profile_module_lines(prof)
    env = _profile_extra_env(prof)

    def _apply(key: str, name_k: str, cpus_k: str, mem_k: str) -> None:
        """Fold one partition's WP_* profile keys into the catalogue entry."""
        info = dict(CLUSTER_PARTITIONS.get(key, {}))
        cpus = prof.get(cpus_k, "")
        mem = prof.get(mem_k, "")
        if mem.isdigit():
            info["node_mem_mb"] = int(mem)          # total RAM per node (MB)
        if cpus.isdigit():
            cpn = int(cpus)
            info["cpus_per_node"] = cpn
            if mem.isdigit():
                info["mem_per_cpu_mb"] = max(1, int(mem) // cpn)
        numa = prof.get("WP_MAIN_NUMA_CORES", "")
        if numa.isdigit():
            info["numa_cores"] = int(numa)
        # Assign unconditionally: an EMPTY module list in the profile is a
        # statement ("this site has no modules"), not an absence, and `if mods:`
        # let a built-in default survive it.
        info["modules"] = list(mods)
        if env:
            info["extra_env"] = list(env)
        name = prof.get(name_k, "").strip()
        if name:
            info["slurm_name"] = name
        info.setdefault("arch", "configured")
        CLUSTER_PARTITIONS[key] = info

    _apply("main", "WP_MAIN_PARTITION",
           "WP_MAIN_CPUS_PER_NODE", "WP_MAIN_MEM_PER_NODE_MB")
    _apply("debug", "WP_DEBUG_PARTITION",
           "WP_DEBUG_CPUS_PER_NODE", "WP_DEBUG_MEM_PER_NODE_MB")


# ============================================================================
# Pipeline orchestration helpers (dry-run -> recommend -> test)
# ============================================================================
def _find_dryrun_outcar() -> Optional[Path]:
    """Locate the dry-run OUTCAR for the no-argument recommend step."""
    for p in (Path(".wolfpack/dryrun_OUTCAR"), Path("dryrun_OUTCAR"), Path("OUTCAR")):
        if p.is_file():
            return p
    return None


def _now() -> str:
    """Current local timestamp as 'YYYY-MM-DD HH:MM:SS'."""
    import datetime as _dt
    return _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def append_report(path: Path, title: str, body: str) -> None:
    """Append a neatly-boxed section to the combined report.out."""
    bar = "#" * 78
    block = (f"\n{bar}\n"
             f"#  {title}\n"
             f"#  {_now()}\n"
             f"{bar}\n\n{body.rstrip()}\n")
    try:
        with open(path, "a") as fh:
            fh.write(block)
    except OSError as exc:
        print(f"[report] WARNING: could not append to {path}: {exc}",
              file=sys.stderr)


def write_state(path: Path, kv: Dict[str, object]) -> None:
    """Merge KEY=VALUE state into the hidden pipeline state file."""
    try:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        existing: Dict[str, str] = {}
        if path.is_file():
            for line in path.read_text().splitlines():
                s = line.strip()
                if s and not s.startswith("#") and "=" in s:
                    k, v = s.split("=", 1)
                    existing[k.strip()] = v.strip().strip('"')
        existing.update({k: str(v) for k, v in kv.items()})
        with open(path, "w") as fh:
            fh.write("# WolfPack-DFT pipeline state (dry-run -> recommend -> test)\n")
            for k, v in existing.items():
                fh.write(f'{k}="{v}"\n')
    except OSError as exc:
        print(f"[state] WARNING: could not write {path}: {exc}", file=sys.stderr)


def _embed_recommendation(script_text: str, candidate: "Candidate",
                          meta: Dict[str, object]) -> str:
    """Insert the INCAR snippet (as comments) + a machine-readable metadata
    line after the shebang, so slurm.sh is self-documenting and vasp-test can
    recover the FIXED parallel config from it."""
    meta_str = " ".join(f"{k}={v}" for k, v in meta.items())
    block = ["", "# ===================  WolfPack-DFT recommendation  ==================",
             f"# WOLFPACK {meta_str}",
             "# Parallelization applied to your INCAR (KPAR/NCORE/NPAR; backup INCAR.bak):"]
    block += ["#   " + ln for ln in candidate.incar_snippet.splitlines()]
    block += ["# ===================================================================="]
    lines = script_text.split("\n")
    if lines and lines[0].startswith("#!"):
        return "\n".join([lines[0], *block, *lines[1:]])
    return "\n".join([*block, *lines])


# INCAR editing lives in wolfpack_incar, so KPAR and NCORE land under the
# file's own "Parallelization" header instead of at the bottom of whatever
# section happened to be last.
_WP_DIR = os.path.dirname(os.path.realpath(__file__))
if _WP_DIR not in sys.path:
    sys.path.insert(0, _WP_DIR)
from wolfpack_incar import set_tag as _set_incar_flag_impl      # noqa: E402
from wolfpack_incar import comment_tag as _comment_out_incar_flag_impl  # noqa: E402


def _set_incar_flag(text: str, key: str, value, note: str = "") -> str:
    """Set `key = value` in its section, keeping any trailing comment."""
    return _set_incar_flag_impl(text, key, value, note)


def _comment_out_incar_flag(text: str, key: str, why: str) -> str:
    """Comment out an ACTIVE `key = ...` line, preserving it for the record."""
    return _comment_out_incar_flag_impl(text, key, why)


def apply_parallel_to_incar(path: Path, kpar: int, ncore: int, npar: int,
                            is_gw: bool) -> Optional[List[str]]:
    """Write the recommended PARALLELISATION into the user's INCAR (backup once at
    INCAR.bak). KPAR + NCORE only -- NEVER NPAR. These are parallelisation, not physics.

    NPAR IS DELIBERATELY NOT WRITTEN. NPAR and NCORE are two ways of expressing the
    same split (NPAR * NCORE = ranks per k-point group), and VASP IGNORES NCORE when
    NPAR is present, so setting both hands control to the one we did not intend. The
    two are only equivalent at ONE rank count: NCORE is absolute (cores per orbital,
    portable), NPAR is not. At the 48 ranks recommended here, KPAR=3 -> 16 ranks per
    k-group, so NCORE=4 and NPAR=4 agree; re-run the SAME INCAR on 96 ranks and NPAR=4
    silently forces NCORE=8 instead of the 4 that was benchmarked. Hence NCORE only,
    with NPAR reported as a derived quantity -- which is exactly what the printed
    INCAR snippet has always said ("Derived only ... do NOT set BOTH").

    An NPAR left over from an earlier version (or from the user) is commented out for
    the same reason: it would override the NCORE we just wrote."""
    try:
        t = Path(path).read_text()
    except OSError:
        return None
    bak = Path(str(path) + ".bak")
    if not bak.exists():
        try:
            bak.write_text(t)
        except OSError:
            pass
    flags = [("KPAR", kpar), ("NCORE", ncore)]
    for k, v in flags:
        t = _set_incar_flag(t, k, v)
    t = _comment_out_incar_flag(
        t, "NPAR", f"removed by vasp-recommend-slurm: NPAR overrides NCORE={ncore} "
                   f"(derived value here is {npar})")
    try:
        Path(path).write_text(t)
    except OSError:
        return None
    return [f"{k}={v}" for k, v in flags] + [f"NPAR={npar} (derived; not written)"]


def main(argv: Optional[Sequence[str]] = None) -> int:
    """CLI entry point: parse a dry-run OUTCAR and emit the parallelization recommendation."""
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    # Fold the per-user cluster profile (vasp-configure) into the partition
    # catalogue and resolve email / core-cap / mem-utilisation defaults from it.
    profile = load_cluster_profile()
    apply_cluster_profile(profile)
    if args.email is None:
        args.email = profile.get("WP_EMAIL", "") or ""
    if args.max_cores is None:
        mc = profile.get("WP_MAX_CORES", "")
        args.max_cores = int(mc) if mc.isdigit() else 120
    if args.mem_util is None:
        try:
            args.mem_util = float(profile.get("WP_MEM_UTIL", "") or 0.80)
        except ValueError:
            args.mem_util = 0.80
    args.mem_util = min(max(args.mem_util, 0.05), 1.0)
    # Head-room kept FREE on every production node, as a fraction of its RAM
    # (vasp-configure: WP_MAIN_MEM_MARGIN; 0.02 => 98% usable). Clamped so a typo
    # cannot swallow the node.
    try:
        _main_margin = float(profile.get("WP_MAIN_MEM_MARGIN", "") or 0.0)
    except ValueError:
        _main_margin = 0.0
    _main_margin = min(max(_main_margin, 0.0), 0.5)
    if args.rss_overhead is None:
        try:
            args.rss_overhead = float(profile.get("WP_RSS_OVERHEAD", "")
                                      or DEFAULT_RSS_OVERHEAD)
        except ValueError:
            args.rss_overhead = DEFAULT_RSS_OVERHEAD
    args.rss_overhead = max(args.rss_overhead, 1.0)
    # GW SWEET node fraction: how much of a node the GW request may grow to (buying
    # frozen-MAXMEM batching speed) while leaving the rest free for queue backfill.
    if args.gw_node_frac is None:
        try:
            args.gw_node_frac = float(profile.get("WP_GW_NODE_FRAC", "") or 0.67)
        except ValueError:
            args.gw_node_frac = 0.67
    args.gw_node_frac = min(max(args.gw_node_frac, 0.0), 0.95)

    # Resolve the dry-run OUTCAR (auto-find so `vasp-recommend-slurm` chains off
    # `vasp-dry-run` with no arguments).
    outcar = args.outcar or _find_dryrun_outcar()
    if outcar is None:
        print("ERROR: no dry-run OUTCAR found. Run 'vasp-dry-run' first (it "
              "writes .wolfpack/dryrun_OUTCAR), or pass an OUTCAR path.",
              file=sys.stderr)
        return 2
    if not Path(outcar).is_file():
        print(f"ERROR: OUTCAR not found: {outcar}", file=sys.stderr)
        return 2

    summary = parse_outcar(outcar, calc_type_override=args.calc_type)
    # Allow a manual NOMEGA override for low-scaling τ/ω enumeration.
    if args.nomega is not None:
        summary.nomega = args.nomega

    partition_info = CLUSTER_PARTITIONS[args.partition]
    # The account's core cap travels with the partition so the geometry sizing
    # can check ALLOCATED cores (nodes x cpus_per_node), which is what SLURM
    # actually charges, rather than the rank count.
    partition_info["max_cores"] = args.max_cores
    cpus_per_node = args.cores_per_node \
        or int(partition_info["cpus_per_node"])  # type: ignore[arg-type]
    # Write the EFFECTIVE value back, so everything downstream sees the same
    # node size. compute_request_geometry reads cpus_per_node from
    # partition_info, so a --cores-per-node override used to reach the SCORING
    # but not the GEOMETRY: the score table was computed for 48-core nodes while
    # the node split was computed for the built-in table's 256, which put 240
    # ranks on "one node" and then failed the core-cap check for a reason that
    # had nothing to do with the job.
    partition_info["cpus_per_node"] = cpus_per_node
    numa_cores = args.numa_cores
    if numa_cores is None and partition_info.get("numa_cores"):
        numa_cores = int(partition_info["numa_cores"])  # type: ignore[arg-type]

    is_gw = summary.calc_type in (
        "GW_CONVENTIONAL", "GW_LOWSCALING", "RPA_LOWSCALING")

    # Build candidates first (so we can bail before printing on failure).
    if is_gw:
        candidates = build_gw_candidates(
            summary=summary, min_cores=args.min_cores, max_cores=args.max_cores,
            partition_name=args.partition, cpus_per_node=cpus_per_node,
            numa_cores=numa_cores, safety_factor=args.mem_headroom,
            limit_kpar_to_irr=not args.allow_kpar_above_irr,
            recommend_maxmem=not args.no_maxmem,
            gw_anchor_override=args.gw_mem_per_rank,
            gw_ref_ranks_override=args.gw_ref_ranks,
            gw_ref_encutgw_override=args.gw_ref_encutgw)
    else:
        candidates = build_candidates(
            summary=summary, min_cores=args.min_cores, max_cores=args.max_cores,
            partition_name=args.partition, cpus_per_node=cpus_per_node,
            numa_cores=numa_cores, safety_factor=args.mem_headroom,
            limit_kpar_to_irr=not args.allow_kpar_above_irr,
            nsim_choices=tuple(args.nsim_choices),
            strict_ncore_one=args.strict_ncore_one)

    if not candidates:
        print("No valid candidates could be generated. "
              "Check --min-cores / --max-cores and your dry-run OUTCAR.",
              file=sys.stderr)
        return 1

    # CALIBRATION: when vasp-test re-invokes us with a MEASURED per-rank peak, pin
    # the GW model to it so the re-pick's feasibility uses real (not theoretical)
    # memory -- otherwise we would re-pick the same infeasible config.
    if is_gw and args.gw_mem_per_rank and args.gw_ref_ranks:
        calibrate_gw_memory(candidates, args.gw_mem_per_rank, args.gw_ref_ranks,
                            args.gw_ref_kpar, args.mem_util)

    # FEASIBILITY: for GW a whole k-group MUST fit one node (a split group means
    # cross-node chi/W traffic). Keep only configs whose group fits; the best-scoring
    # FEASIBLE one wins. If NONE fits, the optimised config cannot run on this
    # cluster -- error out with guidance instead of emitting a straddling layout.
    node_mem = _node_mem_mb(partition_info, int(partition_info["mem_per_cpu_mb"]))  # type: ignore[index]
    feasible = [c for c in candidates
                if group_fits_node(c, node_mem, cpus_per_node)]
    if not feasible:
        best = candidates[0]
        rpk = max(1, best.ranks_per_kgroup or best.total_ranks // max(1, best.kpar))
        need_gb = rpk * best.memory.per_rank_mb / 1024.0
        print(
            "\n[INFEASIBLE] No parallelization fits this cluster's nodes.\n"
            f"  The best config (KPAR={best.kpar}, {rpk} ranks/k-group) needs "
            f"~{need_gb:.0f} GB per k-group, but a node holds only "
            f"{node_mem/1024:.0f} GB ({cpus_per_node} cores).\n"
            "  A GW k-group cannot be split across nodes, so this is not runnable.\n"
            "  Options: raise KPAR (smaller k-groups) if NKPTS allows; lower ENCUTGW/\n"
            "  NOMEGA/NBANDS; or use a higher-memory partition. (vasp-test will also\n"
            "  re-pick automatically if the MEASURED memory is what breaks it.)",
            file=sys.stderr)
        return 3
    candidates = feasible            # best FEASIBLE candidate now leads the list

    executable = pick_executable(
        summary, args.executable,
        std_default=(profile.get("WP_VASP_STD", "") or "").strip() or None,
        gam_default=(profile.get("WP_VASP_GAM", "") or "").strip() or None,
        ncl_default=(profile.get("WP_VASP_NCL", "") or "").strip() or None)
    best_each = best_per_total_ranks(candidates)

    # ---- REFUSE rather than recommend something that cannot be submitted ----
    # The scoring rule down-ranks a layout whose node split blows the account's
    # core cap, but down-ranking only helps when a feasible layout exists. When
    # none does -- a per-rank memory floor that forces more nodes than the cap
    # allows, whatever the rank count -- picking the least-bad and writing a
    # slurm.sh for it hands the user a script every scheduler will reject. Say
    # so instead, and say what to change.
    # Ask compute_request_geometry itself rather than re-deriving it: the
    # scoring rule above uses an approximation of the node split (no reserve,
    # no request trimming), so it can disagree with the geometry that will
    # actually be written. The one that gets written is the one that matters.
    _cap_ok = True
    if candidates and args.max_cores and cpus_per_node > 0:
        _r = _node_reserve_mb(partition_info, _main_margin)
        _, _n_chk, _, _ = compute_request_geometry(
            candidates[0], partition_info, args.mem_util, reserve_mb=_r,
            rss_overhead=args.rss_overhead,
            gw_node_frac=(args.gw_node_frac if is_gw else 0.0))
        _cap_ok = _n_chk * cpus_per_node <= args.max_cores
    if not _cap_ok:
        _cpn = cpus_per_node
        _need = _n_chk
        print("\n" + "=" * 78, file=sys.stderr)
        print(" CANNOT RECOMMEND -- no layout fits this account's core cap",
              file=sys.stderr)
        print("=" * 78, file=sys.stderr)
        print(f"  The best layout needs {_need} node(s); SLURM hands out whole nodes",
              file=sys.stderr)
        print(f"  whole nodes and charges {_cpn} cores for each, so the cap of",
              file=sys.stderr)
        print(f"  {args.max_cores} cores is {max(1, args.max_cores // _cpn)} node(s) --"
              f" and the memory per rank here needs more.", file=sys.stderr)
        print("", file=sys.stderr)
        print("  What changes it, in order of least damage:", file=sys.stderr)
        print("    * raise the cap        vasp-configure  (WP_MAX_CORES)", file=sys.stderr)
        print("    * a higher-memory partition, if your cluster has one", file=sys.stderr)
        if is_gw:
            print("    * lower ENCUTGW / NOMEGA / NBANDS -- the GW floor is ~ENCUTGW^3",
                  file=sys.stderr)
        else:
            print("    * a smaller cell, a coarser k-mesh, or lower ENCUT", file=sys.stderr)
        print("", file=sys.stderr)
        print("  Nothing was written: a slurm.sh for this would be refused at submit.",
              file=sys.stderr)
        return 3

    # GW SWEET: size the geometry NOW (before printing) so the displayed MAXMEM matches
    # the final request -- the request grows to the queue-friendly node share and the
    # frozen MAXMEM (= mem-per-cpu - 3 GB) grows with it, buying batching speed.
    if is_gw and args.gw_node_frac > 0:
        _mpc, _, _, _ = compute_request_geometry(
            candidates[0], partition_info, args.mem_util,
            reserve_mb=_node_reserve_mb(partition_info, _main_margin),
            rss_overhead=args.rss_overhead, gw_node_frac=args.gw_node_frac)
        candidates[0].memory.maxmem_mb = gw_maxmem_from_request(_mpc)

    # Capture the full human-readable report so it can both print to the console
    # and be appended to report.out (for the dry-run -> recommend -> test chain).
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        print_dryrun_summary(summary)
        print_partition_summary(
            partition_name=args.partition, partition_info=partition_info,
            cpus_per_node=cpus_per_node, numa_cores=numa_cores,
            min_cores=args.min_cores, max_cores=args.max_cores)
        if is_gw and summary.calc_type in ("GW_LOWSCALING", "RPA_LOWSCALING") \
                and not summary.nomega:
            print("[GW NOTE] Low-scaling GW/RPA detected but NOMEGA could not be "
                  "read; using a MAXMEM-only recommendation. Pass --nomega N.\n")
        print_candidate_table(best_each, top=max(1, args.top))
        print_best_candidate(
            candidate=candidates[0], partition_name=args.partition,
            partition_info=partition_info, summary=summary,
            email=args.email or None, job_name=args.job_name,
            executable=executable, time_limit=args.time,
            gw_node_frac=(args.gw_node_frac if is_gw else 0.0))
        print(f"[MEMORY POLICY] SLURM memory sized for >= "
              f"{args.mem_util*100:.0f}% utilisation (request = need / "
              f"{args.mem_util:.2f}); vasp-test will refine it from a real run.")
    out_text = buf.getvalue()
    sys.stdout.write(out_text)

    if args.csv is not None:
        write_csv(args.csv, candidates)
        print(f"[CSV] Full ranked list written to {args.csv}")

    if args.no_write:
        return 0

    # Geometry + 80%-utilisation memory for the production job (GW: SWEET-raised).
    best = candidates[0]
    _frac = args.gw_node_frac if is_gw else 0.0
    _reserve = _node_reserve_mb(partition_info, _main_margin)
    mem_per_cpu, nodes, ntpn, node_mem = compute_request_geometry(
        best, partition_info, args.mem_util, reserve_mb=_reserve,
        rss_overhead=args.rss_overhead, gw_node_frac=_frac)
    script_text = slurm_script(
        candidate=best, partition_name=args.partition,
        partition_info=partition_info, summary=summary,
        email=args.email or None, job_name=args.job_name,
        executable=executable, time_limit=args.time, mem_util=args.mem_util,
        reserve_mb=_reserve, rss_overhead=args.rss_overhead, gw_node_frac=_frac)

    meta = {
        "stage": "recommend",
        "calc": summary.calc_type,
        "ranks": best.total_ranks,
        "kpar": best.kpar, "ncore": best.ncore, "npar": best.npar,
        "nsim": best.nsim,
        "prod_partition": partition_info.get("slurm_name", args.partition),
        "prod_cpn": cpus_per_node,
        "node_mem_mb": node_mem,
        "mem_per_cpu": mem_per_cpu,
        "pred_mem_per_rank": int(round(best.memory.per_rank_mb)),
        "pred_flat_mb": int(round(best.memory.base_mb)),
        "pred_nodes": nodes,
        "pred_ntpn": ntpn,
        "mem_util": args.mem_util,
        "exe": executable,
    }
    script_text = _embed_recommendation(script_text, best, meta)

    try:
        sp_path = Path(args.write_slurm)
        sp_path.write_text(script_text + "\n")
        try:
            os.chmod(sp_path, 0o755)
        except OSError:
            pass
        print(f"\n[FILES] production SLURM script -> {sp_path}"
              f"   (submit with: sbatch {sp_path})")
        if args.write_incar is not None:
            Path(args.write_incar).write_text(best.incar_snippet + "\n")
            print(f"[FILES] INCAR snippet           -> {args.write_incar}")
    except OSError as exc:
        print(f"[FILES] WARNING: could not write {args.write_slurm}: {exc}",
              file=sys.stderr)

    # Apply the recommended parallelisation to the INCAR so vasp-test and the
    # production run use it (KPAR/NCORE always; NPAR for DFT). Backup INCAR.bak.
    if not args.no_apply_incar:
        applied = apply_parallel_to_incar(Path("INCAR"), best.kpar, best.ncore,
                                          best.npar, best.calc_type != "DFT")
        if applied:
            print(f"[FILES] applied to INCAR        -> {' '.join(applied)}"
                  f"  (backup: INCAR.bak)")

    # Pipeline state for vasp-test (the FIXED config it must validate + scale).
    write_state(args.state, meta)

    # Combined, human-readable report.
    if not args.no_report:
        append_report(args.report, "STAGE 2/3 -- PARALLELIZATION RECOMMENDATION "
                      "(vasp-recommend-slurm)", out_text)
        print(f"[FILES] report section appended -> {args.report}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
