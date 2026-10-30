# Contributing

Tests have no dependency: `lua spec/run.lua`, from the repository root.

## Adding a rule

1. Declare it in `src/fxaudit/rules/registry.lua`, with the next free id of its category.
2. Implement it in the matching module of `src/fxaudit/rules/`. A module exposes
   `checkFile(ctx)` and/or `checkResource(resource)`, and reports with
   `ctx.report(id, node, message, { hint = ..., confidence = ..., severity = ... })`.
3. Test both directions in `spec/`: code it must flag, and similar code it must leave alone.

## What makes a good rule

A false positive costs more than a missed bug: people stop reading a tool that cries wolf.

- Before submitting, run the rule on real resources (ox_lib, qbx_core, esx_core, qb-core) and read what it reports.
- If a rule is right only most of the time, set `confidence = "medium"` and say why in a comment.
- Messages state what is wrong and what happens at runtime. The `hint` says what to write instead.

## Reporting a false positive

Open an issue with the smallest code that reproduces it, and the rule id.

## Reporting a vulnerability found with fxaudit

Tell the author of the affected resource privately before publishing anything.
