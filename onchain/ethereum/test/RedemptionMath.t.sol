// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RedemptionMath} from "../src/libraries/RedemptionMath.sol";

contract RedemptionMathTest is Test {
    uint16 constant FEE = 50; // 0.5%

    function testCollateralFromDusdTakesTheFee() public pure {
        // 1000 DUSD at 50bps buys 995 USD of collateral
        assertEq(RedemptionMath.collateralFromDusd(1_000e18, FEE), 995e18);
    }

    function testZeroFeeIsIdentity() public pure {
        assertEq(RedemptionMath.collateralFromDusd(1_000e18, 0), 1_000e18);
        assertEq(RedemptionMath.dusdFromCollateral(1_000e18, 0), 1_000e18);
    }

    /// @dev the inverse must never under-charge: a redeemer burns at least as much DUSD
    /// as the collateral they are handed warrants. Same direction repayFromSeize rounds.
    function testDusdFromCollateralRoundsUp() public pure {
        // 995 USD of collateral warrants 1000 DUSD exactly
        assertEq(RedemptionMath.dusdFromCollateral(995e18, FEE), 1_000e18);
        // one wei more collateral must cost strictly more than 1000 DUSD, not the same
        assertGt(RedemptionMath.dusdFromCollateral(995e18 + 1, FEE), 1_000e18);
    }

    /// @dev round-tripping must never let a redeemer extract more collateral than they paid for
    function testFuzzRoundTripNeverFavorsTheRedeemer(uint128 dusdAmount) public {
        vm.assume(dusdAmount > 0);
        uint256 collateral = RedemptionMath.collateralFromDusd(dusdAmount, FEE);
        vm.assume(collateral > 0);
        uint256 backToDusd = RedemptionMath.dusdFromCollateral(collateral, FEE);
        assertLe(backToDusd, dusdAmount, "round trip must not inflate the DUSD owed");
    }

    function testFuzzCollateralIsAlwaysLessThanDusdAtANonZeroFee(uint128 dusdAmount) public {
        vm.assume(dusdAmount > 1_000); // below this the fee truncates to zero, which is fine
        assertLt(RedemptionMath.collateralFromDusd(dusdAmount, FEE), dusdAmount);
    }
}
