# `wc` — user manual

## Synopsis

```
wc [OPTION]... [FILE]...
wc [OPTION]... --files0-from=F
```

## Description

`wc` reads each `FILE` and writes a newline, word, byte, and (optionally)
character count for each input. Inputs are processed independently; the
counts printed for a single file are the totals over that file, and a
`total` line is added after the last file unless suppressed.

If no `FILE` is given, or if `FILE` is `-`, standard input is read.

By default, `wc` prints three columns — lines, words, bytes — matching the
output of GNU `wc`. Any of the `-l`, `-w`, `-c` / `-m` flags restrict the
output to that subset, and any flag on the command line suppresses the
default set.

The program is implemented in SBCL Common Lisp and uses `pread(2)` on
seekable files so that multiple worker threads can count different
byte ranges of the same file in parallel. When `--number-threads` is 1, or
the input is a non-seekable stream (stdin, pipe, socket), a single-threaded
linear read loop is used. When `--number-threads > 1`, multi-threaded execution
is always used.

## Options

Options that take a value accept both `--opt=VALUE` and `--opt VALUE`.

### Counting

`-c`, `--bytes`
  Print the byte count.

`-m`, `--chars`
  Print the character count (UTF-8, lenient by default).

`-l`, `--lines`
  Print the newline count.

`-w`, `--words`
  Print the word count.

Short options may be clustered: `-lwc` is equivalent to `-l -w -c`.
The default when no counting flag is given is `-l -w -c`.

### Character-mode selection

`--utf8-strict`
  Enable strict UTF-8 character validation. Implies `-m`. Rejects `0xED`-lead
  sequences followed by `0xA0`–`0xBF` (surrogate-half encodings) and does not
  accept bytes `< 0xC2` or `> 0xF4` as lead bytes.

Without `--utf8-strict`, `-m` uses a lenient heuristic: any byte for which
`(byte & 0xC0) != 0x80` is counted as a character start. That is fast and
sufficient for well-formed UTF-8; it does *not* reject invalid lead bytes
or surrogate-half sequences.

### Kernel selection

`--implementation=NAME`
  Select the kernel backend: `generic`, `avx2`, or `avx512`. Default is the
  fastest backend the binary was built with.

`--debug`
  Print `wc: using <impl> implementation` to stderr before processing.

Requesting a backend the binary was not built with falls back gracefully
with a warning on stderr:

- `--implementation avx512` on a build without AVX-512 → warns and uses
  AVX2 if available, otherwise generic.
- `--implementation avx2` on a build without AVX2 → warns and uses
  generic.

### Threading and buffer tuning

`--number-threads=N`
  Use `N` worker threads for seekable files. Default is `min(8, ncpus)`.
  When `N > 1`, `wc` always uses the multi-threaded worker pool regardless
  of file size.

`--chunk-size=BYTES`
  Buffer size per worker, and the unit of block partitioning under
  `--number-threads`. Between 1024 (1 KiB) and 1073741824 (1 GiB).
  Default is 1048576 (1 MiB).

The chunk size and thread count interact through cache behaviour. On Zen 5
machines, `--chunk-size 1048576 --number-threads 8..10` is optimal.
Users can experiment with any thread count and chunk size on their hardware.

### Total-line control

`--total=WHEN`
  Control when the total line is printed: `auto` (default), `always`,
  `never`, or `only`.
  - `auto`   — print the `total` line iff more than one input was processed.
  - `always` — always print it.
  - `never`  — never print it.
  - `only`   — print *only* the total; suppress per-file lines.

### File-list input

`--files0-from=F`
  Read input filenames from `F`, NUL-separated. `-` means standard input.
  If the file list ends up empty, exit 0 without reading stdin.

### Informational

`--help`
  Print usage and exit with status 0.

`--version`
  Print program version and exit with status 0.

### Argument termination

`--`
  Terminates option parsing. Every following token is treated as a
  filename, including tokens starting with `-`.

## Exit status

- **0** — All inputs were processed without error.
- **1** — At least one input could not be opened or read; the per-file error was printed to stderr, and the remaining inputs were still processed.
- **130** — Interrupted via `with-user-abort` (Ctrl-C).

## Environment

`WC_NO_SIMD`
  If set **at build time**, suppresses `:avx2` and `:avx512` features in `wordcount.asd`, forcing a generic-only binary. Ignored at runtime.

## Examples

### Default: lines, words, bytes

```sh
$ ./wc tests/plato1g.txt
 23220400 195711880 1073979760  tests/plato1g.txt
```

### Lines and words only, AVX-512, 10 threads

```sh
$ ./wc -lw --implementation avx512 --number-threads 10 tests/plato1g.txt
 23220400 195711880  tests/plato1g.txt
```

### UTF-8 strict validation

```sh
$ ./wc -m --utf8-strict -l tests/plato.org
     48143    3835642 tests/plato.org
```

Any character that would be an invalid UTF-8 start byte in strict mode is
*not* counted, but the byte count (if requested) still reflects the raw
file length.

### Multiple files with a total

```sh
$ ./wc -l a.txt b.txt c.txt
     100  a.txt
     200  b.txt
     300  c.txt
     600  total
```

`--total=never` suppresses the total line; `--total=only` prints only it.

### Standard input

```sh
$ some-command | ./wc -l
      42
```

### Filenames from a NUL-separated list

```sh
$ find . -name '*.txt' -print0 | ./wc --files0-from - -c
 1073979760  total
```

### Forcing a specific backend for benchmarking

```sh
$ for impl in generic avx2 avx512; do
>   printf '%-8s ' "$impl"
>   time ./wc --implementation "$impl" --number-threads 1 \
>       tests/plato1g.txt >/dev/null
> done
generic  2.52 s
avx2     0.09 s
avx512   0.06 s
```

## Notes on behaviour

### Byte counting is I/O-free for regular files

If only `-c` is requested (`-l`, `-w`, `-m` are all off), `wc` short-circuits
to `lseek(SEEK_END) - lseek(SEEK_CUR)` for seekable files and does not
read the file at all. The file offset is preserved.

### Threading and performance

`--number-threads` and `--chunk-size` are always honoured for seekable regular
files. When `--number-threads > 1` is requested, `wc` executes via the
multi-threaded worker pool regardless of file size or block count. The
single-threaded linear `read(2)` loop is used only when `--number-threads` is 1
or when reading from non-seekable streams.

Under the default configuration (8 threads, 1 MiB chunk size), empirical saturation
occurs around **8 MiB**, where every worker receives at least one full 1 MiB block.
Single-threaded AVX-512 scans files below 8 MiB in under 1 millisecond (< 800 µs),
making sequential execution very fast on small files. However, users can freely
tune `--number-threads` and `--chunk-size` (e.g. `--chunk-size 64k`) to find the
optimal operating points and break-even thresholds for their specific CPU caches,
core topologies, and storage systems. See `tools/bench-threshold-report.md` for
in-depth benchmarks and analysis.

### Fast process exit (application mode)

When running as a CLI utility, `wc` delegates thread and memory teardown
to the OS kernel upon exit via `_exit(2)` (`sb-ext:exit :abort t`). Worker
threads are not joined, foreign memory is not deallocated individually, and
for single-file inputs, closing the file descriptor is deferred to kernel
exit. This eliminates exit latency and matches standard C/C++ utility design.
Full RAII cleanup is maintained in library mode.

### Non-seekable inputs

Standard input, pipes, and sockets always use the single-threaded linear
path regardless of `--number-threads`, because `pread(2)` requires a
seekable descriptor.

### Word and line counting do not depend on UTF-8

Word boundaries are ASCII whitespace bytes, and newline is `0x0A`. Neither
is ever a UTF-8 continuation byte (which are all ≥ `0x80`), so word and
line counts are identical in ASCII and UTF-8 modes. Only `-m` (character
counting) differs.

### Compatibility with GNU `wc`

The exact per-file error-message wording and the formatting spacing of the
`total` line differ slightly. Numeric columns are formatted to width 8 with
a separating space.

When both `-c` and `-m` are given, current `wc` prints *both* byte and
character columns. Some older GNU `wc` versions printed only one.

`--files0-from` with an empty file list exits 0 without reading stdin,
matching current GNU `wc`.

Command-line compatibility with GNU `wc` is a goal but not a hard
guarantee; the option set above is the authoritative list.

-L option (line width in printed columns) is not implemented
