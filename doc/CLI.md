# The `poa` command

```
poa a [options] FILE...     compress:  song.ogg -> song.ogg.poa, talk.opus -> talk.opus.poa
poa x [options] FILE...     extract:   song.ogg.poa -> song.ogg
poa list FILE...            what each .poa holds: original size, stored size, hash
poa t FILE...               test each .poa: extract and verify in memory, write nothing
poa info FILE...            the structure of each file, and what POA does with it
poa report [FILE]           a bug report (no audio, no comment text) and a link to open an issue
poa bench FILE...           how fast this machine runs a, a --no-verify and x on them
poa selftest                the samples inside the binary
poa --version, poa -V       the build and the system
```

The command follows the pack-algorithm family's (PJA's `doc/CLI.md` is the
model); this page says what POA does and where it differs.

**Names.** A `.poa` does not store the original's extension: `a` appends
`.poa` to the whole name (`song.ogg` -> `song.ogg.poa`) and `x` removes it
(`song.ogg.poa` -> `song.ogg`). A name that does not end in `.poa` gets
`.out` when extracted.

| switch | what it does |
|---|---|
| `-o PATH` | output name with one input; a directory if it exists or ends in `/` |
| `--output-dir=DIR` | output directory |
| `-f`, `--force` | replace an existing output, only with something that verified |
| `-th N`, `--threads=N` | files worked on at once, the largest first; by default the processors, up to 8. A file is coded on one thread. Each file's lines come out in the order of the inputs |
| `--max-output=SIZE` | `x`, `t`: refuse a declared original above SIZE (`256M` by default, `K`/`M`/`G`, `0` = no limit), before decoding |
| `--keep-corrupt` | `x`: an output that does not verify stays as `NAME.corrupt` |
| `--no-verify` | `a`: do not decompress the stream to check it before writing (about twice as fast; a codec bug would then only show when extracting, where the hash catches it). The `.poa` is the same byte for byte |
| `--no-sync` | do not wait for each output to reach the disk before it takes its name; after a power cut an output may be empty or missing |
| `--clean-temps` | `a`, `x`: delete the temporaries an interrupted run left in the directories this run writes to: only POA's (`.poa-tmp-PID-N`), only regular files, only older than an hour, never one whose process is still running |
| `-n`, `--dry-run` | do everything but write |
| `-q`, `--quiet` | only errors |
| `--stats` | `a`, `x`, `t`: where each file's time went (read, parse, encode, verify, decode, hash, write) |
| `--json` | `a`, `x`, `t`, `info`, `list`: one JSON object a line for each file, in the order of the inputs, then `{"summary": ...}` |
| `--cpu=PATH` | accepted for the family's scripts: POA has one path, `plain`; any other is refused (exit 2) |
| `-o REPORT` | `report`: the file the report goes to (never over an existing one) |
| `--with-file` | `report`: also copy FILE beside the report as `poa-report-NAME`, to attach if you choose to (without FILE: exit 2) |
| `-r N` | `bench`: runs of each measure, the best counts (3 by default) |
| `--` | everything after it is a file |

All warnings and errors go to stderr.

| exit status | when |
|---|---|
| 0 | every file went through (`t`: every `.poa` verified; `selftest`: every check passed) |
| 1 | a file failed: it is not an Ogg file (no Ogg page in it) or not a `.poa`, it is damaged, it could not be read or written; `selftest`: a check failed |
| 2 | usage error: an unknown command or option, a value out of range, an option for another command, `--cpu` with a path not here |
| 3 | a bug in POA: an exception that is not about the file or the system. The run ends with `This is a bug in POA. Please run: poa report FILE and open an issue at https://github.com/YadeWira/POA/issues` |
| 130, 143, 129, 141 | ended by SIGINT, SIGTERM, SIGHUP or SIGPIPE, after deleting the temporaries it was writing |

## Checking and reporting

- **`poa t`**: what `x` does, without writing: the header, the declared
  size against `--max-output`, decoding, then the size and the BLAKE3-128.
  `NAME: OK` for each one that verifies, `poa: NAME: ...` on stderr for
  each that does not (exit 1).
- **`poa info`**: for an Ogg file, its pages (with how many have a CRC that
  does not match), the bytes between pages, and each logical stream: serial,
  codec, pages, packets, bytes; then what `a` does with it. For a `.poa`,
  its header (format, flags, original size, BLAKE3-128) and whether it
  extracts and verifies. Comment headers (tags) are never printed.
- **`poa report`**: POA's version and build, the system, the command line
  (paths cut to their names), and for FILE its size, BLAKE3-128, structure
  and what `a` does with it. No audio and no comment text. Then a link that
  opens a GitHub issue with the report in it. `--with-file` copies the file
  beside the report: it goes nowhere unless you attach it.
- **`poa bench`**: for each file, the best of N runs of `a`, `a --no-verify`
  and `x`, in milliseconds and MB/s of the original, and the write alone.
  Nothing is written beside the inputs.
- **`poa selftest`**: the binary carries three samples (`pas/poaselftest.inc`,
  written by `tools/gen_selftest.py` from `tests/ogg`) and the BLAKE3-128 of
  the `.poa` each one has to give: each is compressed, compared with it and
  extracted back.
- **`poa --version`**: version, commit (from `POA_COMMIT` at build time;
  `build.sh` takes it from git), build date, FPC, target, system, processor,
  `cpu_path: plain`, processors, default threads, `.poa` format.

## Nothing written that did not verify

- `a` writes the `.poa` only after it has decompressed its own stream and
  compared it with the input (unless `--no-verify`).
- `x` validates the header, refuses a declared size above `--max-output`
  before decoding, decodes with that size as the cap, checks the size and
  the BLAKE3-128, and only then writes.
- Writing goes to a temporary in the same directory (`.poa-tmp-PID-N`),
  flushed to the disk (unless `--no-sync`) and renamed to the output only
  once it is complete; on Unix the directory is flushed after. Without `-f`
  the name is taken only if it is still free. A run cut short never leaves a
  partial file under the output's name; a temporary left by `kill -9` or a
  power cut is named by the next run that writes there, and deleted only
  with `--clean-temps`.
