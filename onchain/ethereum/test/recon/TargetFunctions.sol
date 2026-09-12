// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

import {Properties} from "./Properties.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/**
 * @dev the call surface the fuzzer drives. Every target is clamped with
 * Chimera's `between`, which wraps by modulo and therefore never reverts —
 * a reverting clamp wastes the call.
 *
 * Liquidation entry points are deliberately absent. They are not excluded by
 * config; they are simply never written, so there is nothing to accidentally
 * re-enable while that engine is broken.
 */
abstract contract TargetFunctions is BaseTargetFunctions, Properties {
    uint256 internal constant MAX_WARP = 30 days;

    function _tokenSlot(uint8 seed) private pure returns (uint256) {
        return seed % 2;
    }

    function desultory_deposit(uint8 actorSeed, uint8 tokenSeed, uint8 positionSeed, uint256 amount)
        public
        updateGhosts
    {
        address actor = _getActor(actorSeed);
        MockERC20 token = _getToken(tokenSeed);
        uint256 slot = _tokenSlot(tokenSeed);

        uint256 balance = token.balanceOf(actor);
        precondition(balance > 0);
        amount = between(amount, 1, balance);

        // one seed value in four opens a fresh position
        uint256 positionId = positionSeed % 4 == 0 ? 0 : _getPosition(positionSeed);

        vm.prank(actor);
        desultory.deposit(positionId, address(token), amount);

        ghostPaidIn[slot] += amount;

        if (positionId == 0) {
            // Position assigns ids from _nextTokenId starting at 1, incrementing
            // per mint. Setup mints none and only this harness can trigger a
            // mint, so the id just created is exactly positionIds.length + 1.
            positionIds.push(positionIds.length + 1);
        }
    }

    function desultory_withdraw(uint8, uint8 tokenSeed, uint8 positionSeed, uint256 amount) public updateGhosts {
        precondition(positionIds.length > 0);

        MockERC20 token = _getToken(tokenSeed);
        uint256 slot = _tokenSlot(tokenSeed);
        uint256 positionId = _getPosition(positionSeed);

        uint256 collateral = desultory.getPositionCollateralForToken(positionId, address(token));
        precondition(collateral > 0);
        amount = between(amount, 1, collateral);

        // withdraw is owner-gated, so the caller is the owner rather than a seeded actor
        vm.prank(position.ownerOf(positionId));
        desultory.withdraw(positionId, address(token), amount);

        ghostPaidOut[slot] += amount;
    }

    function desultory_borrow(uint8, uint8 tokenSeed, uint8 positionSeed, uint256 amount) public updateGhosts {
        precondition(positionIds.length > 0);

        MockERC20 token = _getToken(tokenSeed);
        uint256 slot = _tokenSlot(tokenSeed);
        uint256 positionId = _getPosition(positionSeed);

        uint256 liquidity = desultory.getAvailableLiquidity(address(token));
        precondition(liquidity > 0);

        // Clamp to the position's remaining borrow capacity as well as to pool
        // liquidity. Clamping on liquidity alone makes almost every generated
        // borrow revert with Desultory__CollateralValueNotEnough, which burns
        // the call without exploring anything.
        uint256 capacity = _borrowCapacityInToken(positionId, address(token));
        precondition(capacity > 0);

        uint256 ceiling = capacity < liquidity ? capacity : liquidity;
        amount = between(amount, 1, ceiling);

        // borrow is owner-gated
        vm.prank(position.ownerOf(positionId));
        desultory.borrow(positionId, address(token), amount);

        ghostPaidOut[slot] += amount;
    }

    function desultory_repay(uint8 actorSeed, uint8 tokenSeed, uint8 positionSeed, uint256 amount)
        public
        updateGhosts
    {
        precondition(positionIds.length > 0);

        address actor = _getActor(actorSeed);
        MockERC20 token = _getToken(tokenSeed);
        uint256 slot = _tokenSlot(tokenSeed);
        uint256 positionId = _getPosition(positionSeed);

        uint256 debt = desultory.getPositionBorrowForToken(positionId, address(token));
        precondition(debt > 0);

        uint256 balance = token.balanceOf(actor);
        precondition(balance > 0);

        // repay is permissionless, so any actor may settle any position's debt
        amount = between(amount, 1, debt < balance ? debt : balance);

        vm.prank(actor);
        desultory.repay(positionId, address(token), amount);

        ghostPaidIn[slot] += amount;
    }

    /**
     * @dev how much of `token` this position can still borrow, in token units.
     *
     * getValueUSD(token, amount) is amount * price18 / 10**tokenDecimals, so the
     * USD value of one whole token is getValueUSD(token, 10**tokenDecimals).
     * Both configured tokens are 18-decimal, matching the deploy script.
     */
    function _borrowCapacityInToken(uint256 positionId, address token) internal view returns (uint256) {
        uint256 maxUSD = desultory.userMaxBorrowValueUSD(positionId);
        uint256 owedUSD = desultory.userBorrowedAmountUSD(positionId);
        if (owedUSD >= maxUSD) {
            return 0;
        }

        uint256 unitPriceUSD = desultory.getValueUSD(token, WAD);
        if (unitPriceUSD == 0) {
            return 0;
        }

        return ((maxUSD - owedUSD) * WAD) / unitPriceUSD;
    }

    function desultory_borrowDUSD(uint8, uint8 positionSeed, uint256 amount) public updateGhosts {
        precondition(positionIds.length > 0);
        uint256 positionId = _getPosition(positionSeed);

        uint256 maxUSD = desultory.userMaxBorrowValueUSD(positionId);
        uint256 owedUSD = desultory.userBorrowedAmountUSD(positionId);
        precondition(maxUSD > owedUSD);

        // DUSD is valued at $1, so USD headroom is the DUSD amount directly
        amount = between(amount, 1, maxUSD - owedUSD);

        vm.prank(position.ownerOf(positionId));
        desultory.borrowDUSD(positionId, amount);
        ghostDusdMinted += amount;
    }

    function desultory_repayDUSD(uint8, uint8 positionSeed, uint256 amount) public updateGhosts {
        precondition(positionIds.length > 0);
        uint256 positionId = _getPosition(positionSeed);

        uint256 debt = desultory.getPositionDusdDebt(positionId);
        precondition(debt > 0);

        address payer = position.ownerOf(positionId);
        uint256 balance = dusd.balanceOf(payer);
        precondition(balance > 0);

        amount = between(amount, 1, debt < balance ? debt : balance);

        vm.prank(payer);
        desultory.repayDUSD(positionId, amount);
        ghostDusdBurned += amount;
    }

    function warp(uint32 secs) public updateGhosts {
        uint256 jump = between(uint256(secs), 1, MAX_WARP);
        vm.warp(block.timestamp + jump);
    }

    /// @dev price movement is wide on purpose. Every invariant is an
    /// internal-consistency property, so they survive the protocol going
    /// economically underwater — which it will, since nothing can liquidate.
    /// Bad debt reached this way is expected, not a finding.
    function oracle_setPrice(uint8 tokenSeed, uint256 priceSeed) public updateGhosts {
        MockV3Aggregator feed = _getFeed(tokenSeed);
        int256 initial = tokenSeed % 2 == 0 ? WETH_INITIAL_PRICE : USDC_INITIAL_PRICE;

        uint256 newPrice = between(priceSeed, uint256(initial) / 100, uint256(initial) * 100);
        feed.updateAnswer(int256(newPrice));
    }
}
