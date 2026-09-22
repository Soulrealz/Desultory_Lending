// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/**
 * @dev the arithmetic of a redemption, with no storage, no oracle and no position.
 *
 * It lives apart from Desultory for the same reason LiquidationMath does: this is an
 * inverse PAIR, and an inverse pair whose two halves disagree is exactly the defect
 * class ADR 0004 catalogues. Here both halves sit next to each other where the
 * disagreement would be visible.
 *
 * Both functions are unit-agnostic: they take a quantity and return the same unit.
 * Desultory calls them in USD, which avoids a second token conversion and its rounding.
 *
 * Rounding follows the protocol's existing policy — every tie goes to the pool.
 */
library RedemptionMath {
    uint16 internal constant MAX_BPS = 10_000;

    /**
     * @dev USD of collateral a redeemer receives for burning `dusdAmount`, net of the fee.
     *
     * Rounds DOWN: the redeemer never receives more than the fee schedule warrants.
     * Same direction as seizeFromRepay.
     */
    function collateralFromDusd(uint256 dusdAmount, uint16 feeBps) internal pure returns (uint256) {
        return (dusdAmount * (MAX_BPS - feeBps)) / MAX_BPS;
    }

    /**
     * @dev the exact inverse: DUSD that must be burned for `collateralUSD` of collateral.
     *
     * Rounds UP: a redemption capped by liquidity or by the position's balance burns at
     * least as much DUSD as the collateral actually delivered warrants, never less.
     * Same direction as repayFromSeize, and for the same reason — the inverse is only
     * ever used to recompute a CAPPED figure downward, and rounding it down there would
     * hand the redeemer a sliver of free collateral on every partial fill.
     */
    function dusdFromCollateral(uint256 collateralUSD, uint16 feeBps) internal pure returns (uint256) {
        uint256 denominator = MAX_BPS - feeBps;
        return (collateralUSD * MAX_BPS + denominator - 1) / denominator;
    }
}
