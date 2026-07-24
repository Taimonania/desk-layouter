---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

Use /tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, verify the work: run /code-review (does the code follow the standards and match the spec?) **and** /acceptance-review (do the change's UI-observable acceptance criteria actually render correctly?) in the same verification pass. Address the findings from both.

Commit your work to the current branch.

As the final step, open a PR against `main` and merge it — resolving an issue is not complete until its PR is opened and merged (see AGENTS.md, "Resolving an issue").
