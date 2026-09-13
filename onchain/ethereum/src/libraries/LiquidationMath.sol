// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/**
 * @dev the arithmetic of a liquidation, with no storage, no oracle and no position.
 *
 * It lives apart from Desultory because four of the seven defects in the engine this
 * replaces were arithmetic errors (payout in the wrong token, unbounded seizure, an
 * inverted penalty, a proportion that always rounded to zero) and none of them were
 * reachable by a test that did not first build a whole protocol. Here they are.
 *
 * Every function is unit-agnostic: it takes two quantities in the SAME unit and returns
 * that unit. Desultory calls seizeFromRepay in USD and splitBonus in collateral-token
 * amounts, which avoids a second USD-to-token conversion and the rounding it would add.
 *
 * Rounding follows the protocol's existing policy — every tie goes to the pool.
 */
library LiquidationMath {
    uint256 internal constant WAD = 1e18;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant DEEP_UNDERWATER_HF = 0.95e18;
    uint16 internal constant CLOSE_FACTOR_BPS = 5_000;

    /**
     * @dev collateral weighted by each asset's liquidation threshold, over total debt,
     * scaled to WAD. Returns max at zero debt so no caller has to special-case it.
     */
    function healthFactor(uint256 weightedCollateral, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) {
            return type(uint256).max;
        }
        return (weightedCollateral * WAD) / debt;
    }

    /**
     * @dev how much of a position's debt one call may retire.
     *
     * Below DEEP_UNDERWATER_HF a half close leaves a position that is still liquidatable
     * and still shrinking, so the remainder rots. Above it, a partial close preserves the
     * borrower's upside if the price rebounds.
     */
    function closeFactorBps(uint256 hf) internal pure returns (uint16) {
        return hf < DEEP_UNDERWATER_HF ? MAX_BPS : CLOSE_FACTOR_BPS;
    }

    /// @dev value seized for a given repayment, including the bonus. Rounds DOWN: a
    /// liquidator never seizes more than earned.
    function seizeFromRepay(uint256 repayAmount, uint16 bonusBps) internal pure returns (uint256) {
        return (repayAmount * (MAX_BPS + bonusBps)) / MAX_BPS;
    }

    /// @dev the inverse, used when seizure has been clamped to the collateral actually
    /// held. Rounds UP: a clamped liquidation never under-charges the liquidator.
    function repayFromSeize(uint256 seizeAmount, uint16 bonusBps) internal pure returns (uint256) {
        uint256 denominator = MAX_BPS + bonusBps;
        return (seizeAmount * MAX_BPS + denominator - 1) / denominator;
    }

    /**
     * @dev split the seizure between the protocol and the liquidator. Only the bonus is
     * split; the base — what the liquidator paid for — is never touched.
     *
     * The cut rounds UP, favouring the protocol, but is capped at the bonus. That cap is
     * the point: if rounding could push proceeds below what the liquidator paid, the call
     * is a guaranteed loss and nobody makes it.
     */
    function splitBonus(uint256 baseAmount, uint256 seizeAmount, uint16 protocolShareBps)
        internal
        pure
        returns (uint256 protocolCut, uint256 toLiquidator)
    {
        if (seizeAmount <= baseAmount) {
            return (0, seizeAmount);
        }

        uint256 bonus = seizeAmount - baseAmount;
        protocolCut = (bonus * protocolShareBps + MAX_BPS - 1) / MAX_BPS;
        if (protocolCut > bonus) {
            protocolCut = bonus;
        }
        toLiquidator = seizeAmount - protocolCut;
    }
}
