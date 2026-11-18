---
status: current
verified-against: 10d4d92
---

# Known Issues

Weaknesses that are known and not fixed, each with why. Remove an entry when it is
fixed, and say in the commit which one. Items that are accepted by design are labelled as
such and point at the ADR that accepted them.

## Open

**1. Oracle answers of zero or below are not rejected.** `getValueUSD` and
`_usdToTokenAmount` cast Chainlink's `int256` answer straight to `uint256`. A negative
answer would be read as an enormous price; a zero answer values the collateral at zero and
makes liquidation revert on division by zero. Healthy Chainlink feeds do not report these
for the listed assets, but the fix is a one-line `answer <= 0` revert in `OracleLib`. Found
while writing [[Threat-Model]]. No test covers it.

**2. No L2 sequencer-uptime check.** On an L2, after a sequencer outage, prices that are
stale but still inside the 3-hour window can be acted on right after restart. Matters only
once the protocol targets an L2 for real. See [[Oracles]].

**3. `totalBadDebtUSD` can count the same debt twice.** `deposit()` is permissionless, so a
stranded position can be re-collateralized and stranded again, adding its remaining debt a
second time. A recognition-flag mapping would fix it, but it changes accounting meaning and
there is no test built for it yet, so it was left. See [[Liquidations]].

**4. Wei-scale seizure seam.** `getAvailableLiquidity` is in token units while
`_seizeCollateral` converts with `__toScaledUp`, so a seizure that exactly saturates the cap
can leave a pool 1–2 wei short. The backstop path meets that condition on every call. The
obvious patch is an unexplained `-1`, which is why it was left. It is harmless at realistic
pool sizes, and the argument for that does not extend to a dust-scale pool. See
[[Liquidations]].

## Accepted by design

**5. The redemption fee rarely reaches the borrower.** A rational redeemer always picks
`redeemWithBackstop`: the redeemer nets the same either way, and that path moves the fee to
reserves. The fairness argument for letting the caller pick the target is weaker in practice
than it first looked. See [[0007-dusd-redemption]].

**6. Self-redemption on the backstop path jumps the liquidity queue.** A position can
redeem against itself through the backstop to get around the availability bound, for 0.5%.
Accepted in [[0007-dusd-redemption]].

**7. The debt ceiling is per chain, not global.** No chain can see total DUSD supply, so a
global cap cannot be enforced from the sending side. See [[0010-dusd-debt-ceiling]].

## Coverage gaps

**8. A DUSD-heavy position going unhealthy is rarely or never reached by the fuzzer.** Not
reached from a cold corpus in about 500,000 Medusa calls, with or without the ceiling target.
A dedicated target would close it. See [[Invariants]].

**9. Liveness is not asserted.** "A debt-free position can always withdraw in full" needs
try/catch around actor calls in the harness. Deferred. See [[Invariants]].

## Related

- [[Threat-Model]] — the trust assumptions these sit inside
- [[Invariants]] — what the fuzzer does check
