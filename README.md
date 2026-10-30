# fxaudit

**Find what breaks, leaks or gets your FiveM server exploited, before your players do.**

fxaudit is a static analyzer for FiveM resources, written in pure Lua 5.4 with no dependencies.
It understands the CfxLua dialect, your `fxmanifest.lua`, the client/server split and all 7,000+ natives.

[Version française](README.fr.md)

```text
$ fxaudit scan examples/vulnerable-resource

server.lua
  9:11 CRITICAL FX400  'item' comes from the client (event 'shop:buy') and reaches addInventoryItem without validation
    | xPlayer.addInventoryItem(item, 1)
    > check its type and bounds, or recompute the value on the server from your config
  26:3 CRITICAL FX404  code received from an HTTP request is executed: whoever controls that server controls yours
    | load(body)()
    > unless you wrote this yourself, treat this resource as compromised
  42:16 HIGH FX216  'string.fromat' does not exist
    | print(string.fromat('%s', 'typo'))
    > did you mean 'string.format'?
client.lua
  6:5 MEDIUM FX201  'position' leaks: it is assigned in a function without 'local' and becomes a global
    | position = GetEntityCoords(ped)

1 resource, 3 Lua files: 5 critical, 13 high, 6 medium, 3 low
Score: 2/100
```

## Why

- **For founders:** check a script you bought or downloaded before it touches your server, and get a score per resource.
- **For developers:** catch undefined variables, leaks and exploitable events in your editor's terminal or in CI.
- **Safe by design:** fxaudit never executes what it scans, not even the manifest or its own config file.

## What it detects

| Category | Examples |
|---|---|
| **Syntax** | every error of a file at once, with the line of the block left open |
| **Variables** | undefined globals across files, global leaks, unused or shadowed locals, use before declaration, typos with suggestions, client natives called on the server |
| **Logic** | `not a == b`, `x == 1 or "b"`, unreachable code, duplicate table keys, removal during iteration, wrong `string.format` arguments |
| **Security** | client data reaching money, items or commands unchecked, `source` read after a `Wait`, SQL injection, downloaded code being run, obfuscation, exposed webhooks |
| **Performance** | `while true` without `Wait`, permanent per-frame loops, SQL in loops, broadcasts in fast loops |
| **Leaks** | handlers registered in loops, player tables never cleaned, unreleased models and DUIs, stuck NUI focus |
| **Manifest** | missing files, globs matching nothing, undeclared UI pages, broken `@resource/file` imports |
| **Events** | events missing `RegisterNetEvent`, handlers that do not exist, exports that do not exist |

Run `fxaudit rules` for the 80+ rules, and `fxaudit explain FX400` for the details of one.

## Install

You need [Lua 5.4](https://www.lua.org/download.html). On Windows: `winget install DEVCOM.Lua`.

```sh
git clone https://github.com/badidu09/fxaudit.git
cd fxaudit
lua bin/fxaudit scan /path/to/your/resources
```

On Windows, you can also add the `bin` folder to your `PATH` and run `fxaudit scan .`.

## Usage

```sh
fxaudit scan ./resources                    # analyze a whole server folder
fxaudit scan ./resources/my_script          # or a single resource
fxaudit scan . -s high                      # only show high and critical
fxaudit scan . --all                        # also show info-level remarks
fxaudit scan . --only FX400,FX404           # only these rules
fxaudit scan . -f json -o report.json       # machine-readable output
fxaudit scan . -f sarif -o fxaudit.sarif    # GitHub code scanning
```

Exit codes: `0` nothing at or above `--fail-on` (default `high`), `1` findings at or above it, `2` usage error.

## Silencing a finding

```lua
local unused = 1 -- fxaudit-ignore FX203
-- fxaudit-ignore FX200
print(GlobalFromElsewhere)
-- fxaudit-ignore-file FX202
```

## Configuration

Put a `.fxaudit.lua` at the root of your project. It must only contain constants:

```lua
return {
  globals = { "MyFrameworkGlobal" },     -- defined outside the scanned files
  disable = { "FX204", "FX207" },        -- rules to turn off
  severity = { FX202 = "info" },         -- change a rule's level
  exclude = { "vendor/" },               -- ignore paths containing this text
  min_severity = "low",
  fail_on = "high",
}
```

## GitHub Actions

```yaml
- uses: actions/checkout@v4
- uses: badidu09/fxaudit@develop
  with:
    path: .
    fail-on: high
```

## Limits

Please read this before trusting a score.

- **A good score does not prove a resource is safe.** Static analysis cannot see everything, and a determined attacker can hide code from it.
- **Protected files are not analyzed.** Escrowed and precompiled files are reported as `FX710`, and fxaudit says nothing about what they do. It will never try to decrypt them.
- **False positives exist.** Some findings carry `(medium confidence)` or `(low confidence)`. Read them as places to look, and silence them when they are wrong.
- **The analysis stays inside one function.** Validation done in a helper you call counts when its result is checked, but what a called function does internally is not followed.
- **Only Lua is analyzed.** JavaScript and C# scripts are not read.
- **Nothing runs in game.** fxaudit has not been run inside FXServer; it works on files, from the command line.

## Development

```sh
lua spec/run.lua                       # run the tests, no dependency needed
python tools/gen_natives.py            # refresh the natives database
```

See [CONTRIBUTING.md](CONTRIBUTING.md) to add a rule.

## License

[MIT](LICENSE)
