# test_06_clean_nuke

> vasp-clean / vasp-nuke: never eat an input, refuse while a chain is live

## 1. Definition

Builds calculation folders in known states — fresh, finished, mid-chain, stale,
and not-a-calculation-at-all — runs the two deleting commands in each, and
inventories what survived.

## 2. Purpose

These two commands delete files. The only question that matters is what they
will **not** delete, and whether a plausible mistake can make them.

The plausible mistakes, all covered:

- running either one in the wrong directory;
- running `vasp-nuke` while a chunked chain is between chunks, where `WAVECAR`
  and `CONTCAR` are the restart objects and their loss strands the run **without
  the chain being able to tell**;
- the mirror image: a `chain.env` still saying `running` after the job died,
  locking the folder forever.

## 3. How it is executed

```
tests/run_all.sh test_06_clean_nuke
```

Scratch directories with fabricated VASP outputs, a `notes.txt` and a
`run_me.sh` planted as the user's own files. Seconds; nothing is submitted.

## 4. Expected results

| situation | `vasp-clean` | `vasp-nuke` |
|---|---|---|
| finished calculation | inputs + user files survive | inputs + user files survive, outputs gone |
| chain `running`, job alive | — | **refuses**, says why, restart objects intact |
| chain `running`, job dead | — | proceeds (stale state must not lock the folder) |

A job that has just been cancelled sits in `COMPLETING` while its epilog runs,
and `squeue` still lists it; on this testbed that can last minutes. A job SLURM
still lists may still touch its files, so `vasp-nuke` is right to refuse it.
The stale case therefore uses an id the scheduler genuinely does not know.
| not a calculation | touches nothing | touches nothing |
| directory does not exist | — | refuses |

## 5. Obtained results

All eleven as expected.

No package bug was found here. Two of this test's own checks were wrong when
first written, and both passed while testing nothing.


## 6. Pass / fail criterion

Exact, by inventory: `INCAR`, `POSCAR`, `KPOINTS`, `POTCAR`, `notes.txt` and
`run_me.sh` must be present byte-for-byte after each command; the nuke must
actually remove the outputs it exists to remove; and the live-chain refusal must
leave `WAVECAR` and `CONTCAR` in place.

## 7. Verdict

**PASSED** — 11 assertions, 0 failed. See `logs/run.log`.

## Sources

None needed: every claim is about this package's own deletion policy. The
restart objects a chunked run needs (`WAVECAR`, `CONTCAR`) are named by VASP's
own restart documentation — <https://www.vasp.at/wiki/index.php/ISTART>.
