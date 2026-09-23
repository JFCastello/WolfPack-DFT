# test_26_queue_wait

> vasp-queue-wait: the queue statistics, against arithmetic we chose

## 1. Definition

Puts a fake `sacct` on `PATH` returning jobs whose waits are numbers we picked,
and checks the median, mean, p90 and worst case the command computes per
partition.

## 2. Purpose

The command turns SLURM's `Submit` and `Start` times into a picture of what a
queue actually costs you. Every figure is a reduction over a list, and a
reduction is the kind of thing that is wrong by one element and looks entirely
plausible.

The fixture is built around the case that makes the command worth having: a
partition whose median wait is one minute and whose mean is nearly five hours,
because one job in five sat for a day. A tool reporting only the mean would
describe that queue as taking five hours. It does not.

A **fake** `sacct` is used deliberately. Against a real one the expected value
would have to be computed the same way the tool computes it, and the test would
prove only that the code agrees with itself.

## 3. How it is executed

```
tests/run_all.sh test_26_queue_wait
```

Seconds; no VASP, no scheduler.

## 4. Expected results

```
fast   waits of  60 120 180 240 300 s  ->  median 180   mean 180    p90 300
slow   waits of  60  60  60  60 86400  ->  median  60   mean 17328  p90 86400
```

Plus the rows that must **not** become a wait:

| row | expected |
|---|---|
| a pending job (no `Start`) | counted as pending, **not** as a wait of zero |
| a job held by a dependency (`Eligible` after `Submit`) | excluded — it was waiting on its own job graph, not on the queue |

And: the by-size table separates the 1-node jobs from the 32-node one that
carries the long wait; `--days 0`, `--days abc` and unknown options are
refused; without `sacct` the command says so; an empty window is reported as
*no record*, not as a wait of zero.

## 5. Obtained results

All eighteen as expected: `fast` 180 / 180 / 300 s, `slow` 60 / 17328 / 86400 s,
the held job absent from the five counted in `fast`, one pending job counted as
pending, and the 1-node band holding exactly the four fast `slow` jobs.

No package bug was found here. One assertion failed on the first run and it was
mine.

## 6. Pass / fail criterion

| quantity | tolerance | why |
|---|---|---|
| median, p90, worst | ±1 s | they are elements of the list; off-by-one picks a different element, which is minutes away |
| mean | ±5 s | integer division only |
| job counts | ±0.5 | exact, expressed as a number |

## 7. Verdict

**PASSED** — 18 assertions, 0 failed. See `logs/run.log`.

## Sources

- `sacct` field definitions — `Submit`, `Eligible`, `Start`, and `-X` for
  allocations rather than steps: <https://slurm.schedmd.com/sacct.html>
- `squeue` pending reasons, used for the "queued right now" section —
  <https://slurm.schedmd.com/squeue.html>

