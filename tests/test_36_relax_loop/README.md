# test_36_relax_loop

> vasp-relax-loop: a fixed NSW per chunk, each chunk's walltime from the last one, clean retries

## 1. Definition

Runs `vasp-relax-loop` end to end against the fake scheduler and the fake VASP of
`tests/chain_harness.sh`: launch, chunk after chunk until VASP reports "reached
required accuracy", and every way a chunk can fail. It checks what the chain
submits, from which geometry, with which walltime and memory, and what it writes
in `relax_progress.txt`.

## 2. Purpose

The design, decided on 2026-09-25: every chunk runs the same NSW, from the
previous chunk's CONTCAR, and asks for the walltime its own steps are estimated to
need. What can go wrong, and what this test pins down:

- **the wrong geometry.** A retry that starts from the failed attempt's CONTCAR
  (partial) or from the folder's POSCAR (the original) silently repeats or skips
  work. Every retry must start from the last completed chunk.
- **the wrong walltime.** Too short means kill after kill. Too long waits in the queue.
- **a chain that cannot advance.** VASP does not move the ions after its last ionic
  step (checked with VASP 6.5.1, IBRION 1, 2 and 3), so NSW = 1 would recompute
  one geometry forever. It must be refused.
- **a criterion VASP cannot apply.** A positive EDIFFG compares energies between two
  steps of one run. It must be refused.

The fake VASP behaves like the real one where the chain depends on it: CONTCAR is
the last geometry computed. Its electronic steps converge a decade a step, so the
right estimate is known by hand.

## 3. How it is executed

```
tests/run_all.sh test_36_relax_loop
```

About a minute. `chain_harness.sh` provides fake `sbatch`, `squeue`, `sacct`,
`scontrol` and a fake VASP behind `srun`; the chain runs as in a job (`--chunk-body`),
one chunk per call. vasp-test's measurements are a fixture: stopped inside the first
ionic step after 8 electronic steps of 2.0 s (5 delay, then 1e-1, 1e-2, 1e-3).

## 4. Expected results

| case | expected |
|---|---|
| EDIFFG > 0; no EDIFFG | refused: "EDIFFG must be negative" |
| NSW = 1 in the INCAR; `--nsw 1`; `--steps 2,1,3` | refused, saying why (VASP does not move the ions after its last step) |
| IBRION = 0; no IBRION (VASP's default is 0 with NSW > 0) | refused |
| vasp-test at 2 ranks for a 4-rank job; no vasp-test OSZICAR | refused: run `vasp-test --full-size` |
| `--carry-wavecar` with LWAVE = .FALSE.; `--margin-min 2`; `--safety 0.9` | refused; nothing submitted by any refusal |
| chunk 1 | 13 electronic steps (8 + 3 + 2) × 2.0 s + 2.0 s = 28 s per step; 10 + 28 + 28 = 66 s → **7 min** |
| chunk 2, from chunk 1 (22.5 + 12.5 s) | **6 min** (35 s × 1.15 + 5), from chunk 1's CONTCAR (x = 0.7520: moved once) |
| three chunks to "reached required accuracy" | converged; **4 distinct geometries** (2 + 1 + 1), 3 jobs; each chunk in its own directory; the folder's POSCAR untouched, its CONTCAR the latest; only the latest chunk keeps a WAVECAR |
| relax_progress.txt | one row per chunk: electronic steps per ionic step, the estimated steps and time, the walltime asked; how the chain ended |
| a walltime warning in chunk 1, ionic step 2 (its CONTCAR at 0.7520) | filed as TIMEOUT, restart files removed; try 2 from the **original POSCAR (0.7500)**, in a new directory, **11 min** (at least 1.5 × 7) |
| a step 10 × slower than measured (20 s), warned after 8 steps | re-estimated from its own steps: 13 × 20 + 20 = 280 s per step; 570 s × 1.15 → **16 min** |
| `--max-retries 1`, two walltime kills | stops (`retries_exhausted`), no third job |
| chunk 2 killed | its retry starts from chunk 1's CONTCAR (0.7520), not its own (0.7540) |
| an OOM kill | try 2 at 1.5 × 2000 = **3000 MB/cpu**, same walltime |
| the job dies with the chain | the chain stays "running"; `--resume` reads the TIME LIMIT kill, files the attempt, submits try 2 from the original POSCAR, 11 min |
| `--max-ionic 3` | stops after 2 + 1 geometries; `--resume --max-ionic 4` continues |
| `--steps 2,4` | chunk 2's INCAR has NSW = 4, the folder's none; stops after the two jobs |
| no NSW in the INCAR | 2, and it says so |
| `--carry-wavecar` / without | chunk 2 starts with chunk 1's WAVECAR / with none |
| `--stop`, then `--resume` | chunk 1 completes, nothing submitted; then chunk 2, sized from chunk 1 (6 min); `--status` shows the progress file |

## 5. Obtained results

All forty-nine as expected. The progress file after a walltime kill and its retry:

```
  chunk try NSW  ionic geoms  e-steps/ionic    est.e   estimate  asked      used     energy (eV)  max|F|  result
      1   1   2      1     0  11 [3]              13    0:01:06   0:07   0:00:28               -       -  TIMEOUT
      1   2   2      2     2  11 6                11    0:01:06   0:11   0:00:35      -10.829997  0.1667  ok
```

`[3]`: an ionic step cut off after 3 electronic steps.

On the first run three assertions failed, all of them my own mistakes: a hand
computation and two greps. The code was right each time. See NOTES.

## 6. Pass / fail criterion

Exact: walltimes, memory, the geometry each attempt starts from (atom 2's x), the
directories, the stop reasons, the job counts, the rows of the progress file.

## 7. Verdict

**PASSED** — 49 assertions, 0 failed. See `logs/run.log`.

## Sources

- EDIFFG: positive stops on the energy change between two ionic steps; negative on
  the forces — <https://vasp.at/wiki/index.php/EDIFFG>
- IBRION: default 0 (molecular dynamics) when NSW > 0 — <https://vasp.at/wiki/index.php/IBRION>
- CONTCAR: "the positions of the last ionic step" — <https://vasp.at/wiki/index.php/CONTCAR>;
  that the ions are not moved after it was measured here with VASP 6.5.1
  (NSW = 1: CONTCAR = POSCAR for IBRION 1, 2, 3; NSW = 2: CONTCAR = the second
  geometry of XDATCAR)
- ISTART: a WAVECAR present is read by default — <https://vasp.at/wiki/index.php/ISTART>
- `sbatch --signal`: a warning signal before the time limit —
  <https://slurm.schedmd.com/sbatch.html#OPT_signal>
