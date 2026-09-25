# WolfPack-DFT Toolkit

A collection of helpers for running and analysing VASP calculations on SLURM clusters.
Install once with `./install.sh`: every script is exposed on `$PATH` via a
symlink in `~/.local/bin/`, so the commands work from any directory. Every
script supports `--help` / `-h`.

---

## Installation

```bash
git clone <this-repo> WolfPack-DFT   # or copy the folder onto your cluster
cd WolfPack-DFT
./install.sh                          # symlinks + conda env + cluster wizard
```

`install.sh`:

1. **Symlinks every command** into `~/.local/bin/` pointing back at this
   folder. The command name always matches the script (e.g. `vasp-clean` →
   `vasp_clean.sh`, `vasp-test` → `vasp_test.sh`, `vasp-recommend-slurm` →
   `vasp_recommend_slurm.py`). Scripts are *not* copied, so `git pull`
   updates every command at once — **don't delete this folder after installing.**
2. **Creates a conda environment** (`wolfpack-dft`) with every Python
   dependency the toolkit needs: `numpy`, `scipy`, `matplotlib`, `pymatgen`,
   plus the optional `glow` Markdown renderer used by `wolfpack`.
3. **Adds `~/.local/bin` to your `PATH`** (a small tagged block in `~/.bashrc`)
   if it isn't already there.
4. **Runs the cluster wizard** (`vasp-configure`) — see below.
5. **Writes a manifest** (`~/.local/share/wolfpack-dft/`) so the uninstaller
   can undo everything precisely.

Activate the environment before using the Python tools (`vasp-calculate-u`,
`build-supercell`, `build-magnetic-configs`, `vasp-plot-fatbandsdos`):

```bash
conda activate wolfpack-dft
```

Useful flags: `./install.sh --email me@uni.edu` (pre-fill email),
`--env NAME` (target env), `--bin-dir DIR`, `--no-conda` (symlinks only),
`--no-path`, `--no-configure` (skip the wizard), `-y` (no prompts; auto-detect
the cluster). See `./install.sh --help`.

### Cluster configuration (`vasp-configure`)

The toolkit is **not** wired to any one machine: a per-user *cluster profile*
(`~/.config/wolfpack-dft/cluster.conf`) tells the SLURM tools how your cluster
looks. `install.sh` runs the wizard for you; re-run it any time:

```bash
vasp-configure          # interactive wizard (detects + asks)
vasp-configure --show   # print the current profile
vasp-configure --edit   # hand-edit the profile in $EDITOR
```

> **A job died with `execve(): vasp_std: No such file or directory`?** That
> means the configured module line doesn't put `vasp_std` on `PATH` (a wrong or
> conflicting module — e.g. an Lmod *"cannot be loaded as requested"* error
> aborts the load, so VASP is never available). No reinstall needed:
>
> ```bash
> vasp-configure --verify   # loads your modules and reports exactly what fails
> vasp-configure            # re-pick a version — it now TEST-LOADS each choice
> vasp-configure --edit     # or fix the WP_VASP_MODULES line by hand
> ```
>
> The wizard now verifies every choice by actually loading it and checking that
> `vasp_std` appears, and when `module spider` lists several prerequisite
> combinations it tries each and keeps the first that works — so a conflicting
> set (like three different `gcc` versions) is rejected automatically.

It detects and lets you confirm/override:

- your **notification email** (used as `#SBATCH --mail-user`);
- the **VASP module(s)** to load — discovered from `module avail`/`spider`, so
  you **choose the version**, and its prerequisites are detected when possible;
- your **debug** and **main** partition names;
- **cores per node** and **memory per node** for each (from `sinfo`);
- the **maximum cores** you may request (from `sacctmgr`, else you set it);
- **pipeline policy** (no longer hardcoded): the test/debug **walltime cap**, your
  cluster's minimum **memory-utilisation policy** (e.g. 80 %; tools target +1 %), the
  **magic pre-spike hold** (min), and the **debug RAM reserve** (GB) left for login.

Every value has a manual fallback if auto-detection isn't available. The result
flows into `vasp-recommend-slurm`, `vasp-dry-run` and `vasp-test`, so the SLURM
scripts they emit target **your** partitions and load **your** modules.

**No cluster? Install anyway.** The plotting and analysis tools
(`vasp-plot-fatbandsdos`, `vasp-quick-plots`, `vasp-check`, `build-supercell`,
`build-magnetic-configs`,
`vasp-calculate-u`) need **no** cluster profile and no VASP install — only the
conda env. `install.sh` detects the absence of SLURM/modules and skips the
wizard, so you can install on a laptop and plot from copied calculation folders.

### Uninstallation

```bash
./uninstall.sh            # remove symlinks, the conda env, the PATH block,
                          # the manifest, and any legacy ~/Useful_scripts dir
./uninstall.sh -y         # same, no prompts
./uninstall.sh --keep-env # keep the conda environment
./uninstall.sh --purge-repo  # ALSO delete this toolkit folder
```

The uninstaller is nuclear but safe: it only removes the conda env if
`install.sh` created it, and it never deletes this source folder unless you
pass `--purge-repo`.

---

## Quick reference

| Command | Source script | What it does |
|---------|--------------|--------------|
| `vasp-configure` | `vasp_configure.sh` | Build your cluster profile (email, VASP modules, partitions, cores, memory, max-cores) |
| `vasp-dry-run` | `vasp_dry_run.sh` | **Pipeline STAGE 1** — 1-rank dry run on debug → dimensions (NKPTS, NBANDS, FFT grids, plane waves) + starts `report.out`. It is free because `--dry-run` exits before VASP allocates — which also means it brings **no memory table**; memory is measured in STAGE 3 |
| `vasp-recommend-slurm` | `vasp_recommend_slurm.py` | **Pipeline STAGE 2** — read that OUTCAR → KPAR/NCORE + `slurm.sh` (80%-mem, multi-node split) |
| `vasp-test` | `vasp_test.sh` | **Pipeline STAGE 3** — benchmark of the *fixed* config (job `slurm_benchmark.sh`) → scale measured RAM to production → write the **definitive** `slurm_vasptest.sh` + (GW) `MAXMEM` into the INCAR; prints a **predicted-vs-measured** comparison + validation verdict of the chosen parallelization & node config |
| `vasp-scf-loop` | `vasp_chain.sh` | Converge a **static SCF as a chain of short jobs** for queues where a long walltime waits a long time. Each job caps its electronic steps to fit the walltime, restarts from the previous one's `WAVECAR`, and submits its own successor. Launch once; it runs until the SCF converges. Needs `vasp-test` to have run |
| `vasp-relax-loop` | `vasp_chain.sh` | The same for a **structural relaxation**: chunks `NSW`, never `NELM` — a truncated electronic loop gives wrong forces. Validates `CONTCAR` before it becomes the next `POSCAR`, and recovers when an ionic step runs out of `NELM`. Picks the chunk walltime from a study of the queue, resizes each chunk's memory from what the last one used, and continues after an OOM kill with a plain `--resume` |
| `vasp-diagnose` | `vasp_diagnose.sh` | **Failure + data-salvage** analysis of a run — root cause (OOM / walltime / crash / missing-input), measured peak RAM, layout, **and whether the data is still usable** (FULL / PLOTTABLE / PARTIAL / NOT — e.g. a killed DFT+U run whose occupations/eigenvalues survived). Human report + a machine-readable summary line. Read-only |
| `backfill-study` | `backfill_study.py` | **How long this job will wait in the queue**: the job script as written, and the same job at other walltimes (quartiles of the wait), from the partition's `sacct` history of jobs shaped like it; and your fairshare now (`sshare`, `sprio`). `vasp-relax-loop` asks it at launch, with its own ionic-step estimate, for the chunk walltime. Estimates no run time; launches nothing |
| `vasp-check` | `vasp_check.sh` | **What a run produced, as data** — parameters, convergence, forces, cell and stress, what the relaxation changed, moments, gap with the VBM/CBM band, spin and k-point, GW quasiparticle energies — plus checks against the run's own NELM/EDIFFG and VASP's rules. No physical interpretation. (Why it died / salvageability → `vasp-diagnose`) |
| `vasp-slurm-report` | `vasp_slurm_report.sh` | **What every job in a folder actually cost** — the dry-run, the benchmark, the production job and every chunk of a `vasp-relax-loop`/`vasp-scf-loop` chain (older chains too), each labelled with its stage — reads `sacct` for them and turns them into the three ratios that say whether the allocation was earned: CPU efficiency (`TotalCPU / (Elapsed x NCPUS)`, which is what catches a 240-rank job running on 1), memory efficiency (`AveRSS x NCPUS / ReqMem` — *Ave*, not *Max*, because rank 0 is an outlier at high `KPAR`), and time use (`Elapsed / Timelimit`). Flags anything under 50% CPU, anything that ran to its walltime, and any state that is not clean. `--csv` for a machine-readable table. Read-only: it never submits or cancels anything |
| `vasp-clean` | `vasp_clean.sh` | Selective cleanup of VASP output files (with dry-run) |
| `vasp-nuke` | `vasp_nuke.sh` | Fast no-questions-asked delete of all VASP output files |
| `run-nscf-steps` | `run_nscf_steps.sh` | Hubbard U workflow Step 1: submit NSCF perturbation jobs |
| `run-scf-steps` | `run_scf_steps.sh` | Hubbard U workflow Step 2: submit SCF perturbation jobs |
| `collect-u-data` | `collect_u_data.sh` | Hubbard U workflow Step 3: collect occupations → U_data.dat |
| `vasp-calculate-u` | `vasp_calculate_u.py` | Hubbard U workflow Step 4: linear fit → print U |
| `vasp-plot-fatbandsdos` | `vasp_plot_fatbandsdos.py` | Fat-band + projected DOS figure (pymatgen; `wolfpack_plot/` package) |
| `vasp-quick-plots` | `vasp_quick_plots.sh` | One figure per method (plain/one_orbital/duo/rgb/cmyk/stacked) into numbered `Plots/` sub-folders, projections auto-picked over an energy window |
| `build-supercell` | `build_supercell.py` | Build a plain VASP supercell from a POSCAR |
| `build-magnetic-configs` | `build_magnetic_configs.py` | **Enumerate the inequivalent collinear spin orderings** of a structure into one ready-to-run folder each (NM / FM / AFM / FiM), with a `.cif` and `.vesta` to look at them |
| `wolfpack` | `wolfpack.sh` | Print this README (`--help`), the plotting guide (`--plots`) or the command list (`--list`) |

> Setup commands (run from this folder, not on `$PATH`): `./install.sh` and
> `./uninstall.sh` — see [Installation](#installation).

---

### How the toolkit edits your INCAR

Several commands write tags into your INCAR — `vasp-recommend-slurm` sets
`KPAR`/`NCORE`, `vasp-test` pins the benchmark layout, the chunked runs rewrite
`NELM`/`NSW` once per chunk, `build-magnetic-configs` sets `ISPIN`/`MAGMOM`.
All of them go through one library (`wolfpack_incar.py`, and `wolfpack_incar.sh`
for the tools that run inside a compute job), which follows your file rather
than imposing a format:

- A tag that is **already there** has its value replaced **where it sits**. Its
  indentation, its column alignment and its own trailing comment are kept.
- A tag that is **new** goes to the **end of its section** — `MAGMOM` under
  *Startup job description*, `KPAR` under *Parallelization* — aligned the way
  that block already aligns.
- If the section does not exist it is created, in the canonical order, with a
  `!-----` header. If your INCAR has **no** section headers at all, it stays
  that way and the tag is simply appended.
- A tag that has to go is **commented out in place**, never deleted: the value
  it held is evidence.

So an INCAR laid out in sections comes back laid out in sections, and a flat one
comes back flat.

---

## 1. The parallelization pipeline (dry-run → recommend → test)

Three commands, run **in order, with no arguments and nothing to edit by hand**.
Each stage reads what the previous one left behind, so from a folder with just
`INCAR KPOINTS POSCAR POTCAR` you only ever type:

```bash
vasp-dry-run            # STAGE 1  (submit; wait for it to finish)
vasp-recommend-slurm    # STAGE 2  (instant, on the login node)
vasp-test               # STAGE 3  (submit; wait for it to finish)
```

When it's done the folder contains exactly:

```
INCAR  KPOINTS  POSCAR  POTCAR   # your inputs (KPAR/NCORE/NPAR applied; backup INCAR.bak)
slurm_dryrun.sh                  # STAGE 1 dry-run job
slurm.sh                         # STAGE 2 recommend first-pass production job
slurm_benchmark.sh               # STAGE 3 debug benchmark job
slurm_vasptest.sh                # STAGE 3 DEFINITIVE production job (measured memory) <- sbatch this
report.out                       # one tidy report from all 3 stages
.wolfpack/                       # everything else: the captured OUTCARs, the job
                                 # logs, the pipeline state, and the benchmark's
                                 # scratch directory
```

Nothing the pipeline creates lands beside your inputs except the job scripts you
might submit and the report you read. The benchmark's scratch used to be a
`vasp_test_<jobid>/` in this folder, one per failure, each still holding a
`CHGCAR` and a `WAVECAR`; it now lives under `.wolfpack/`, and a failed one keeps
only what makes it diagnosable (`OUTCAR`, `OSZICAR`, `stdout`) — the heavy files
are dropped on every exit path, the walltime kill included.

Intermediates (the dry-run OUTCAR, pipeline state, SLURM logs) live in a hidden
`.wolfpack/` folder so your directory stays clean.

### STAGE 1 — `vasp-dry-run`

Renders a self-contained `slurm_dryrun.sh` (resolved `#SBATCH` + module loads
from your `vasp-configure` profile) and submits it. The job runs a 1-rank VASP
`--dry-run` inside `.wolfpack/`, captures VASP's memory table to
`.wolfpack/dryrun_OUTCAR`, and **starts `report.out`**.

```bash
vasp-dry-run            # writes ./slurm_dryrun.sh, submits it (~30 s of compute)
```

### STAGE 2 — `vasp-recommend-slurm`

With **no argument**, auto-finds `.wolfpack/dryrun_OUTCAR`. It enumerates
(KPAR, NCORE, NPAR) candidates, ranks them by the
[VASP-wiki parallelization rules](https://www.vasp.at/wiki/index.php/Category:Parallelization),
and writes the production job to **`slurm.sh`**.

> **Two rule sets, kept apart.** VASP parallelizes GW/RPA by different rules
> than a relaxation or an SCF, so the tool uses separate enumerators, scorers
> and rejections. Every recommendation says which one produced it
> (`parallelization rules : ...`).
>
> | | relax / SCF (D) | GW / RPA (G) |
> |---|---|---|
> | ranks fill whole nodes | D1 | G1 (same: MPI placement) |
> | `N_ranks % KPAR == 0` | D3 | G2 |
> | `NKPTS % KPAR == 0` | **D2, required** | **not applied** — priced, not vetoed |
> | `NCORE` | D4/D5 — factor of cores-per-node and of the k-group | **G3 — always 1** (which makes D4/D5 vacuous) |
> | `NBANDS` | D6 — padded to a multiple of `NPAR` | not applied |
> | `NTAUPAR`/`NOMEGAPAR` | — | G4 divisors of `NOMEGA`; G5 their product divides the k-group |
> | what decides | k-point coverage | **G6 — the k-group holds χ and W and must fit memory** |
>
> `vasp-check` makes the same split when auditing a finished run.
> [`tests/test_08_recommend/`](tests/test_08_recommend/) sweeps the recommender
> over k-point counts, calculation types and core caps and checks every
> recommendation against the rules of **its own** regime: 32 recommendations,
> 0 violations.

### Allocation profile: whole nodes, or the ranks you actually need

`vasp-configure` asks how your cluster hands out cores, and the answer changes
the shape of every job script:

| `WP_ALLOC_PROFILE` | what it asks for | the cap counts |
|---|---|---|
| `whole-nodes` (default) | whole nodes: `--ntasks` is a multiple of the cores per node | **cores** — n nodes cost `n x cpus-per-node` whatever runs on them |
| `balanced` | the rank count the physics wants, spread **evenly**: n nodes of m ranks with `n x m = ntasks` exactly | **ranks** — for a cluster that shares nodes between jobs |

On 48-core nodes a calculation with 41 irreducible k-points wants a rank count
that 41 divides, so KPAR can use them. `whole-nodes` gives it 192 or 240 and
KPAR falls back to 1; `balanced` gives it **3 nodes x 41 = 123**.

Even occupancy is not a nicety. An MPI rank count split unevenly over nodes
makes one node the slowest, and every collective in every electronic step waits
for it — invisible in the output, and visible only as a job that is slower than
its rank count suggests.

Both profiles allow a rank count **smaller than one node**: `NPAR` cannot exceed
`NBANDS`, so a cell with few bands cannot use a whole node however many cores
it is given.

```bash
vasp-configure --alloc-profile balanced     # or: whole-nodes
vasp-configure --edit                       # or edit WP_ALLOC_PROFILE by hand
```

`slurm.sh` carries:

- the chosen **KPAR/NCORE/NSIM** embedded as comments **and written into your
  `INCAR`** so STAGE 3 and production match (KPAR + NCORE for GW; KPAR + NCORE +
  NPAR for DFT; backup at `INCAR.bak`, opt out with `--no-apply-incar`);
- a memory request sized to the **≥ 80 % utilisation** rule (see below);
- **automatic, k-group-aware multi-node splitting** — keeps **whole k-point groups
  on a node** (`nodes = KPAR / g`, never straddling a k-group across the boundary —
  crucial for GW, where a split group means cross-node χ/W traffic). The per-node
  ceiling is computed from the **real predicted usage**, not the padded request, and
  the request is then **trimmed to fit the node** (kept within `[usage, usage/0.80]`,
  so utilisation stays between 80 % and 100 % — policy-compliant *and* no OOM). It
  only straddles (plain memory split) when a single group can't fit a node even at
  its real usage — i.e. the group is genuinely larger than one node.

It also appends its recommendation to `report.out` and saves the fixed config to
`.wolfpack/state.env` for STAGE 3.

```bash
vasp-recommend-slurm                    # auto-find OUTCAR -> ./slurm.sh + report.out
vasp-recommend-slurm dryrun_OUTCAR      # or pass an OUTCAR explicitly (manual use)
vasp-recommend-slurm --partition main --max-cores 256 --top 5
vasp-recommend-slurm --help             # full flag list
```

**Useful flags:** `--partition {main,debug,…}` · `--max-cores/--min-cores N` ·
`--mem-util F` (utilisation target, default `0.80`) ·
`--rss-overhead F` (VASP-table → real-RSS factor, default `1.4`) ·
`--calc-type {auto,dft,gw,gw-low,rpa-low}` · `--no-write` (print only).

> **Why the memory estimate here is only a starting point.** VASP's reported
> per-rank memory does **not** include FFT plans, MPI/UCX buffers, the
> scaLAPACK/ELPA workspace or the allocator high-water mark — real RSS is
> typically 1.4–3× larger (much more for GW/RPA). STAGE 2 multiplies by
> `--rss-overhead` and the 80 % rule to stay safe, but the **authoritative**
> memory comes from STAGE 3, which *measures* it.

### STAGE 3 — `vasp-test`

> **Testing a candidate other than the best: `vasp-test -n N`.** STAGE 2 prints a
> `[TOP CANDIDATES]` table; the score *ranks* them, only a benchmark *measures*
> them. `vasp-test -n 3` benchmarks row 3 instead of row 1 — `-n N`,
> `--candidate N` or just `vasp-test 3` all work, and with no flag you get
> whatever the pipeline is currently set to (row 1 unless you asked otherwise).
>
> It does not reinterpret the table: it re-runs `vasp-recommend-slurm --pick N`
> with the **same arguments as the first time** (recorded in `state.env`), so
> row N is a row of the same table you read. That rewrites `INCAR`, `slurm.sh`
> and `state.env` for candidate N and then benchmarks it, exactly as if the
> recommender had chosen it — the definitive `slurm_vasptest.sh` follows too.
> Asking for a row that does not exist refuses and says how many there are.
>
> `vasp-recommend-slurm --pick N` does the selection on its own if you just want
> the files, without benchmarking.

Reads the **fixed** config from STAGE 2 and benchmarks **that exact config** (job
`slurm_benchmark.sh`) — not your raw INCAR. VASP runs for `WP_TEST_WALLTIME_MIN`
minus a short analysis margin, inside a job capped at that walltime. The recommended
rank count (e.g. 120) won't fit on the debug partition, so it runs the same
**KPAR/NCORE** at the largest rank count that *does* fit (up to both debug nodes) at
the maximum debug memory (node RAM − the `WP_DEBUG_RESERVE_GB` reserve). Then it:

1. reads the SLURM metrics (`MaxRSS`, CPU efficiency) of the fixed config;
2. **scales** the measured per-rank memory from the test rank count **up to the
   production rank count** (VASP component-distribution rules: wavefunctions
   ∝ 1/ranks, grid ∝ 1/NPAR, projectors ∝ 1/NCORE);
3. sizes the production memory to the **utilisation policy** and lays it out as
   one node if it fits else exactly **KPAR nodes** (one whole k-group/node), then
   writes the **definitive `slurm_vasptest.sh`** (recommend's `slurm.sh` is kept);
4. prints a **VERDICT** on whether the recommended config is adequate and appends
   STAGE 3 to `report.out`.

```bash
vasp-test               # renders ./slurm_benchmark.sh, submits it, writes slurm_vasptest.sh
# KPAR/NCORE/NPAR are already in your INCAR (applied by vasp-recommend-slurm):
sbatch slurm_vasptest.sh   # the definitive production job, with measured memory
```

**Cluster policies (from the profile; override via env):**

- **Memory utilisation** — the request is sized so the job *uses* at least the
  `WP_MEM_UTIL_MIN` policy (e.g. 80 %); the tool aims 1 % above it
  (`request = predicted_use / 0.81`) so a slightly-low real usage still clears the
  floor, while keeping a safety margin.
- **Debug/login reserve** — on the debug partition, **`WP_DEBUG_RESERVE_GB` per
  node** (default 4 GB) is kept free so the (shared) login node stays responsive.

> **Feasibility & auto-recovery (GW).** A GW k-group *cannot* be split across nodes,
> so a config is only valid if one whole k-group fits a single node.
> `vasp-recommend-slurm` only ever picks a **feasible** config — as the node memory
> tightens it automatically climbs to a higher `KPAR` (smaller k-groups: 3 → 7 → … →
> NKPTS), and if *nothing* fits it stops with an `[INFEASIBLE]` message (lower
> `ENCUTGW`/`NOMEGA`/`NBANDS`, or use a larger-memory partition). If the **measured**
> memory from `vasp-test` is what makes the chosen group too big for a node, vasp-test
> **auto-recovers**: it re-runs recommend *calibrated to the real measurement*, which
> re-selects a feasible `KPAR`, rewrites your `INCAR` + `slurm.sh`, and tells you to
> re-run `vasp-test` to benchmark the new config.

**Flags & tunables (export before running):**

| Variable | Default | Meaning |
|----------|---------|---------|
| `VASP_TEST_MINUTES` | `30` | length of the timed run (your debug walltime must allow it) |
| `VASP_TEST_MAX_CORES` | `2 × cores/node` | cap on debug ranks for the benchmark |
| `VASP_EXE` | `vasp_std` | `vasp_std` / `vasp_gam` / `vasp_ncl` |
| `VASP_TEST_MEM_UTIL` | `0.80` | request memory so usage ≥ this fraction |
| `VASP_TEST_DEBUG_MARGIN_MB` | `16384` | memory kept free per debug/login node |

The debug/main partitions, cores/node, memory/node, modules and email all come
from your `vasp-configure` profile (`vasp-configure --show` to check). The 80 %
target and RSS-overhead factor can be pinned in the profile as `WP_MEM_UTIL` and
`WP_RSS_OVERHEAD`.

> Requires SLURM job accounting (`sacct`/`MaxRSS`) so memory can be anchored to
> the measured peak. If it is off, it falls back to VASP's own memory table.

### Chunked runs — `vasp-scf-loop`

Some schedulers make a long walltime wait a long time: a 10-hour job can sit in
the queue for days while a 1-hour job backfills into a gap immediately. This runs
the same calculation as a chain of short jobs.

```bash
cd <calc folder>          # after dry-run -> recommend -> test
vasp-scf-loop             # start, then leave it alone
vasp-scf-loop --status    # where is it
vasp-scf-loop --stop      # finish the current chunk, then stop cleanly
vasp-scf-loop --resume    # continue a stopped chain
```

Each chunk caps `NELM` to what fits the walltime, restarts from the previous
chunk's `WAVECAR`, and submits the next one itself. There is no `--dependency`
chain: exactly as many jobs run as are needed, and nothing is left queued when it
converges. The first chunk is deliberately short — it calibrates against the real
per-step time, and every later chunk is sized from that measurement.

**The whole chain spends at most your INCAR's `NELM`.** A chain stands in for one
job with that setting, so chunking never quietly enlarges the step budget.

**Stopping is safe.** `--stop` lets the running chunk finish, archive and record
itself before halting, so nothing is lost and `--resume` picks up where it left
off. `--stop --now` additionally writes a `STOPCAR`, VASP's own clean stop, which
still writes the `WAVECAR`.

**Overrunning the walltime is survivable.** A walltime `SIGKILL` cannot be caught
and would kill the job exactly where it submits its successor — chain dead, chunk
lost. Each chunk asks SLURM for a catchable warning signal first and converts it
into a `STOPCAR`, so VASP exits cleanly and the normal decision logic still runs.
An overrun costs a shorter chunk, not the run.

It stops and tells you why on: a failed or crashed chunk, a lost `WAVECAR`
(without which every later chunk would restart cold and never converge), an
energy that stops improving, `NaN` in the OSZICAR, or running out of `NELM`.
**The only limit is your own `NELM`** (`NSW` for a relaxation): there is no cap
on the number of chunks, on the compute accumulated, or on how many days the
chain has been running. It never resubmits into a failure. Per-chunk history is in `wolfpack_chain/chain.log`; on success it appends
one block to `report.out` and runs `vasp-check` for you.

> Short jobs backfill better than long ones **only if they are also small**. For a
> job spanning several nodes the launcher says so, with the queue statistics it
> used, rather than letting you find out after a week.

### Chunked relaxation — `vasp-relax-loop`

The same chain for a structural relaxation. It chunks `NSW`, never `NELM`,
because a truncated electronic loop gives wrong forces. Everything above holds,
plus four things specific to long relaxations on a real cluster.

```bash
backfill-study                     # how long this job waits in the queue; launches nothing
vasp-relax-loop                    # launch: chunk walltime from its step estimate + the queue
vasp-relax-loop --walltime 120     # launch with a chunk walltime you choose
vasp-relax-loop --resume           # after a stop, a crash, or an OOM kill
vasp-relax-loop --fresh            # archive an unfinished chain, start a new one here
```

**The chunk walltime is chosen once, then fixed.** At launch it comes from
`--walltime` if you give one (whole minutes). Otherwise it comes from
**`backfill-study`** (below), and if the study cannot decide, from the profile's
`WP_CHUNK_WALLTIME_MIN`. It
is capped at the partition's `MaxTime`; an explicit `--walltime` above `MaxTime`
is refused, not silently cut. Every chunk of that chain then uses it, and the
number of ionic steps per chunk adapts to it instead.

**A chain that cannot fit one ionic step does not start.** If a single ionic step
(estimated from `vasp-test`, ×1.5 for a first chunk that starts cold) does not
fit in the chunk, every chunk would be killed before completing one. The
launcher refuses, and tells you the shortest walltime that would work:

```
[FAIL] not even ONE ionic step fits in a 60-min chunk.
 One step is ~2555.6s (estimated from the benchmark); a first chunk starts cold, so it must hold 1.5 x that: 3834s.
 ...
 The shortest chunk that holds one: 70 min.
 Launch with:   --walltime 70      (or more ranks, for a faster step)
```

If steps grow later (a cell relaxation's basis grows with the volume), the chain
stops before submitting a chunk that cannot complete one. The geometry reached
so far is kept in `POSCAR`, and the stop names the new chain that would fit:
`vasp-relax-loop --fresh --walltime 83`.

**`backfill-study`: how long a job waits in this queue.** A command of its
own, and what `vasp-relax-loop` asks at launch. It reads the job from
`slurm_vasptest.sh` (or `slurm.sh`) and the partition's accounting history
(`sacct`, last 30 days; `WP_CHAIN_QUEUE_DAYS` changes it). It estimates no run
time: that is the chain's job, from `vasp-test`'s measurements.

```
backfill-study -- config_01
  partition   sequana_cpu   (MaxTime: not shown by scontrol)
  your job    1 node x 48 cores, 73 GB, --time=3-00:00:00   (slurm_vasptest.sh)
  history     699 jobs that started on sequana_cpu in the last 30 days

YOUR JOB
  Predicted wait: about 29.3 h   (Q1 19.2 h, Q3 2.2 days)
  from 15 of your own jobs of your size that asked for 2 to 4 days (your fairshare today 0.600).
  All 162 such jobs, any user: about 35.1 h.
  Your job 11599543 here asked for 8 h and waited 24.3 h.

HOW LONG JOBS OF YOUR SIZE WAITED, BY THE WALLTIME THEY ASKED FOR
  walltime asked         0-1 h    1-4 h   4-12 h  12-24 h    1-2 d    2-4 d
  Q1  (25 % within)        8 s     12 s   55 min      1 s   11.2 h   18.4 h
  Q2  (50 % within)       15 s     19 s    2.5 h   23.8 h   19.6 h   35.1 h
  Q3  (75 % within)       42 s     33 s    5.6 h   43.6 h   40.1 h    3.4 d
  jobs                      46      291      132       27       41      162
  your size = jobs that asked for 1 node, 24-96 cores, 24-219 GB (yours: 48 cores, 73 GB).
  Q1, Q2, Q3: a quarter, half and three quarters of them had started within that time.
  Walltimes with fewer than 8 such jobs are not shown.

FAIRSHARE NOW   (Fair Tree)
  your factor   0.600   jdoe in account fisica; 1.000 is the top-ranked user
  above you     4 of the 10 user associations (user + account) have a higher factor
  shares, use   account fisica: 25.0 % of the shares, 31.0 % of the use, among its sibling accounts
                jdoe: 33.3 % of the shares, 41.8 % of the use, within fisica
  weights       fairshare 10000, age 1000 (full after 7 days), job size 1000, partition 1000, QOS 0
  worth         your factor adds 6000 points to each of your jobs' priority
                0.1 of factor = 1000 points = what 7.0 days of waiting add (age)
  pending now   12 jobs of 9 users on sequana_cpu; 4 carry more fairshare points than yours
                your job 11601005: priority 6870, 4 pending jobs above it
  decay         past use counts half after 7 days (PriorityDecayHalfLife)
```

(An illustration, from a synthetic history and fairshare shaped like one
partition's; the jobs' owners were drawn at random.)

**Jobs of your size** are the partition's jobs from the window that started
and asked for about what yours asks: the same node band (1, 2–4, 5–16, 17+),
between half and twice your cores, and between a third and three times your
memory. The table's footer puts that in numbers. If no walltime has 8 such
jobs, the comparison drops memory, then cores, then nodes, and the title says
which one it used.

**The table** has the quartiles of the wait down (Q1: a quarter of those jobs
had started by then, Q2 the median: half, Q3: three quarters), and the
walltime they asked for across. Each column is its own set of jobs, and the
last row says how many. Only columns with at least 8 are shown.

**The prediction** (YOUR JOB) is your column, narrowed by fairshare: the
jobs in it whose owners' fairshare today is closest to yours. It takes those
within 0.05 of your factor, then 0.10, 0.20 and 0.30, until there are 8 of
them. Your own jobs have your factor, so with 8 of them they are the answer.
If fairshare orders this queue, those jobs waited the way yours will. If it
does not, they are a sample of the same column, and the prediction says what
the column says. The whole column's median is printed next to it for
comparison. The owners' factors are today's: what they were when those jobs
ran is not recorded anywhere `sacct` or `sshare` can show. When fairshare
cannot narrow the column (no `sshare`, owners hidden by `PrivateData`, a
weight of 0, fewer than 8 jobs within 0.30), the prediction is the whole
column, and the reason is given. Or it says why there is no estimate at all:
more than the partition's MaxTime, or more than anyone asked for in the
window. Outside a calculation folder, give the job: `--partition --nodes
--cpus --mem-mb --time`.

Last, **where you stand today**. The table is what the queue did, over weeks,
to everyone's jobs of your size. What orders the pending jobs now is their
priority, and your part of it is your fairshare. From `scontrol show config`,
`sshare -a` and `sprio`, and in SLURM's own terms:

- **your factor** (0 to 1). Under Fair Tree, the default since Slurm 19.05, it
  is your rank among the user associations, 1.000 for the top one. Under the
  classic algorithm (`PriorityFlags=NO_FAIR_TREE`), 0.500 means you used
  exactly your share.
- **shares, use**: your account's share against its use among its sibling
  accounts, and yours within the account.
- **weights**, and what your factor is **worth**: priority is the sum of weight
  × factor, and the age factor reaches 1 after `PriorityMaxAge` of waiting.
  So 0.1 of fairshare is worth a fixed number of days of waiting.
- **pending now**: the partition's pending jobs, how many carry more
  fairshare points than yours, and where each of your own stands.
- **decay**: how fast past use fades (`PriorityDecayHalfLife`).

What a command cannot tell (no `sshare`, or `PrivateData` hiding the other
users) is said, not counted as zero. `priority/basic` (FIFO) is said to have no
fairshare. `--account` picks the account when you have several (default: the
job script's, else yours); `--no-fairshare` leaves the section and the
narrowing out. The chain's chunk walltime uses neither.

It does not simulate the scheduler. It measures what the scheduler actually
did, backfill included, to jobs like yours. What it cannot see: jobs still
waiting (only jobs that started have a wait to measure), and other users' jobs
if the cluster's `sacct` shows you only your own.

**At launch**, `vasp-relax-loop` estimates the ionic-step time from
`vasp-test`'s measurements and hands it to `backfill-study`. For each candidate
walltime, `backfill-study` counts the chunks the relaxation would need (the
chain's own ramp) and picks the smallest `chunks × (median wait + start-up)`.
The table is shown at launch and kept in `wolfpack_chain/backfill_study.txt`.
With too little data the chain uses the profile's walltime;
`vasp-relax-loop --no-queue-study` skips it.

**Memory is measured every chunk and the next one is resized.** After each chunk
the chain reads what it used: `MaxRSS`/`AveRSS` from `sacct`, or, where the
accounting records none, VASP's own `Maximum memory used` from OUTCAR (rank 0,
applied to every rank). It then rewrites the next chunk's `#SBATCH` lines:

```
--mem-per-cpu = (MaxRSS + (ranks per node − 1) × AveRSS) / ranks per node × 1.25
```

This is sized for the heaviest node's total, because that is what SLURM
enforces (`cgroup.conf`, `ConstrainRAMSpace`), not each task. The largest peak
ever measured is never forgotten; for `ISIF ≥ 3` the request also grows with
the cell volume. The **number of ranks never changes**, since your KPAR/NCORE
were chosen for it. When a node can no longer hold them, they are spread over
more nodes. When one rank alone needs more than a node, the chain stops and says
what frees memory (a lower KPAR first). `chain.log` shows each chunk's peak next
to what it was granted. This applies to `vasp-scf-loop` too.

**After an OOM kill: `vasp-relax-loop --resume`, and nothing else.** It works
out that the chunk was OOM-killed (from `sacct`'s `OUT_OF_MEMORY` or
`slurmstepd`'s message), then:

- raises the memory: the larger of 1.5 × what was granted
  (`WP_CHAIN_OOM_FACTOR`) and what the measurements say, spreading over more
  nodes if needed;
- keeps the geometry the dead chunk reached (its `CONTCAR` becomes `POSCAR`);
- counts the ionic steps it completed and adds them to the trajectory, even when
  the whole job died and the chunk could not record anything itself;
- sets aside a `WAVECAR` that was cut off while being written
  (`WAVECAR.partial`), and starts that one chunk cold;
- refuses, with the way out, when no layout the cluster offers can hold it, and
  refuses while a chunk of the chain is still queued or running.

A walltime kill is handled the same way: the walltime stays fixed, and the steps
per chunk come down to what was measured. If not one step completed, it refuses
and tells you to start a new chain with a longer walltime.

**The only limit is `NSW`.** The chain runs until the relaxation converges or
your `NSW` is spent, however many chunks, hours or days that takes. To go past
`NSW`, raise it in `INCAR.chain.bak` (your original INCAR, which a new chain
reads) and start again with `--fresh`.

`--status` shows the chunk walltime and where it came from, the current
allocation, the memory measured, and how many OOM kills the chain has survived.

## 2. VASP run analysis

### `vasp-check`

What a finished or killed VASP run produced, **as data**. It states numbers and
draws no physical conclusions: no "metallic", no "antiferromagnetic", no
advice. The only verdicts are checks against the run's own criteria (NELM,
EDIFFG) and against explicit VASP requirements (NCORE=1 for GW, LASPH with a
meta-GGA, NTAUPAR dividing NOMEGA, ...). All of them are listed together at
the end, one line each.

```bash
vasp-check              # the current directory
vasp-check path/to/calc # a specific directory
```

Sections, each only when the run has the data:

| section | what it shows |
|---|---|
| Run | calculation type, VASP version, completion, files present |
| Parameters | the tags that matter, as VASP applied them, five to a line |
| Electronic convergence | ionic steps, SCF iterations, steps that reached NELM, \|T·S\| per atom |
| Ionic convergence | max and RMS \|F\| (against \|EDIFFG\|), drift, max \|F\| per step, energy per step |
| Forces and stress at this geometry | for a static run: max \|F\|, stress components |
| Cell and stress | volume, lattice lengths, external pressure |
| What the relaxation changed | POSCAR vs CONTCAR, side by side (below) |
| Magnetization | net moment, moment per ion |
| Band edges and gap | E-fermi, gap, VBM/CBM with band, spin and k-point, partially occupied states |
| Occupations | NELECT, occupied bands, NBANDS, plane waves per k-point |
| GW quasiparticles | KS and QP gap, band edges KS → QP, mean Z |
| meta-GGA | POTCAR kinetic-energy density, ICHARG, LASPH, first k-point vs the sibling Scf |
| Checks | `[ OK ]` / `[WARN]` / `[FAIL]` |
| Energy | TOTEN, energy(sigma→0), per atom; the result |

Why a run died and whether its data is usable: `vasp-diagnose`.

Exit codes: `0` = no failed check, `1` = at least one `[FAIL]`, `2` = usage error.

### What the relaxation changed

For any run with ionic steps, `vasp-check` puts the starting `POSCAR` and the
final `CONTCAR` side by side. It reports data only, with no verdicts: one
table per quantity, each value once, with its change.

```
  CELL                          POSCAR       CONTCAR        change        %
    a (A)                     5.624058      5.626850     +0.002792  +0.050%
    ...
    volume (A^3)              241.4820      241.3221       -0.1599  -0.066%
    density (g/cm^3)            6.5421        6.5465       +0.0044  +0.067%
    max |strain| (%)                                        0.1043   Green-Lagrange

  SPACE GROUP                   POSCAR       CONTCAR
    symprec 1e-5          P2_1/c (14)        P1 (1)
    ...

  NEAREST NEIGHBOUR (A)         POSCAR       CONTCAR        change
    shortest                    1.9651        1.9624       -0.0028
    mean over sites             2.0686        2.0675       -0.0011

  ATOMIC DISPLACEMENTS (A)           max          mean           RMS   cell change excluded
    all  (20)                   0.0017        0.0010        0.0012
    La   (4)                    0.0016        0.0013        0.0013
    ...
    moved > 0.0001 A : 16 of 20      largest: #15 O 0.0017, #11 O 0.0017, #12 O 0.0017
```

- **Cell**: a, b, c, the angles, the volume and the density, then the largest
  Green–Lagrange strain. That strain is rotation-free, so a cell that was only
  re-oriented reads zero.
- **Space group** at four tolerances, 1e-5 being the one VASP itself uses for
  `ISYM`.
- **Nearest neighbour**: the shortest distance in the cell, and the mean over
  sites.
- **Displacements**: max, mean and RMS, overall and per species, and the three
  largest by atom index. They are measured as fractional differences with
  periodic images resolved, so the cell's own change is not counted as atoms
  moving.

After a chunked relaxation the "before" column is the geometry chunk 1 started
from (`chunk-001`), not the POSCAR the chain has been overwriting.

For a static run there is nothing to diff, so it tabulates the geometry that
was computed: cell, density, space group at each tolerance and the nearest
neighbour. The same report is available on its own:

```bash
wolfpack_structure.py POSCAR CONTCAR                  # before -> after
wolfpack_structure.py POSCAR CONTCAR --labels=A,B     # name the two columns
wolfpack_structure.py POSCAR                          # one structure
```

---

## 3. Cleanup

### `vasp-clean` (preferred)

Smart cleanup with dry-run support, recursive mode, per-file size reporting,
and confirmation prompt before deleting.

```bash
vasp-clean                    # show what would be removed, then prompt
vasp-clean -n .               # dry-run: show without deleting
vasp-clean -r ./relax_runs    # recurse into all VASP sub-folders
vasp-clean -a -f calc1 calc2  # aggressive mode, no prompt
vasp-clean --help
```

**Removed by default:** WAVECAR CHG TMPCAR PCDAT WAVEDER STOPCAR REPORT HILLSPOT  
**Added with `-a`:** CHGCAR LOCPOT ELFCAR PROCAR DOSCAR EIGENVAL XDATCAR  
**Always kept:** INCAR POSCAR CONTCAR KPOINTS POTCAR OUTCAR OSZICAR vasprun.xml

### `vasp-nuke`

Fast, no-questions-asked delete — every VASP output file in one `rm` call.
Use `vasp-clean -n` first if you want to see what will be deleted.

```bash
vasp-nuke               # nuke current directory
vasp-nuke path/to/calc  # nuke a specific directory
```

---

## 4. Linear-response Hubbard U workflow

Four scripts that together implement the Cococcioni & de Gironcoli (PRB 2005)
linear-response U calculation. Run them **in order**:

```
Step 1: run-nscf-steps   →   Step 2: run-scf-steps
                                        ↓
Step 4: vasp-calculate-u      ←   Step 3: collect-u-data
```

### Setup (once per system)

```
working_dir/
    01_Groundstate/         converged DFT ground state (CHGCAR, WAVECAR,
                            POSCAR, POTCAR, KPOINTS). The perturbed atom
                            must be its own species in POSCAR/POTCAR.
    INCAR.nscf.template     base INCAR for NSCF runs (must have ICHARG=11;
                            must NOT set LDAUL/LDAUU/LDAUJ)
    INCAR.scf.template      base INCAR for SCF runs (no ICHARG=11 line)
    model_job.sh            SLURM template with #SBATCH -J/-o/-e lines
```

### Step 1 — `run-nscf-steps`

Submits one NSCF job per α value. Already-complete runs are skipped.

```bash
run-nscf-steps --ldaul "2 -1 -1" \
               --ldauu-template "{alpha} 0 0" \
               --ldauj-template "{alpha} 0 0"
# monitor: squeue -u $USER
```

### Step 2 — `run-scf-steps`

Same syntax as Step 1. Run after **all** NSCF jobs have finished. Use
`--lenient` if jobs were OOM-killed after reaching EDIFF.

```bash
run-scf-steps --ldaul "2 -1 -1" \
              --ldauu-template "{alpha} 0 0" \
              --ldauj-template "{alpha} 0 0"
```

### Step 3 — `collect-u-data`

Reads d- or f-electron occupations from all OUTCARs and writes `U_data.dat`.
Requires `LORBIT=11` in every INCAR.

```bash
collect-u-data                   # defaults: site=1, orbital=d
collect-u-data --site 2          # perturbed atom is POSCAR index 2
collect-u-data --orbital f       # use f-electron column
collect-u-data --lenient         # accept OOM-killed but converged runs
```

### Step 4 — `vasp-calculate-u`

Reads `U_data.dat`, fits χ₀ = d(dN_NSCF)/dα and χ = d(dN_SCF)/dα, and prints:

```
U = 1/χ - 1/χ₀
```

```bash
python vasp-calculate-u        # or: python vasp_calculate_u.py
```

---

## 5. Fat-band + projected DOS plot

### `vasp-plot-fatbandsdos`

Produces publication-quality fat-band + DOS figures. A **very thin, very pale
grey backbone** traces every band in the background of *every* method; coloured
markers (opacity = weight) sit on top, and the DOS shares the energy axis. See
[PlotReadme.md](PlotReadme.md) for the full reference. The implementation lives
in the `wolfpack_plot/` package; `vasp_plot_fatbandsdos.py` is the stable master
entry point (the command and `from vasp_plot_fatbandsdos import generate` both
keep working).

**`--method` is REQUIRED.**

```bash
# discover species, atom tokens, and available orbitals first:
vasp-plot-fatbandsdos --root . --list

# then plot (choose a method):
vasp-plot-fatbandsdos --root . --method rgb \
    --projections "(Cu-d),(V-d),(S-p)" \
    --title "MoS_2 - G_0W_0"
```

| Method | Groups | Description |
|--------|--------|-------------|
| `plain` | 0 | no projection: pale backbone + a small **solid black circle at every k-point** |
| `one_orbital` | exactly 1 | **pure-blue** circles; opacity = w_group / w_total |
| `duo` | exactly 2 | two-colour gradient; opacity = total weight |
| `rgb` | 1–3 | additive colour: R/G/B channels; opacity = total weight |
| `cmyk` | exactly 4 | subtractive **CMYK** mix (C/M/Y/K); opacity = total weight |
| `stacked` | any | sumo-style circles; area ∝ weight² |

For **ISPIN=2**, `--spin up`/`down` draws that channel with the standard circles
(no cyan/magenta edges any more), and `--spin both` writes the spin-up plot, the
spin-down plot, **and** a dedicated overlaid plain plot (spin-up blue / spin-down
orange over dashed per-spin backbones). See [PlotReadme.md](PlotReadme.md) §6.

**Auto-pick projections over an energy window** — instead of `--projections`,
let the tool rank the `(element, dominant-l)` characters by their projected-DOS
contribution inside `[--emin, --emax]` and take the top *N* (falling back to
inequivalent Wyckoff sites `Pt1-d, Pt2-d, …` when there are too few elements):

```bash
vasp-plot-fatbandsdos --root . --method one_orbital --auto-projections 1 \
    --emin -3 --emax 3 --name homo_character
```

`--name` sets the output base filename under `Plots/`.

### `vasp-quick-plots`

One figure per method in a single command, with projections auto-picked over the
energy window (`one_orbital`→1, `duo`→2, `rgb`→3, `cmyk`→4, `stacked`→5 units),
each written into its own numbered sub-folder of `Plots/`. Needs the conda env
active.

```bash
conda activate wolfpack-dft
vasp-quick-plots --emin -6 --emax 6 --title "MoS_2"
# writes Plots/{0_Plain,1_ONE,2_DUO,3_RGB,4_CMYK,5_Stacked}/

vasp-quick-plots --methods plain,rgb,cmyk          # a subset
vasp-quick-plots --stacked-n 6                      # 6 units in the stacked plot
```

With `--spin both`, every folder gets `_up` and `_down` plots and `0_Plain` also
gets the blue/orange overlaid plain plot; `--spin up`/`down` gives one per folder.

The contribution ranking is computed by integrating the projected DOS over the
window (a proper states integral, summed over spin), so it is a faithful,
reproducible measure of which orbitals dominate the chosen energy range.

---

## 6. Structure builders

### `build-supercell`

Reads a VASP POSCAR, applies an integer scaling (diagonal `na nb nc` or full
3×3 matrix), and writes the supercell to a new POSCAR. Preserves selective
dynamics and velocities. No defects or dopants.

```bash
build-supercell POSCAR                        # default 2×2×2
build-supercell POSCAR -s 3 3 1               # 3×3×1 slab
build-supercell POSCAR -s 2 2 2 --sort        # also sort by electronegativity
build-supercell POSCAR -s -1 1 1  1 -1 1  1 1 -1 -o POSCAR_conv
                                              # primitive FCC → conventional
build-supercell --help
```

### `build-magnetic-configs`

Finding a magnetic ground state means computing several spin orderings and
comparing them. Doing that by hand is error-prone in a way that does not
announce itself: `MAGMOM` has to line up site-for-site with the POSCAR, and a
slip gives a calculation that converges to something else without complaining.

This enumerates the inequivalent collinear orderings of `./POSCAR` and writes
one folder per ordering, grouped by type, each with a POSCAR, an INCAR derived
from `./INCAR` with `ISPIN` and `MAGMOM` set, a rescaled KPOINTS and — when its
species order still matches — the POTCAR.

**pymatgen does the physics; this command is the plumbing.** The enumeration is
`MagneticStructureEnumerator`, the site matching is `StructureMatcher`, the space
groups are `get_space_group_info`, and the `.cif` is whatever `CifWriter`
produces. Nothing is worked around.

**Which atoms are magnetic, and how large their moments start.** By default the
magnitudes come from your `./INCAR`'s `MAGMOM` if it has one, and otherwise from
pymatgen's default-moment table. `--magmom` overrides both, in either notation:

```bash
build-magnetic-configs --magmom "Ni:1.0,V:2.5"     # per species
build-magnetic-configs --magmom "4*3.0 12*0.0"     # the INCAR's own shorthand,
                                                   # one entry per ion, POSCAR order
```

Naming an element there is also a statement that it **is** magnetic, so a cell
whose elements are all non-magnetic in pymatgen's table — which is refused
without it — enumerates with it.

Only the **magnitudes** are read. The signs are not, and could not be: which
sites come out up and which down is the whole content of the enumeration, and a
sign given here would be overwritten by every ordering pymatgen generates.

Giving two symmetrically **inequivalent** atoms of one species different
starting moments is not something the enumerator accepts — it strips per-site
moments and rebuilds them from a `{species: magnitude}` dict. What it does have
is a strategy that splits sites by Wyckoff symbol and gives them different
moments in the output:

```bash
build-magnetic-configs --magmom "Ti:1.0" \
    --strategies ferromagnetic,antiferromagnetic,ferrimagnetic_by_motif
```

**Your POSCAR is used as written.** The enumerator does not return the cell it
was given — it can reduce the basis, reorder the sites and return different
coordinates — so each ordering is matched back onto your input and the folder
carries your own coordinates. If an ordering needs a supercell, it is built from
your input. `SpacegroupAnalyzer` is never called on the way to a folder unless
you ask for it:

```bash
build-magnetic-configs --symmetrize --symprec 0.1
```

which replaces the input with `get_refined_structure()` before enumerating, and
says so in the index.

When pymatgen returns a cell smaller than your input, or a structure
`StructureMatcher` cannot match, that structure is written as it comes and the
index says so.

**Symmetry is reported, not used.** `SUMMARY.txt` has a space group column and
each folder a three-line `SYMMETRY.txt`, both holding exactly what
`get_space_group_info` returned for that folder's POSCAR — or that it returned
nothing.

Each folder also carries a `.cif` with the moments (P 1, because pymatgen
disables symmetry detection when asked for magmoms) and, when pymatgen finds a
space group, a second symmetrised `.cif` without moments. The `.vesta` draws an
arrow on each magnetic atom, red up and blue down.

Needs the enumlib binaries (`enum.x`, `makestr.x`), which `install.sh` pulls
into the conda environment.

```bash
build-magnetic-configs --dry-run              # look before writing
build-magnetic-configs                        # write the folders
build-magnetic-configs --magnetic-species V   # only V is magnetic, ignore Cu
build-magnetic-configs POSCAR_relaxed         # start from another file
build-magnetic-configs --help
```

---

## 7. Utilities

### `wolfpack`

The toolkit entry point. Prints the guides from any directory, using `glow` for
rendered Markdown if available and falling back to `cat`.
*(Replaces the former `my-shortcuts` command; `install.sh` removes the old
symlink automatically.)*

```bash
wolfpack               # this README (same as --help)
wolfpack --help        # this README
wolfpack --plots       # the plotting guide (PlotReadme.md)
wolfpack --list        # one-line list of every installed command
wolfpack --where       # print the toolkit directory
wolfpack --help | less # paginate
```

---

## 8. The test suite

`tests/` holds 33 tests, and they ship with the toolkit so you can see what is
actually checked rather than take a claim on trust.

```bash
tests/run_all.sh                    # everything, in order
tests/run_all.sh test_13_plots      # one test
tests/run_all.sh --list             # what there is
```

Each `tests/test_NN_*/README.md` states the test, why it exists, the expected
result **with the published source it is contrasted against**, the result
obtained, the pass/fail criterion and the verdict. `tests/test_NN_*/logs/run.log`
is the evidence of the last run.

Where a test asserts a physical number, that number is traced to a source: the
VASP wiki and its tutorials, or a paper. A few of them:

| test | quantity | measured | published |
|---|---|---|---|
| `test_20_u_workflow` | linear-response U, the whole four-step flow | 6.333 eV | 6.33 eV ([VASP wiki](https://vasp.at/wiki/Calculate_U_for_LSDA%2BU)) |
| `test_18_vasp_check` | Si indirect gap | 0.5975 eV | ≈0.6 eV PBE/PAW |
| `test_18_vasp_check` | Al | 0.000 eV | metal, no gap |
| `test_01_cases` | bcc Fe moment | 2.241 μB | 2.2 μB PBE, 2.22 exp. |
| `test_17_vasp_tutorial_magnetism` | hcp Co moment | 1.576 μB/Co | [VASP magnetism tutorial](https://www.vasp.at/tutorials/latest/magnetism/part1/) |
| `test_16_chain_live` | chunked vs one long relaxation | \|dE\| = 1e-06 eV | identical, by construction |

The live tests need a SLURM to submit to. `tests/slurm_testbed.sh` builds one
in `/tmp/wpslurm`; without it those tests skip rather than fail. **No POTCAR is
included** — they are licensed and may not be redistributed. The tests read
yours from `$WP_POTCAR_DIR`, and skip cleanly when a potential is absent.

The whole suite runs in about 20 minutes on an 8-core laptop.

---

## Typical end-to-end flows

### New calculation (the parallelization pipeline)
```bash
vasp-configure                            # once: set up your cluster profile
# from a folder with INCAR KPOINTS POSCAR POTCAR — no arguments, nothing to edit:
vasp-dry-run                              # STAGE 1  (wait for it to finish)
vasp-recommend-slurm                      # STAGE 2  → slurm.sh + KPAR/NCORE/NPAR into INCAR
vasp-test                                 # STAGE 3  → definitive slurm_vasptest.sh (measured)
# KPAR/NCORE/NPAR are already in your INCAR (backup INCAR.bak); then:
sbatch slurm_vasptest.sh                  # the definitive production job, with measured memory
vasp-check                                # → sanity-check the result
vasp-clean -f .                           # → clean up
```

### Linear-response Hubbard U
```bash
# 1. Prepare 01_Groundstate/, INCAR templates, model_job.sh
run-nscf-steps --ldaul "2 -1" --ldauu-template "{alpha} 0" --ldauj-template "{alpha} 0"
# (wait for NSCF jobs)
run-scf-steps  --ldaul "2 -1" --ldauu-template "{alpha} 0" --ldauj-template "{alpha} 0"
# (wait for SCF jobs)
collect-u-data --site 1 --orbital d
python vasp-calculate-u                        # prints U
```

### Fat-band + DOS figure
```bash
# Folder layout: root/Scf/ root/Bands/ root/Dos/ (all with vasprun.xml)
vasp-plot-fatbandsdos --root . --list
vasp-plot-fatbandsdos --root . --method rgb \
    --projections "(Cu-d),(V-d),(S-p)" --title "MoS_2"
# output: Plots/fatbands_dos.png and .pdf
```
