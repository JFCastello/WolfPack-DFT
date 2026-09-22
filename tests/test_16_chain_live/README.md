# test_16_chain_live

> chunked relax and SCF vs one long run: same structure, same energy

## 1. Definition

Runs the same relaxation twice — once straight through, once cut into two jobs
with a restart at the boundary — and compares the final energy and structure.
Then does the same for a static SCF, which chunks `NELM` instead of `NSW`.

## 2. Purpose

`vasp-relax-loop` and `vasp-scf-loop` exist to cut a long calculation into
short jobs that backfill into a queue. Their entire value rests on one claim:

> splitting the calculation changes the answer by nothing.

That cannot be verified by reading code. A chain that dropped `ISTART`/`ICHARG`,
or wrote `LWAVE = .FALSE.` into a chunk, would restart from scratch at every
boundary — the energies would still look plausible and the relaxation would
still converge, to a slightly different geometry after more steps.

## 3. How it is executed

```
tests/run_all.sh test_16_chain_live
```

Silicon, 2 atoms, with one atom displaced by (0.02, 0.01, 0) fractional so
there is somewhere to relax **to** — a structure already at its minimum would
agree trivially. Four VASP runs on 4 ranks; a few minutes.

- **direct**: `NSW = 12`, straight through.
- **chunked**: `NSW = 6`, then restart from that `CONTCAR` + `WAVECAR` with
  `ISTART = 1`, `ICHARG = 1`, and finish. The boundary is done by hand so the
  comparison isolates the **restart** from the scheduler.

## 4. Expected results

Identical answers, to numerical precision. There is no physical reason for a
difference: the restart reads the same wavefunction and density the direct run
had in memory.

## 5. Obtained results

```
the reference relaxation finished (E = -10.820773 eV)
the relaxation really was split (6 then 1 ionic steps)
chunked and direct relaxation agree in energy     |dE| = 1.00e-06 eV
chunked and direct relaxation agree in structure  max |dr| = 1.74e-11 A
chunked and direct SCF agree in energy            |dE| = 0.00e+00 eV
```

`1.7e-11 Å` is machine precision. The static SCF agrees to the last printed
digit.

## 6. Pass / fail criterion

| quantity | tolerance | why that tolerance |
|---|---|---|
| relaxation energy | 1e-3 eV | below any energy difference a conclusion is drawn from |
| relaxation structure | 5e-3 Å | an order of magnitude below a typical `EDIFFG = -0.01` |
| SCF energy | 1e-4 eV | a static run restarts from a converged WAVECAR; it has no excuse |

Loose enough that a differently-converged run passes, tight enough that a
restart which silently lost the wavefunction does not.

## 7. Verdict

**PASSED** — 5 assertions, 0 failed. See `logs/run.log`.

## Sources

- `ISTART` — <https://www.vasp.at/wiki/index.php/ISTART>
- `ICHARG` — <https://www.vasp.at/wiki/index.php/ICHARG>
- `EDIFFG` — <https://www.vasp.at/wiki/index.php/EDIFFG>
