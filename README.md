# Zoreman

A [foreman](https://ddollar.github.io/foreman/) clone in Zig. Inspired by
[goreman](https://github.com/mattn/goreman).

Zoreman manages Procfile-based applications on POSIX systems (macOS and Linux).

> Zoreman is **POSIX/macOS/Linux only**. Windows is not supported and is not
> a goal of this project.

## Installation

### Requirements

- Zig 0.16 or later

### From source

```sh
git clone https://github.com/aaronjheng/zoreman
cd zoreman
zig build -Doptimize=ReleaseSafe
```

The resulting binary lives at `zig-out/bin/zoreman`.

## Quick start

Create a `Procfile`:

```procfile
web: python3 -m http.server 9000
worker: ruby worker.rb
```

Run it:

```sh
zoreman start
```

Output:

```text
00:00:00     web | Starting web on port 5000
00:00:00  worker | Starting worker on port 5100
00:00:00     web | Serving HTTP on 0.0.0.0 port 9000 ...
```

Each child gets its own `PORT` environment variable (5000, 5100, 5200, ...).

## Commands

```text
zoreman check                       Validate the Procfile and exit
zoreman start [PROCESS...]          Start one or more processes (all if omitted)
zoreman run COMMAND [PROCESS...]    Talk to a running supervisor over RPC
zoreman export FORMAT LOCATION      Export the Procfile to another process manager
zoreman version                     Print the zoreman version
zoreman help [TASK]                 Show help for zoreman or a subcommand
```

`run COMMAND` accepts:

```text
start PROCESS...
stop PROCESS...
stop-all
restart PROCESS...
restart-all
list
status
```

## Files

### Procfile

Each line declares one process: `name: command`. Lines beginning with `#` are
comments. Empty lines and lines without `:` are skipped. Empty names are
skipped; an empty command is an error (zoreman is stricter than goreman here
to avoid spawning empty shells). Duplicate process names are an error.

```procfile
# Comments are ok
web: bundle exec rails server -p $PORT
worker: bundle exec rake jobs:work
```

### `.env`

Loaded from `<basedir>/.env` (default current directory) and merged into each
child's environment. Values from `.env` override the inherited environment.
A missing `.env` file is not an error; a malformed file is.

```env
DATABASE_URL=postgres://localhost/myapp
RAILS_ENV=development
```

### `.goreman`

Optional YAML-ish configuration file in the current directory. Only top-level
scalar fields are read; everything else is ignored. CLI flags override
`.goreman` values. Supported fields:

```yaml
procfile: Procfile
port: 8555
basedir: .
baseport: 5000
exit_on_error: false
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-f`, `--procfile PATH` | `Procfile` | Path to the Procfile |
| `-e`, `--env PATH` | `.env` | Path to the env file |
| `-p`, `--port PORT` | `8555` | Port the RPC server listens on |
| `-b`, `--baseport PORT` | `5000` | Base port for the auto-injected `PORT` env var |
| `--basedir DIR` | _none_ | Change to this directory before reading anything |
| `--set-ports BOOL` | `true` | Inject `PORT` into each child's env |
| `--exit-on-error BOOL` | `false` | Exit if any child exits with a non-zero status |
| `--exit-on-stop BOOL` | `true` | Exit when all children have stopped |
| `--logtime BOOL` | `true` | Prefix log lines with `HH:MM:SS` |
| `--rpc-server BOOL` | `true` | Start the RPC server when running `start` |

Boolean flags accept `true`/`false`, `yes`/`no`, `1`/`0`, `t`/`f`, `y`/`n`
(case-insensitive). Use `--flag=value`.

The RPC server listen address defaults to `0.0.0.0` and may be overridden via
`GOREMAN_RPC_ADDR`. The RPC port defaults to `--port` and may be overridden via
`GOREMAN_RPC_PORT`. The RPC client target defaults to `127.0.0.1:<port>` and may
be overridden via `GOREMAN_RPC_SERVER`.

## RPC examples

In one terminal:

```sh
zoreman start
```

In another:

```sh
zoreman run list           # web\nworker\n
zoreman run status         # *web\n*worker\n
zoreman run stop web       # gracefully stops web
zoreman run start web      # starts it again
zoreman run restart-all    # restarts every process
```

The wire protocol is one-line JSON over TCP. It is **not** compatible with
Go's `net/rpc`; it is implementation-private.

## Export

```sh
zoreman export upstart /etc/init
```

Generates one `app-<name>.conf` per Procfile entry containing
`start on starting`, `stop on stopping`, `respawn`, `env PORT=...`, an absolute
`chdir`, and `exec <command>`. `<basedir>/.env` (next to the Procfile) is
inlined as `env KEY='value'` lines.
## License

Zoreman is licensed under the [BSD-3-Clause License](https://opensource.org/licenses/BSD-3-Clause).
See [LICENSE](LICENSE) for more details.
