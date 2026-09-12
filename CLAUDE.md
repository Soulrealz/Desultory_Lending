# Desultory Lending — Project Instructions

## Documentation upkeep (mandatory, end of every task)

After completing the work for a prompt, and before ending the turn, check whether any of these need updating. Do this without being asked.

1. **`PROJECT_STRUCTURE.md`** — update whenever files or directories were added, removed, renamed, or moved during the task. It holds a tree of the repository (directories and files) with one-line descriptions. Exclude gitignored content (`lib/`, `out/`, `cache/`, `.env`, `broadcast/`).

2. **`PROJECT_CONTEXT.md`** — update whenever new core logic was added or existing core logic was rewritten: contracts, libraries, deploy scripts, or significant test infrastructure. Adjust the section for the affected module so it still gives an accurate general idea of what the module does and where things live. This file is a rough map, not full documentation — keep entries short and skip minor changes (comments, formatting, renames of locals, small refactors that don't change behavior).

3. **The vault at `docs/`** — this is narrower than the two rules above: it fires on *behavior* changes, not on any file touch.
   - When a module's behavior changes, update its note in `docs/Protocol/` and set `verified-against` in the frontmatter to the current commit.
   - When a design decision is made, write a numbered ADR in `docs/Decisions/`. Accepted ADRs are never edited to reflect a changed mind — supersede them with a new record that links back.
   - `docs/Notes/` is never mandatory. It is scratch space and makes no accuracy claim.
   - Use wikilinks (`[[Note Name]]`) for internal links and Mermaid for diagrams.

If a task changed neither structure nor core logic, no update is needed — don't touch the files just to touch them.

## Build & test

- Foundry project lives in `onchain/ethereum/`. Dependencies are not vendored: clone/install them into the gitignored `lib/` (see `onchain/ethereum/README.md`; note `forge install --no-commit` no longer exists in Foundry 1.x).
- Tests require the `PRIVATE_KEY` env var (any key works locally, e.g. the default Anvil key): `PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge test`

## Conventions

- Line endings are LF, enforced via `.gitattributes`. Never commit CRLF.
