# Desultory Lending — Foundry project

Dependencies are not vendored and not tracked as submodules. They install into the
gitignored `lib/` directory.

## To install dependencies do:

Use `--no-git` on every line. Without it, Foundry 1.x adds each dependency as a git
submodule and recreates `.gitmodules`, which this project deliberately does not use.
(The old `--no-commit` flag no longer exists.)

```
forge install LayerZero-Labs/layerzero-v2 --no-git
forge install LayerZero-Labs/devtools --no-git
forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-git
forge install OpenZeppelin/openzeppelin-contracts --no-git
forge install foundry-rs/forge-std --no-git
forge install smartcontractkit/foundry-chainlink-toolkit --no-git
forge install Recon-Fuzz/chimera@0.1.4 --no-git
forge install GNSPS/solidity-bytes-utils --no-git
forge install LayerZero-Labs/LayerZero --no-git
```

Chimera is pinned to `0.1.4` because the fuzzing harness is written against that
version's API.

The last two are transitive dependencies of LayerZero's `TestHelperOz5`, which the
cross-chain tests build on: `solidity-bytes-utils` for `BytesLib`, and the LayerZero
V1 repo for the V1 interfaces its ULN mocks still reference.

## To run tests do:

Tests require the `PRIVATE_KEY` env var. Any key works locally:

```
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 forge test -vvv
```

## Fuzzing

Stateful invariant fuzzing lives in `test/recon/`, built on the Chimera scaffold.
One harness drives both engines:

```
medusa fuzz
echidna . --contract CryticTester --config echidna.yaml
```

Counterexamples from either engine replay as ordinary Foundry tests in
`test/recon/CryticToFoundry.sol`.

The harness asserts internal-consistency invariants only — see
`docs/Audit/Invariants.md`. Liquidation entry points are deliberately absent from the
target surface while that engine is broken.
