## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each mapped to a label of the same name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Resolving an issue

Whenever an issue is being solved, the **last step is always to open a PR against `main` and merge it** — resolving the issue is not complete until its PR is opened and merged. Only do this once the work is committed, every acceptance criterion is genuinely met, and the checks pass. Use `GH_HOST=github.com gh pr create --base main ...` then `gh pr merge <n> --merge`. Close the issue as part of the same wrap-up.
