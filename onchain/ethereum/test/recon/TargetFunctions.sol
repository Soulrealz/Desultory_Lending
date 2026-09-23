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

    /// @dev matches Desultory's own SECONDS_PER_YEAR; used to re-derive an accrual bound
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

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

    /**
     * @dev pick a position that actually carries DUSD debt, scanning from `seed`; returns 0
     * when none does.
     *
     * Redemption needs FOUR things true at once — a position with DUSD debt, that position
     * healthy, that position holding the collateral asset named, and the caller holding
     * DUSD. Drawing each of the four independently from a seed made the conjunction so rare
     * that the real call fired zero times across hundreds of thousands of generated calls.
     * Scanning for a candidate is clamping, in the same spirit as _borrowCapacityInToken:
     * it changes which legal call is made, never which calls are legal. Every precondition
     * below is still asserted against the chosen position, the health gate included.
     */
    function _positionWithDusdDebt(uint8 seed, uint256 preferBelow) internal view returns (uint256) {
        uint256 n = positionIds.length;

        // first pass: a position the redeemer could OVER-pay, i.e. one owing less than the
        // redeemer holds. That is the only state in which a legal amount can exceed the
        // debt, and therefore the only state from which _redeem's clamp-to-debt branch is
        // reachable at all. It is not a thumb on the scale for that branch: the amount is
        // still drawn uniformly across the whole balance below, so a partial fill against
        // the same position is just as likely as an over-payment.
        for (uint256 i = 0; i < n; i++) {
            uint256 id = positionIds[(uint256(seed) + i) % n];
            uint256 owed = desultory.getPositionDusdDebt(id);
            if (owed > 0 && owed < preferBelow) {
                return id;
            }
        }

        for (uint256 i = 0; i < n; i++) {
            uint256 id = positionIds[(uint256(seed) + i) % n];
            if (desultory.getPositionDusdDebt(id) > 0) {
                return id;
            }
        }
        return 0;
    }

    /// @dev token slot the position holds collateral in, scanning from `seed`; returns
    /// tokens.length when it holds neither.
    function _collateralSlot(uint256 positionId, uint8 seed) internal view returns (uint256) {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 slot = (uint256(seed) + i) % tokens.length;
            if (desultory.getPositionCollateralForToken(positionId, tokens[slot]) > 0) {
                return slot;
            }
        }
        return tokens.length;
    }

    /// @dev an actor holding DUSD, scanning from `seed`; address(0) when none does.
    /// DUSD only ever reaches an actor, through desultory_borrowDUSD.
    function _dusdHolder(uint8 seed) internal view returns (address) {
        for (uint256 i = 0; i < actors.length; i++) {
            address who = actors[(uint256(seed) + i) % actors.length];
            if (dusd.balanceOf(who) > 0) {
                return who;
            }
        }
        return address(0);
    }

    /// @dev redemption. The redeemer burns DUSD and receives collateral, so the DUSD leg
    /// is a burn (ghostDusdBurned) and the collateral leg is a transfer out (ghostPaidOut).
    ///
    /// The burned amount is read from the supply delta rather than from `amount`: _redeem
    /// clamps to the position's debt AND to the capped collateral, so the requested figure
    /// routinely overstates what was actually burned, and crediting it would break
    /// property_dusdSupplyMatchesAuthorization on the first partial fill.
    ///
    /// The redeemer is not `liquidator` — liquidator is only ever funded with pool tokens
    /// (see Setup.sol), never DUSD, so a precondition on its DUSD balance would always
    /// fail and this target would be dead. DUSD only ever reaches an actor, via
    /// desultory_borrowDUSD, so the redeemer is an actor that actually holds some
    /// (_dusdHolder), chosen before the target position so the amount can be bounded
    /// against a real balance. Redeeming against one's own position is legal and
    /// deliberately not excluded.
    function desultory_redeem(uint8 redeemerSeed, uint8 positionSeed, uint8 collatSeed, uint256 amount)
        public
        updateGhosts
    {
        precondition(positionIds.length > 0);

        address redeemer = _dusdHolder(redeemerSeed);
        precondition(redeemer != address(0));
        uint256 balance = dusd.balanceOf(redeemer);
        precondition(balance > 0);

        uint256 positionId = _positionWithDusdDebt(positionSeed, balance);
        precondition(positionId != 0);

        // only drive the path the engine is specified for; an unhealthy position reverting
        // is correct behaviour, not a finding
        precondition(desultory.healthFactor(positionId) >= 1e18);

        uint256 debt = desultory.getPositionDusdDebt(positionId);
        precondition(debt > 0);

        uint256 slot = _collateralSlot(positionId, collatSeed);
        precondition(slot < tokens.length);
        MockERC20 collatToken = MockERC20(tokens[slot]);
        precondition(desultory.getPositionCollateralForToken(positionId, address(collatToken)) > 0);

        // Bounded by the redeemer's BALANCE, deliberately not by min(debt, balance). _redeem
        // clamps dusdAmount down to the position's debt and then re-clamps it down again
        // from the capped collateral, and a bound that could never exceed the debt left both
        // of those branches unexecutable. What the burn actually needs is that the FINAL
        // figure fits the balance, and the final figure is at most min(amount, debt) <=
        // balance for any amount <= balance — so asking for more than is owed is both legal
        // (the engine is specified to fill partially rather than revert) and always payable.
        amount = between(amount, 1, balance);

        uint256 redeemerCollatBefore = collatToken.balanceOf(redeemer);
        uint256 supplyBefore = dusd.totalSupply();

        vm.prank(redeemer);
        desultory.redeem(positionId, address(collatToken), amount);

        uint256 burned = supplyBefore - dusd.totalSupply();
        uint256 received = collatToken.balanceOf(redeemer) - redeemerCollatBefore;

        ghostPaidOut[slot] += received;
        ghostDusdBurned += burned;

        // The redeemer must never receive more USD of collateral than the DUSD they burned
        // — that difference IS the redemption fee, and its sign is the whole economic
        // guarantee. Asserted instead of "redemption never lowers the target's health
        // factor": health factor is a function of the indices, and redeem() accrues
        // internally, so a before/after comparison straddles an accrual boundary and
        // attributes realized interest to the redemption. This invariant compares two
        // figures produced by the same call, so no amount of elapsed time can perturb it.
        // The health-factor property is covered by testRedeemImprovesTheTargetHealthFactor
        // in test/Desultory.t.sol, where no time passes between the snapshot and the call.
        gte(burned, desultory.getValueUSD(address(collatToken), received), "redeemer received more than they burned");
    }

    /// @dev the backstopped redemption path. Same ghost handling and same redeemer
    /// selection as desultory_redeem — the reserve commit moves no tokens, so only the
    /// collateral payout and the burn show up.
    function desultory_redeemWithBackstop(uint8 redeemerSeed, uint8 positionSeed, uint8 collatSeed, uint256 amount)
        public
        updateGhosts
    {
        precondition(positionIds.length > 0);

        address redeemer = _dusdHolder(redeemerSeed);
        precondition(redeemer != address(0));
        uint256 balance = dusd.balanceOf(redeemer);
        precondition(balance > 0);

        uint256 positionId = _positionWithDusdDebt(positionSeed, balance);
        precondition(positionId != 0);

        precondition(desultory.healthFactor(positionId) >= 1e18);

        uint256 debt = desultory.getPositionDusdDebt(positionId);
        precondition(debt > 0);

        uint256 slot = _collateralSlot(positionId, collatSeed);
        precondition(slot < tokens.length);
        MockERC20 collatToken = MockERC20(tokens[slot]);
        precondition(desultory.getPositionCollateralForToken(positionId, address(collatToken)) > 0);

        // see desultory_redeem: bounded by balance so the clamp-to-debt branch is reachable
        amount = between(amount, 1, balance);

        uint256 redeemerCollatBefore = collatToken.balanceOf(redeemer);
        uint256 supplyBefore = dusd.totalSupply();

        vm.prank(redeemer);
        desultory.redeemWithBackstop(positionId, address(collatToken), amount);

        uint256 burned = supplyBefore - dusd.totalSupply();
        uint256 received = collatToken.balanceOf(redeemer) - redeemerCollatBefore;

        // received is the redeemer's own balance delta, not the contract's: on the
        // backstop path the fee stays in the contract (booked to reserves), so the
        // contract's balance delta would overstate what the redeemer actually got. The
        // redeemer's delta is what both ghostPaidOut and the assertion below are about,
        // and on this path it is exactly what left the contract — the fee never leaves.
        ghostPaidOut[slot] += received;
        ghostDusdBurned += burned;

        gte(burned, desultory.getValueUSD(address(collatToken), received), "redeemer received more than they burned");
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

        uint256 committed = pool.backstopScaledDeposits * pool.liquidityIndex / WAD;
        precondition(committed > 0);

        // The bound has to survive the accrual releaseBackstop performs on its own way in.
        // getAvailableLiquidity is deposits - debt, and an accrual grows the debt side
        // faster than the deposit side by the reserve cut every single time, so the figure
        // read here is an OVER-estimate of what the call will find: bounding against it
        // reverted Desultory__InsufficientLiquidity on any pool that had accrued since it
        // was last touched, which is most of them. There is no public single-token accrual
        // poke to force the state forward first, and adding one to the protocol to suit a
        // test would be the wrong direction, so bound against a conservative LOWER bound on
        // post-accrual availability instead.
        //
        // accrue() computes factor = rate * dt * WAD / (SECONDS_PER_YEAR * MAX_BPS) and
        // grows borrowIndex by borrowIndex * factor / WAD, both floored, so the debt figure
        // rises by at most debt * rate * dt / (SECONDS_PER_YEAR * MAX_BPS); the two wei
        // cover the round-up on either side of the ceiling division. Deposits can only grow
        // across an accrual — liquidityIndex never decreases and totalScaledDeposits is
        // untouched by accrue() — so subtracting that bound from the pre-accrual figure can
        // only understate what the call will see. `committed` is safe unadjusted for the
        // same reason: the backstop deposit is valued through liquidityIndex and so is
        // never worth less after the accrual than it is here.
        uint256 debt = (pool.totalScaledBorrows * pool.borrowIndex + WAD - 1) / WAD;
        uint256 dt = block.timestamp - pool.lastUpdate;
        uint256 rate = desultory.getBorrowRate(address(token), desultory.getUtilization(address(token)));
        uint256 accrualBound = (debt * rate * dt) / (SECONDS_PER_YEAR * MAX_BPS) + 2;

        uint256 available = desultory.getAvailableLiquidity(address(token));
        precondition(available > accrualBound);
        available -= accrualBound;

        amount = between(amount, 1, committed < available ? committed : available);

        vm.prank(desultory.owner());
        desultory.releaseBackstop(address(token), amount);
    }

    /**
     * @dev deliberately drive one pool into the short state the backstop exists for.
     *
     * Nothing else on this surface reaches it. The backstop only does anything once a
     * pool's debt has caught up with its deposits — _commitBackstop returns early while
     * `debt + want <= deposits` — and a pool only gets there by being borrowed almost dry
     * and then left to accrue, since borrowIndex outruns liquidityIndex by the reserve cut
     * on every accrual. Random borrows sized anywhere in [1, ceiling] essentially never
     * stack up to that, which is why redeemWithBackstop's reserve commit, and
     * releaseBackstop behind it, were dead.
     *
     * This is test/Desultory.t.sol's _saturatedUsdcPool in harness form: draw the pool down
     * to the last thousandth of its available liquidity, then let time run.
     *
     * The thousandth left behind is not timidity, it is the point. Drawing to exactly zero
     * makes reserves and the deposit deficit grow by the same quantity — the reserve cut is
     * precisely what separates the two sides — so _commitBackstop's `need <= deficit` guard
     * fires and the commit buys nothing. Leaving a slice means reserves stay ahead of the
     * deficit by that slice forever after, which is exactly the room a backstopped
     * redemption fills.
     */
    function desultory_saturatePool(uint8 tokenSeed, uint8 positionSeed, uint32 secs) public updateGhosts {
        precondition(positionIds.length > 0);

        MockERC20 token = _getToken(tokenSeed);
        uint256 slot = _tokenSlot(tokenSeed);
        uint256 positionId = _getPosition(positionSeed);

        uint256 liquidity = desultory.getAvailableLiquidity(address(token));
        precondition(liquidity > 0);

        uint256 capacity = _borrowCapacityInToken(positionId, address(token));
        precondition(capacity > 0);

        uint256 ceiling = capacity < liquidity ? capacity : liquidity;
        uint256 drawn = ceiling - ceiling / 1_000;
        precondition(drawn > 0);

        vm.prank(position.ownerOf(positionId));
        desultory.borrow(positionId, address(token), drawn);
        ghostPaidOut[slot] += drawn;

        // and now let the interest run, which is what actually inverts deposits and debt
        uint256 jump = between(uint256(secs), 1, MAX_WARP);
        vm.warp(block.timestamp + jump);

        wethFeed.updateAnswer(wethFeed.latestAnswer());
        usdcFeed.updateAnswer(usdcFeed.latestAnswer());
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

    /**
     * @dev the owner closing an asset to new exposure, or reopening it. Owner-only, and it
     * moves no tokens, so the ghosts must NOT be touched here — same shape as
     * desultory_releaseBackstop.
     *
     * Retirement blocks deposit and borrow only; every unwind path stays open, which is
     * exactly what makes it safe to fuzz alongside the rest of the surface.
     *
     * It must never leave BOTH tokens retired at once. This harness has a fixed two-token
     * set, so that state makes every deposit and borrow revert permanently and the rest of
     * the run explores nothing — retiring one therefore reopens the other.
     */
    function desultory_setTokenRetired(uint8 tokenSeed, bool retired) public updateGhosts {
        MockERC20 token = _getToken(tokenSeed);
        MockERC20 other = _getToken(tokenSeed % 2 == 0 ? 1 : 0);

        vm.prank(desultory.owner());
        desultory.setTokenRetired(address(token), retired);

        if (retired && desultory.isTokenRetired(address(other))) {
            vm.prank(desultory.owner());
            desultory.setTokenRetired(address(other), false);
        }
    }

    /**
     * @dev time passes, and the feeds keep reporting.
     *
     * Every price read goes through OracleLib.staleCheckLatestRoundData, whose TIMEOUT is
     * 3 hours, so a jump of up to MAX_WARP leaves BOTH feeds stale. Without the re-post
     * below, every target that reads a price — borrow, redeem, liquidate, and every
     * health-factor precondition — reverts on staleness for the remainder of the sequence
     * unless the fuzzer happens to draw oracle_setPrice for each of the two tokens before
     * warping again. That is a harness artifact, not a protocol state worth most of the
     * call budget: in production the feeds keep publishing while time passes.
     *
     * The answers are re-posted UNCHANGED, so this moves no price — oracle_setPrice
     * remains the only thing that does. test/Desultory.t.sol's _saturatedUsdcPool does
     * exactly the same thing for exactly the same reason after its 365-day warp.
     */
    function warp(uint32 secs) public updateGhosts {
        uint256 jump = between(uint256(secs), 1, MAX_WARP);
        vm.warp(block.timestamp + jump);

        wethFeed.updateAnswer(wethFeed.latestAnswer());
        usdcFeed.updateAnswer(usdcFeed.latestAnswer());
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
