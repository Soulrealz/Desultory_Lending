// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

import {Properties} from "./Properties.sol";
import {Desultory} from "../../src/Desultory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/**
 * @dev the call surface the fuzzer drives. Every target is clamped with
 * Chimera's `between`, which wraps by modulo and therefore never reverts —
 * a reverting clamp wastes the call.
 *
 * Liquidation entry points are present (`desultory_liquidate`, below) and are on the
 * fuzzed call surface: the engine is real and this harness targets it, including the
 * same-asset case (debtAsset == collateralAsset), which is legal in production and not
 * excluded here.
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

    function desultory_liquidate(uint8 positionSeed, uint8 debtSeed, uint8 collatSeed, uint256 amount)
        public
        updateGhosts
    {
        precondition(positionIds.length > 0);
        uint256 positionId = _getPosition(positionSeed);

        // only drive the path the engine is specified for; a healthy position reverting is
        // correct behaviour, not a finding, and would just waste the call
        precondition(desultory.healthFactor(positionId) < 1e18);

        MockERC20 debtToken = _getToken(debtSeed);
        MockERC20 collatToken = _getToken(collatSeed);

        uint256 debt = desultory.getPositionBorrowForToken(positionId, address(debtToken));
        precondition(debt > 0);
        precondition(desultory.getPositionCollateralForToken(positionId, address(collatToken)) > 0);

        amount = between(amount, 1, debt);

        uint256 debtSlot = _tokenSlot(debtSeed);
        uint256 collatSlot = _tokenSlot(collatSeed);

        // debtSeed and collatSeed are independent, so they can select the same token, and
        // liquidate() places no restriction on debtAsset == collateralAsset — same-asset
        // liquidation is a legal, real production path and must be exercised, not dodged.
        // When the slots coincide, a single call pays debt tokens IN and seizes collateral
        // OUT of the very same balance, so the balance can move in either net direction
        // depending on repayAmount vs. the liquidator's cut of the seizure. Taking two
        // independent unsigned "after - before" legs (one assuming the balance only rises,
        // one assuming it only falls) underflows whichever leg guessed wrong. Snapshot the
        // single shared balance once instead and record one signed net delta, so the ghosts
        // record whatever actually happened rather than an assumed direction — this still
        // reconciles with property_tokenConservation, which only requires that every call's
        // contribution to (paidIn - paidOut) match that call's actual balance change.
        if (debtSlot == collatSlot) {
            uint256 before = debtToken.balanceOf(address(desultory));

            vm.prank(liquidator);
            desultory.liquidate(positionId, address(debtToken), address(collatToken), amount);

            uint256 afterBal = debtToken.balanceOf(address(desultory));
            if (afterBal >= before) {
                ghostPaidIn[debtSlot] += afterBal - before;
            } else {
                ghostPaidOut[debtSlot] += before - afterBal;
            }
        } else {
            uint256 paidBefore = debtToken.balanceOf(address(desultory));
            uint256 seizedBefore = collatToken.balanceOf(address(desultory));

            vm.prank(liquidator);
            desultory.liquidate(positionId, address(debtToken), address(collatToken), amount);

            // ghosts track what actually moved, not what was requested: the call clamps to the
            // close factor and to collateral held, so the two can differ
            ghostPaidIn[debtSlot] += debtToken.balanceOf(address(desultory)) - paidBefore;
            ghostPaidOut[collatSlot] += seizedBefore - collatToken.balanceOf(address(desultory));
        }
    }

    /// @dev the backstopped liquidation path. Same ghost handling as desultory_liquidate —
    /// the reserve commit moves no tokens, so only the seizure payout and the repayment
    /// show up in the balances.
    function desultory_liquidateWithBackstop(uint8 positionSeed, uint8 debtSeed, uint8 collatSeed, uint256 amount)
        public
        updateGhosts
    {
        precondition(positionIds.length > 0);
        uint256 positionId = _getPosition(positionSeed);
        precondition(desultory.healthFactor(positionId) < 1e18);

        MockERC20 debtToken = _getToken(debtSeed);
        MockERC20 collatToken = _getToken(collatSeed);

        uint256 debt = desultory.getPositionBorrowForToken(positionId, address(debtToken));
        precondition(debt > 0);
        precondition(desultory.getPositionCollateralForToken(positionId, address(collatToken)) > 0);

        amount = between(amount, 1, debt);

        uint256 debtSlot = _tokenSlot(debtSeed);
        uint256 collatSlot = _tokenSlot(collatSeed);

        if (debtSlot == collatSlot) {
            uint256 before = debtToken.balanceOf(address(desultory));

            vm.prank(liquidator);
            desultory.liquidateWithBackstop(positionId, address(debtToken), address(collatToken), amount);

            uint256 afterBal = debtToken.balanceOf(address(desultory));
            if (afterBal >= before) {
                ghostPaidIn[debtSlot] += afterBal - before;
            } else {
                ghostPaidOut[debtSlot] += before - afterBal;
            }
        } else {
            uint256 paidBefore = debtToken.balanceOf(address(desultory));
            uint256 seizedBefore = collatToken.balanceOf(address(desultory));

            vm.prank(liquidator);
            desultory.liquidateWithBackstop(positionId, address(debtToken), address(collatToken), amount);

            ghostPaidIn[debtSlot] += debtToken.balanceOf(address(desultory)) - paidBefore;
            ghostPaidOut[collatSlot] += seizedBefore - collatToken.balanceOf(address(desultory));
        }
    }

    /// @dev the owner returning committed backstop capital to reserves. Owner-only, so it
    /// is pranked as the deployer like desultory_withdrawReserves — but unlike that one it
    /// moves no tokens, so the ghosts must NOT be touched here.
    function desultory_releaseBackstop(uint8 tokenSeed, uint256 amount) public updateGhosts {
        MockERC20 token = _getToken(tokenSeed);

        Desultory.Pool memory pool = desultory.getPoolInfo(address(token));
        precondition(pool.backstopScaledDeposits > 0);

        uint256 committed = pool.backstopScaledDeposits * pool.liquidityIndex / 1e18;
        precondition(committed > 0);

        uint256 available = desultory.getAvailableLiquidity(address(token));
        precondition(available > 0);

        amount = between(amount, 1, committed < available ? committed : available);

        vm.prank(desultory.owner());
        desultory.releaseBackstop(address(token), amount);
    }

    /// @dev the owner draining protocol revenue. Value-moving and owner-only, so it is
    /// pranked as the deployer; the ghosts must see it or property_tokenConservation
    /// breaks the first time the fuzzer calls it.
    function desultory_withdrawReserves(uint8 tokenSeed, uint256 amount) public updateGhosts {
        MockERC20 token = _getToken(tokenSeed);
        uint256 slot = _tokenSlot(tokenSeed);

        uint256 reserves = desultory.getPoolInfo(address(token)).reserves;
        precondition(reserves > 0);

        uint256 cash = token.balanceOf(address(desultory));
        precondition(cash > 0);

        amount = between(amount, 1, reserves < cash ? reserves : cash);

        vm.prank(desultory.owner());
        desultory.withdrawReserves(address(token), address(this), amount);
        ghostPaidOut[slot] += amount;
    }

    function warp(uint32 secs) public updateGhosts {
        uint256 jump = between(uint256(secs), 1, MAX_WARP);
        vm.warp(block.timestamp + jump);
    }

    /// @dev price movement is wide on purpose. Every invariant is an
    /// internal-consistency property, so they survive the protocol going
    /// economically underwater — which it can, since loss allocation (socializing
    /// bad debt, an insurance fund, etc.) is deliberately out of scope even though
    /// liquidation itself now runs. Bad debt reached this way is expected, not a
    /// finding.
    function oracle_setPrice(uint8 tokenSeed, uint256 priceSeed) public updateGhosts {
        MockV3Aggregator feed = _getFeed(tokenSeed);
        int256 initial = tokenSeed % 2 == 0 ? WETH_INITIAL_PRICE : USDC_INITIAL_PRICE;

        uint256 newPrice = between(priceSeed, uint256(initial) / 100, uint256(initial) * 100);
        feed.updateAnswer(int256(newPrice));
    }
}
