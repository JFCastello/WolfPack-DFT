# test_02_dispatcher

> wolfpack: every command resolves, and an unknown one is refused

## 1. Definition

Walks the command map the installer advertises, checks each name resolves to a
file that exists, runs every command's `--help` from an empty directory, and
checks that an unknown subcommand is refused.

## 2. Purpose

This is the front door. A command that does not resolve is invisible until a
user types it, and then it fails in the least helpful way there is — a shell
error about a path they never wrote.

`--help` is checked **from an empty directory** on purpose: that is where a
confused user types it. A `--help` that needs a calculation present to work is
a `--help` that fails exactly when it is needed.

## 3. How it is executed

```
tests/run_all.sh test_02_dispatcher
```

Reads `COMMAND_MAP` out of `install.sh`, then runs each script with `--help`
under `timeout`, in an empty scratch directory. No VASP, no SLURM; seconds.

## 4. Expected results

- all advertised commands resolve to an existing file;
- every `--help` exits without a traceback, without hanging, and prints
  something;
- `wolfpack nonsense-subcommand` exits non-zero.

## 5. Obtained results

```
all 21 advertised commands resolve to a file that exists
17 x --help works from an empty directory
wolfpack rejects an unknown subcommand
```

**Two package bugs were found here and fixed:**

- **`vasp-nuke --help` printed bash's `cd` documentation.** The argument fell
  through to `cd "$1"`; the `cd` builtin recognises `--help`, printed its own
  manual and returned 2, so the `|| exit 1` stopped the script. It deleted
  nothing — verified in a sandbox before reporting it — but the safest thing a
  user can type before a destructive command was answered with the manual for a
  different command. It has its own `--help` now, and rejects unknown options.
- **`vasp-calculate-u --help` crashed** with a numpy `FileNotFoundError` about
  `U_data.dat`: it read the data file before parsing arguments. Arguments are
  parsed first now.

## 6. Pass / fail criterion

Exact, no tolerance: any unresolved command, any `--help` that exits non-zero,
traceback, hangs or prints nothing, or an unknown subcommand accepted, fails
the test.

## 7. Verdict

**PASSED** — 19 assertions, 0 failed. See `logs/run.log`.

## Sources

None needed: nothing here is physics. The claims are about this package's own
command map, verified against `install.sh` itself.

