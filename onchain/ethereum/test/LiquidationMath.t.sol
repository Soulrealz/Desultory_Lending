// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LiquidationMath} from "../src/libraries/LiquidationMath.sol";

contract LiquidationMathTest is Test {
    uint256 constant WAD = 1e18;
    uint16 constant MAX_BPS = 10_000;

    ///////////////////////
    // healthFactor
    ///////////////////////

    function testHealthFactorIsMaxAtZeroDebt() public pure {
        assertEq(LiquidationMath.healthFactor(1_000e18, 0), type(uint256).max);
    }

    function testHealthFactorIsOneWhenCollateralEqualsDebt() public pure {
        assertEq(LiquidationMath.healthFactor(1_000e18, 1_000e18), WAD);
    }

    function testFuzzHealthFactorDecreasesWithDebt(uint128 collateral, uint96 debtA, uint96 debtB) public {
        vm.assume(debtA > 0 && debtB > debtA);
        uint256 hfA = LiquidationMath.healthFactor(collateral, debtA);
        uint256 hfB = LiquidationMath.healthFactor(collateral, debtB);
        assertGe(hfA, hfB, "more debt must never raise the health factor");
    }

    ///////////////////////
    // closeFactorBps
    ///////////////////////

    function testCloseFactorBands() public pure {
        assertEq(LiquidationMath.closeFactorBps(0.94e18), MAX_BPS, "deep band is a full close");
        assertEq(LiquidationMath.closeFactorBps(0.95e18 - 1), MAX_BPS, "just below the mark is still deep");
        assertEq(LiquidationMath.closeFactorBps(0.95e18), 5_000, "at the mark is the normal band");
        assertEq(LiquidationMath.closeFactorBps(0.99e18), 5_000, "normal band");
    }

    ///////////////////////
    // seize / repay round trip
    ///////////////////////

    function testSeizeExceedsRepayByTheBonus() public pure {
        assertEq(LiquidationMath.seizeFromRepay(1_000e18, 1_000), 1_100e18, "10% bonus");
        assertEq(LiquidationMath.seizeFromRepay(1_000e18, 500), 1_050e18, "5% bonus");
    }

    function testFuzzSeizeIsNeverBelowRepay(uint128 repay, uint16 bonusBps) public pure {
        bonusBps = uint16(bound(bonusBps, 0, 2_000));
        assertGe(LiquidationMath.seizeFromRepay(repay, bonusBps), repay, "seizure must cover the repayment");
    }

    /// @dev the back-solve must never charge more than the seizure it was derived from
    function testFuzzBackSolveNeverOvercharges(uint128 repay, uint16 bonusBps) public pure {
        bonusBps = uint16(bound(bonusBps, 0, 2_000));
        uint256 seize = LiquidationMath.seizeFromRepay(repay, bonusBps);
        assertLe(LiquidationMath.repayFromSeize(seize, bonusBps), repay, "round trip must not inflate the repayment");
    }

    ///////////////////////
    // splitBonus
    ///////////////////////

    function testSplitBonusTakesShareOfBonusOnly() public pure {
        // seize 1100 against a base of 1000: bonus is 100, protocol takes 30%
        (uint256 cut, uint256 toLiquidator) = LiquidationMath.splitBonus(1_000e18, 1_100e18, 3_000);
        assertEq(cut, 30e18, "30% of the 100 bonus");
        assertEq(toLiquidator, 1_070e18, "liquidator keeps the rest");
    }

    function testSplitBonusIsZeroWhenThereIsNoBonus() public pure {
        (uint256 cut, uint256 toLiquidator) = LiquidationMath.splitBonus(1_000e18, 1_000e18, 3_000);
        assertEq(cut, 0, "no bonus, no cut");
        assertEq(toLiquidator, 1_000e18);
    }

    /// @dev the property that keeps liquidation worth calling. If rounding the cut up
    /// could push proceeds below what the liquidator paid, nobody calls it.
    function testFuzzLiquidatorIsNeverWorseOff(uint128 base, uint16 bonusBps, uint16 shareBps) public pure {
        bonusBps = uint16(bound(bonusBps, 0, 2_000));
        shareBps = uint16(bound(shareBps, 0, MAX_BPS));

        uint256 seize = LiquidationMath.seizeFromRepay(base, bonusBps);
        (uint256 cut, uint256 toLiquidator) = LiquidationMath.splitBonus(base, seize, shareBps);

        assertGe(toLiquidator, base, "liquidator must never receive less than they paid");
        assertLe(cut, seize - LiquidationMath.repayFromSeize(seize, bonusBps) + 1, "cut cannot exceed the bonus");
        assertEq(cut + toLiquidator, seize, "the split must be exhaustive");
    }
}
