---
status: current
verified-against: 10d4d92
---

# Threat Model

What the protocol trusts, who can do what, and where an attacker would start. The
[[Invariants]] say what must stay true. This note says what has to be trusted for those
invariants to be worth anything. Known, accepted weaknesses are tracked in [[Known-Issues]].

## What is at stake

- **Deposited tokens** held by `Desultory`: every lender's principal plus all collateral.
- **DUSD integrity on every chain.** Unbacked DUSD can drain any position through
  redemption and repays real debt at par, so a mint bug anywhere is a loss everywhere.
- **Protocol reserves** (`pool.reserves`), which also fund the internal backstop.

## Trust assumptions

| Trusted party | Trusted for | If that trust fails |
|---|---|---|
| **The owner key** | Everything in the table below. It is one `Ownable` EOA, with no timelock and no multisig. | Total loss. See below. |
| **Chainlink feeds** | Fresh, correct, positive USD prices for every listed token. | Wrong prices are wrong health factors: unfair liquidations, or under-collateralized borrowing. |
| **LayerZero endpoint and DVNs** | Delivering only genuine messages from configured peers. The repo sets no DVN configuration, so it runs on LayerZero's defaults. | A forged message mints DUSD with no debt behind it. |
| **Adapter peers on every chain** | Being the real `Adapter`. | Same: the peer can mint unlimited DUSD. ADR 0003 calls this the entire trust boundary. |
| **Listed tokens** | Behaving as plain ERC20s: no fee on transfer, no rebasing, no transfer hooks, no blocklist. | Custody accounting breaks (fee-on-transfer, rebasing), or a re-entry path opens (hooks). See *Re-entrancy*. |

### What the owner can do

| Contract | Power | Worst case |
|---|---|---|
| `Desultory` | `addToken(config)` | List a token with a fake feed, deposit it, borrow every real asset out. |
| `Desultory` | `setTokenRetired` | Freeze new deposits and borrows in a token. Cannot freeze exits. |
| `Desultory` | `withdrawReserves(token, to, amount)` | Take protocol revenue, and with it the internal backstop's funding. Cannot touch depositor principal. |
| `Desultory` | `releaseBackstop` | Return committed backstop capital to reserves. |
| `Desultory` | `setDusdStabilityFee` (capped at 100%), `setDusdDebtCeiling` | Raise the fee on DUSD borrowers; stop all new DUSD borrowing. |
| `Desultory` | `setAdapter`, `setAllowedDestination` | Send cross-chain borrows to an adapter or chain of its choosing. Debt is still recorded at home. |
| `DUSD` | `setMinter`, OFT `setPeer` | Grant itself mint rights: unlimited DUSD. |
| `Adapter` | `setDesultory`, OApp `setPeer` | Point the receive side at an attacker-controlled peer: unlimited DUSD on this chain. |
| all | `transferOwnership`, `renounceOwnership` (single-step `Ownable`) | A typo or a renounce leaves admin permanently broken. |

**What the owner cannot do:** change an existing token's price feed, LTV or threshold (no
setter exists); withdraw depositor principal directly; reduce anyone's balance; pause exits.
Those limits only hold while the owner key is otherwise honest. The DUSD minter and
`addToken` powers above are each enough on their own to drain the protocol.

## Entry points by caller

| Caller | Functions | Main abuse to consider |
|---|---|---|
| Anyone | `deposit`, `repay`, `repayDUSD` | Re-collateralizing a stranded position to count its bad debt twice ([[Known-Issues]]). Dust deposits. |
| Position owner | `withdraw`, `borrow`, `borrowDUSD`, `borrowDUSDTo` | Getting out more than the LTV allows, through rounding or a stale price. |
| Anyone | `liquidate`, `liquidateWithBackstop` | Liquidating a healthy position; seizing more than the bonus; over-spending reserves on the backstop. |
| Anyone with DUSD | `redeem`, `redeemWithBackstop` | Redeeming against an unhealthy position; jumping the liquidity queue (accepted, ADR 0007). |
| NFT holder | ERC721 transfers | Moving a liquidatable position out from under a liquidator (blocked by the transfer gate). |
| Anyone, via LayerZero | `Adapter._lzReceive` | Only reachable from a configured peer. Has no checks on purpose. |

## Specific surfaces

### Oracles

- **Staleness** is checked: `OracleLib` reverts if a feed is over 3 hours old. Every
  state-changing call that reads a price stops while a feed is dead. `deposit` and `repay`
  do not read prices and keep working. See [[Oracles]].
- **A zero or negative answer is not rejected.** `getValueUSD` and `_usdToTokenAmount` cast
  the answer straight to `uint256`. A negative answer becomes an enormous price, so that
  collateral looks nearly infinitely valuable. A zero answer values the collateral at zero
  and makes liquidation revert on division by zero. Tracked in [[Known-Issues]].
- **No L2 sequencer-uptime check.** The protocol is meant to run on L2s, where a sequencer
  outage lets stale-but-not-yet-expired prices be acted on as soon as it restarts.
- Chainlink `minAnswer`/`maxAnswer` clamping is not detected. In a crash below the feed's
  floor, the protocol keeps seeing the floor price.

### Re-entrancy

`nonReentrant` is on `liquidate`, `liquidateWithBackstop`, `redeem` and
`redeemWithBackstop` only. `deposit`, `withdraw`, `borrow` and `repay` are unguarded and
depend on two things. Their token transfer is the last thing they do, after all state is
written. And listed tokens have no transfer hooks, an assumption enforced only by the owner
choosing which tokens to list.

One callback happens earlier than that. `deposit(0, ...)` mints the new position with
`_safeMint`, which calls `onERC721Received` on a contract caller after `accrue` and before
the deposit is credited. At that point the only state written is the completed accrual and
a new, empty position, so re-entering finds the books consistent. It is not covered by a
test, though, and any change that writes state before the mint would turn it into a real
re-entry point. D2.3 (flash-loan backstop) will be the first place an
untrusted contract gets called back in the middle of a liquidation. The guard is on the
public wrappers, not on the private `_liquidate`/`_redeem`.

### Cross-chain

- The source chain records debt and runs every check before sending. The receive side
  must never revert (see [[Cross-Chain]]). A message that is never delivered leaves a
  borrower with debt and no DUSD until someone retries it; LayerZero lets anyone retry.
- The debt ceiling caps each home chain separately, so it cannot cap global DUSD
  supply. No chain can see the others' supply. See [[0010-dusd-debt-ceiling]].

### Economic

- **Solvency is not guaranteed** and the fuzzer does not claim it. A fast enough price drop
  creates bad debt, which is counted, not prevented.
- **Liquidations are not guaranteed to happen.** There is no keeper; ElizaOS (D3) is not
  built. A liquidation also needs the pool to have available liquidity, or the backstop path
  with enough reserves.
- **DUSD has a floor, not a ceiling.** Redemption holds it near $0.995 and above. Nothing
  pushes it down from above $1, and a binding debt ceiling pushes it up. See [[DUSD]].

## Out of scope today

Governance (not built), upgrades (there are none), front-running and MEV ordering between
liquidators (first come, first served, with a clamp so a bot that loses the race does not
revert), and gas griefing through the 32-token cap.

## Related

- [[Architecture]] — the contracts and flows this note assumes
- [[Known-Issues]] — accepted and open weaknesses
- [[Invariants]] — what the fuzzer checks
- [[0003-dusd-only-cross-chain-borrowing]] — why peer configuration is the trust boundary
