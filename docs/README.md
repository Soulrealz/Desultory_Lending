# Desultory Lending — Documentation Vault

This directory is an [Obsidian](https://obsidian.md) vault. Open Obsidian and
"Open folder as vault" pointed at this `docs/` directory.

Notes link to each other with wikilinks (`[[Note Name]]`), which render as plain
text on GitHub. Reading here works; reading in Obsidian works better.

## Zones

| Zone | Contract |
|---|---|
| `Protocol/` | **Maintained.** What the protocol actually does, per module. |
| `Decisions/` | **Maintained.** Numbered ADRs. Accepted ones are never edited, only superseded. |
| `Audit/` | **Maintained.** Threat model, invariants, findings, assessments. |
| `Notes/` | **Not maintained.** Research and scratch thinking. May be wrong. |

`superpowers/` is gitignored working output from planning sessions. It is visible
in the app but is not part of the vault's maintained content.

## Orientation

For a fast map of the repo rather than depth, read `PROJECT_STRUCTURE.md` and
`PROJECT_CONTEXT.md` at the repository root. This vault is the territory; those
two files are the map.
