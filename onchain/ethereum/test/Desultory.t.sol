pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {Desultory} from "../src/Desultory.sol";
import {Position} from "../src/PositionNFT.sol";
import {DUSD} from "../src/DUSD.sol";
import {Deploy} from "../script/Deploy.s.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockV3Aggregator.sol";

contract DesultoryTest is Test {
    Desultory desultory;
    Position position;
    DUSD dusd;
    Deploy deploy;

    address weth;
    address usdc;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address dead = 0x000000000000000000000000000000000000dEaD;

    uint256 constant WAD = 1e18;
    uint16 constant MAX_BPS = 10_000;
    uint16 constant RESERVE_FACTOR = 1_000;

    function setUp() public {
        deploy = new Deploy();
        (address addr1, address addr2, address addr3) = deploy.run();
        desultory = Desultory(addr1);
        position = Position(addr2);
        dusd = DUSD(addr3);

        weth = deploy.getAddrI(0);
        usdc = deploy.getAddrI(1);

        MockERC20(weth).mint(alice, 1_000e18);
        MockERC20(usdc).mint(alice, 100_000e18);
        MockERC20(weth).mint(bob, 1_000e18);
        MockERC20(usdc).mint(bob, 100_000e18);

        vm.startPrank(alice);
        MockERC20(weth).approve(address(desultory), type(uint256).max);
        MockERC20(usdc).approve(address(desultory), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(weth).approve(address(desultory), type(uint256).max);
        MockERC20(usdc).approve(address(desultory), type(uint256).max);
        vm.stopPrank();
    }

    ///////////////////////
    // Deposit Tests
    ///////////////////////

    function testDepositMintsPositionWhenZero() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Desultory.PositionOpened(alice, 1);
        vm.expectEmit(true, true, true, true);
        emit Desultory.Deposit(alice, 1, weth, 1e18);
        desultory.deposit(0, weth, 1e18);

        assertEq(position.ownerOf(1), alice);
        assertEq(desultory.getPositionCollateralForToken(1, weth), 1e18);
        assertEq(MockERC20(weth).balanceOf(address(desultory)), 1e18);

        vm.prank(alice);
        desultory.deposit(1, weth, 2e18);
        assertEq(desultory.getPositionCollateralForToken(1, weth), 3e18);
    }

    function testDepositIntoOthersPositionIsPermissionless() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);

        vm.prank(bob);
        desultory.deposit(1, weth, 1e18);

        assertEq(desultory.getPositionCollateralForToken(1, weth), 2e18);
        assertEq(position.ownerOf(1), alice);
    }

    function testMultiplePositionsPerAddress() public {
        vm.startPrank(alice);
        desultory.deposit(0, weth, 1e18);
        desultory.deposit(0, usdc, 100e18);
        vm.stopPrank();

        assertEq(position.ownerOf(1), alice);
        assertEq(position.ownerOf(2), alice);
        assertEq(desultory.getPositionCollateralForToken(1, weth), 1e18);
        assertEq(desultory.getPositionCollateralForToken(1, usdc), 0);
        assertEq(desultory.getPositionCollateralForToken(2, usdc), 100e18);
        assertEq(desultory.getPositionCollateralForToken(2, weth), 0);
    }

    function testDepositReverts() public {
        vm.startPrank(alice);

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.deposit(0, weth, 0);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.deposit(0, dead, 1);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__PositionDoesNotExist.selector, 42));
        desultory.deposit(42, weth, 1e18);

        vm.stopPrank();
    }

    ///////////////////////
    // Withdraw Tests
    ///////////////////////

    function testWithdrawPartialAndAll() public {
        vm.startPrank(alice);
        desultory.deposit(0, weth, 10e18);

        uint256 balBefore = MockERC20(weth).balanceOf(alice);
        vm.expectEmit(true, true, true, true);
        emit Desultory.Withdrawal(1, weth, 4e18);
        desultory.withdraw(1, weth, 4e18);
        assertEq(MockERC20(weth).balanceOf(alice) - balBefore, 4e18);
        assertEq(desultory.getPositionCollateralForToken(1, weth), 6e18);

        desultory.withdraw(1, weth, type(uint256).max);
        assertEq(desultory.getPositionCollateralForToken(1, weth), 0);
        assertEq(MockERC20(weth).balanceOf(alice), 1_000e18);
        vm.stopPrank();
    }

    function testWithdrawReverts() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.prank(alice);
        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.withdraw(1, weth, 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__NotPositionOwner.selector, 1));
        desultory.withdraw(1, weth, 1e18);

        // LTV violation: 10 WETH = $30k, cap 70% = $21k. Borrow $20k then try
        // to withdraw 5 WETH (post-withdraw cap $10.5k < $20k debt).
        vm.prank(bob);
        desultory.deposit(0, usdc, 20_000e18); // position 2: USDC liquidity
        vm.startPrank(alice);
        desultory.borrow(1, usdc, 20_000e18);
        vm.expectRevert(Desultory.Desultory__WithdrawalWillViolateLTV.selector);
        desultory.withdraw(1, weth, 5e18);
        vm.stopPrank();
    }

    function testWithdrawInsufficientLiquidity() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18); // position 1

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18); // position 2
        desultory.borrow(2, usdc, 5_000e18);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InsufficientLiquidity.selector, usdc));
        desultory.withdraw(1, usdc, type(uint256).max);
    }

    ///////////////////////
    // Borrow Tests
    ///////////////////////

    function testBorrow() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18); // position 1: lender

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18); // position 2: $30k collateral, $21k cap

        uint256 balBefore = MockERC20(usdc).balanceOf(bob);
        vm.expectEmit(true, true, true, true);
        emit Desultory.Borrow(2, usdc, 5_000e18);
        desultory.borrow(2, usdc, 5_000e18);
        vm.stopPrank();

        assertEq(MockERC20(usdc).balanceOf(bob) - balBefore, 5_000e18);
        assertEq(desultory.getPositionBorrowForToken(2, usdc), 5_000e18);
        assertEq(desultory.getUtilization(usdc), 5_000);
        assertEq(desultory.getAvailableLiquidity(usdc), 5_000e18);
    }

    function testBorrowReverts() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18); // position 1

        vm.startPrank(bob);
        desultory.deposit(0, weth, 1e18); // position 2: $3k collateral, $2.1k cap

        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.borrow(2, usdc, 0);

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.borrow(2, dead, 1);

        // liquidity check fires before the LTV check
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InsufficientLiquidity.selector, usdc));
        desultory.borrow(2, usdc, 10_001e18);

        vm.expectRevert(Desultory.Desultory__CollateralValueNotEnough.selector);
        desultory.borrow(2, usdc, 5_000e18); // $5k > $2.1k cap
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__NotPositionOwner.selector, 2));
        desultory.borrow(2, usdc, 1e18);
    }

    ///////////////////////
    // Repay Tests
    ///////////////////////

    function testRepayPartialAndAll() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18);

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18);
        desultory.borrow(2, usdc, 5_000e18);

        vm.expectEmit(true, true, true, true);
        emit Desultory.Repayment(2, usdc, 2_000e18);
        desultory.repay(2, usdc, 2_000e18);
        assertEq(desultory.getPositionBorrowForToken(2, usdc), 3_000e18);

        desultory.repay(2, usdc, type(uint256).max);
        assertEq(desultory.getPositionBorrowForToken(2, usdc), 0);
        assertEq(desultory.getUtilization(usdc), 0);
        vm.stopPrank();
    }

    function testRepayByThirdParty() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18);

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18);
        desultory.borrow(2, usdc, 5_000e18);
        vm.stopPrank();

        // alice repays bob's position — permissionless
        vm.prank(alice);
        desultory.repay(2, usdc, 5_000e18);
        assertEq(desultory.getPositionBorrowForToken(2, usdc), 0);
    }

    function testRepayReverts() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__NoExistingBorrow.selector, usdc));
        desultory.repay(1, usdc, 1e18);
    }

    ///////////////////////
    // Value Tests
    ///////////////////////

    function testGetValueUSDIsNormalizedTo18Decimals() public view {
        // WETH: 18-dec feed at 3000e18; USDC: 8-dec feed at 1e8. Both must
        // come out on the same 1e18-per-dollar scale.
        assertEq(desultory.getValueUSD(weth, 1e18), 3_000e18);
        assertEq(desultory.getValueUSD(usdc, 1e18), 1e18);
        assertEq(desultory.getValueUSD(usdc, 2_500e18), 2_500e18);
    }

    ///////////////////////
    // Interest & Yield Tests
    ///////////////////////

    function testBorrowerOwesInterestAfterTime() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18); // position 1

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18); // position 2
        desultory.borrow(2, usdc, 5_000e18);

        vm.warp(block.timestamp + 365 days);

        // mirror the contract's math: single accrual over 1 year at the rate
        // fixed by utilization at borrow time (U = 50.00%)
        uint256 rate = desultory.getBorrowRate(usdc, 5_000);
        uint256 factor = (rate * uint256(365 days) * WAD) / (uint256(365 days) * MAX_BPS);
        uint256 expectedInterest = (5_000e18 * factor) / WAD;

        uint256 balBefore = MockERC20(usdc).balanceOf(bob);
        desultory.repay(2, usdc, type(uint256).max);
        uint256 paid = balBefore - MockERC20(usdc).balanceOf(bob);
        vm.stopPrank();

        assertApproxEqAbs(paid, 5_000e18 + expectedInterest, 2);
        assertGt(paid, 5_000e18);
        assertEq(desultory.getPositionBorrowForToken(2, usdc), 0);
    }

    function testLenderYieldAndReserves() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18); // position 1: the lender

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18); // position 2: the borrower
        desultory.borrow(2, usdc, 5_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 rate = desultory.getBorrowRate(usdc, 5_000);
        uint256 factor = (rate * uint256(365 days) * WAD) / (uint256(365 days) * MAX_BPS);
        uint256 interest = (5_000e18 * factor) / WAD;
        uint256 expectedReserves = (interest * RESERVE_FACTOR) / MAX_BPS;

        vm.prank(bob);
        desultory.repay(2, usdc, type(uint256).max);

        // lender withdraws principal + 90% of the interest
        uint256 balBefore = MockERC20(usdc).balanceOf(alice);
        vm.prank(alice);
        desultory.withdraw(1, usdc, type(uint256).max);
        uint256 got = MockERC20(usdc).balanceOf(alice) - balBefore;

        assertGt(got, 10_000e18);
        assertApproxEqAbs(got, 10_000e18 + interest - expectedReserves, 2);

        // protocol kept its 10%, and that claim is backed by cash
        Desultory.Pool memory pool = desultory.getPoolInfo(usdc);
        assertApproxEqAbs(pool.reserves, expectedReserves, 2);
        assertGe(MockERC20(usdc).balanceOf(address(desultory)), pool.reserves);
    }

    function testRateIncreasesWithUtilization() public view {
        assertGt(desultory.getBorrowRate(usdc, 8_000), desultory.getBorrowRate(usdc, 1_500));
        assertGt(desultory.getBorrowRate(usdc, 9_900), desultory.getBorrowRate(usdc, 8_000));
    }

    function testNoAccrualWithoutBorrows() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18);

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        desultory.withdraw(1, usdc, type(uint256).max);
        // no borrowers → no yield, principal back exactly
        assertEq(MockERC20(usdc).balanceOf(alice), 100_000e18);
    }

    ///////////////////////
    // NFT Transfer Tests
    ///////////////////////

    function testNftTransferMovesControl() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18); // position 1

        vm.prank(alice);
        position.transferFrom(alice, bob, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__NotPositionOwner.selector, 1));
        desultory.withdraw(1, weth, 1e18);

        uint256 balBefore = MockERC20(weth).balanceOf(bob);
        vm.prank(bob);
        desultory.withdraw(1, weth, 1e18);
        assertEq(MockERC20(weth).balanceOf(bob) - balBefore, 1e18);
    }

    function testUnhealthyPositionTransferReverts() public {
        vm.prank(alice);
        desultory.deposit(0, usdc, 20_000e18); // position 1: liquidity

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18); // position 2: $30k, cap $21k
        desultory.borrow(2, usdc, 20_000e18);
        vm.stopPrank();

        // crash WETH: $3000 → $2000, cap drops to $14k < $20k debt
        MockV3Aggregator(desultory.getPriceFeedForToken(weth)).updateAnswer(2_000e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Position.Position__PositionUnhealthy.selector, 2));
        position.transferFrom(bob, alice, 2);

        // price recovers → transfer goes through, debt travels with the NFT
        MockV3Aggregator(desultory.getPriceFeedForToken(weth)).updateAnswer(3_000e18);
        vm.prank(bob);
        position.transferFrom(bob, alice, 2);
        assertEq(position.ownerOf(2), alice);
        assertEq(desultory.getPositionBorrowForToken(2, usdc), 20_000e18);
    }

    ///////////////////////
    // Health Factor Tests
    ///////////////////////

    function testHealthFactorIsMaxWithNoDebt() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        assertEq(desultory.healthFactor(1), type(uint256).max, "no debt means no risk");
    }

    function testHealthFactorUsesThresholdNotLtv() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18); // 1 WETH @ 3000

        vm.prank(alice);
        desultory.borrowDUSD(1, 2_100e18); // exactly the LTV cap: 3000 * 70%

        // capacity is exhausted, but the seize line is 3000 * 75% = 2250
        assertEq(desultory.userMaxBorrowValueUSD(1), 2_100e18, "at the borrow cap");
        assertEq(desultory.healthFactor(1), (uint256(2_250e18) * 1e18) / 2_100e18, "threshold-weighted");
        assertTrue(desultory.isPositionHealthy(1), "maxed out is not the same as liquidatable");
    }

    function testPositionBecomesLiquidatableOnlyBelowThreshold() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 2_100e18);

        // drop WETH to 2800: seize line is 2800 * 75% = 2100, exactly the debt -> HF == 1
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2800e18);
        assertEq(desultory.healthFactor(1), 1e18, "at the line");
        assertTrue(desultory.isPositionHealthy(1), "at the line is not past it");

        // one more dollar down and it is liquidatable
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2799e18);
        assertLt(desultory.healthFactor(1), 1e18);
        assertFalse(desultory.isPositionHealthy(1), "below the line is liquidatable");
    }

    /// @dev a position between its LTV cap and its liquidation threshold must still be
    /// transferable: it cannot be seized, so there is no liquidator to race.
    function testPositionBetweenLtvAndThresholdIsTransferable() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 2_100e18);

        vm.prank(alice);
        position.transferFrom(alice, bob, 1);
        assertEq(position.ownerOf(1), bob);
    }

    ///////////////////////
    // Fuzz Tests
    ///////////////////////

    /// deposit→withdraw round-trip never pays out more than was put in
    function testFuzzDepositWithdrawNeverProfits(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000e18);

        vm.startPrank(alice);
        desultory.deposit(0, weth, amount);
        uint256 balBefore = MockERC20(weth).balanceOf(alice);
        desultory.withdraw(1, weth, type(uint256).max);
        uint256 got = MockERC20(weth).balanceOf(alice) - balBefore;
        vm.stopPrank();

        assertLe(got, amount);
        assertApproxEqAbs(got, amount, 1);
    }

    /// borrow→warp→repay always costs at least the principal
    function testFuzzBorrowRepayNeverProfits(uint96 rawAmount, uint32 rawTime) public {
        uint256 amount = bound(uint256(rawAmount), 1e6, 5_000e18);
        uint256 timeJump = bound(uint256(rawTime), 1, 730 days);

        vm.prank(alice);
        desultory.deposit(0, usdc, 10_000e18); // position 1

        vm.startPrank(bob);
        desultory.deposit(0, weth, 10e18); // position 2, cap $21k
        desultory.borrow(2, usdc, amount);

        vm.warp(block.timestamp + timeJump);

        uint256 balBefore = MockERC20(usdc).balanceOf(bob);
        desultory.repay(2, usdc, type(uint256).max);
        uint256 paid = balBefore - MockERC20(usdc).balanceOf(bob);
        vm.stopPrank();

        assertGe(paid, amount);
        assertEq(desultory.getPositionBorrowForToken(2, usdc), 0);

        // pool stays solvent: lender claim + reserves never exceed cash + 1 wei dust
        Desultory.Pool memory pool = desultory.getPoolInfo(usdc);
        uint256 lenderClaim = desultory.getPositionCollateralForToken(1, usdc);
        assertLe(lenderClaim + pool.reserves, MockERC20(usdc).balanceOf(address(desultory)) + 1);
    }

    ///////////////////////
    // Scaled Getter Tests
    ///////////////////////

    function testScaledGettersMatchUnscaled() public {
        vm.startPrank(alice);
        desultory.deposit(0, weth, 10e18);
        desultory.borrow(1, weth, 1e18);
        vm.stopPrank();

        // let interest accrue so the indexes diverge from WAD
        vm.warp(block.timestamp + 180 days);
        vm.prank(alice);
        desultory.deposit(1, weth, 1e18);

        Desultory.Pool memory pool = desultory.getPoolInfo(weth);

        uint256 scaledDep = desultory.getScaledDeposit(1, weth);
        uint256 scaledBor = desultory.getScaledBorrow(1, weth);

        assertGt(scaledDep, 0, "scaled deposit should be non-zero");
        assertGt(scaledBor, 0, "scaled borrow should be non-zero");
        assertGt(pool.borrowIndex, WAD, "borrowIndex should have grown");

        // deposits reconstruct with __fromScaledDown, debts with __fromScaledUp
        assertEq(
            scaledDep * pool.liquidityIndex / WAD,
            desultory.getPositionCollateralForToken(1, weth),
            "scaled deposit must reconstruct the unscaled balance"
        );
        assertEq(
            (scaledBor * pool.borrowIndex + WAD - 1) / WAD,
            desultory.getPositionBorrowForToken(1, weth),
            "scaled borrow must reconstruct the unscaled debt"
        );
    }

    ///////////////////////
    // Ownership Tests
    ///////////////////////

    function testOwnerIsSetAndSettersAreGated() public {
        address owner = desultory.owner();
        assertTrue(owner != address(0), "owner must be set");

        vm.prank(owner);
        desultory.setAdapter(address(0xABCD));
        assertEq(desultory.adapter(), address(0xABCD));

        vm.prank(owner);
        desultory.setAllowedDestination(42, true);
        assertTrue(desultory.allowedDestination(42));

        vm.prank(owner);
        desultory.setDusdStabilityFee(250);
        assertEq(desultory.dusdStabilityFeeBps(), 250);
    }

    function testNonOwnerCannotConfigure() public {
        vm.startPrank(alice);
        vm.expectRevert();
        desultory.setAdapter(address(0xABCD));
        vm.expectRevert();
        desultory.setAllowedDestination(42, true);
        vm.expectRevert();
        desultory.setDusdStabilityFee(250);
        vm.stopPrank();
    }

    function testStabilityFeeIsCapped() public {
        vm.prank(desultory.owner());
        vm.expectRevert(Desultory.Desultory__FeeTooHigh.selector);
        desultory.setDusdStabilityFee(10_001);
    }

    ///////////////////////
    // DUSD Debt Tests
    ///////////////////////

    function testBorrowDusdMintsAndRecordsDebt() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        assertEq(dusd.balanceOf(alice), 1_000e18, "DUSD should be minted to borrower");
        assertEq(desultory.getPositionDusdDebt(1), 1_000e18, "debt should be recorded");
    }

    function testDusdDebtCountsTowardHealth() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18); // 1 WETH @ 3000, LTV 70 => 2100 USD capacity

        uint256 before = desultory.userBorrowedAmountUSD(1);
        assertEq(before, 0);

        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        assertEq(desultory.userBorrowedAmountUSD(1), 1_000e18, "DUSD debt must count as USD debt");
        assertTrue(desultory.isPositionHealthy(1));
    }

    function testBorrowDusdBeyondCapacityReverts() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18); // 2100 USD capacity

        vm.prank(alice);
        vm.expectRevert(Desultory.Desultory__CollateralValueNotEnough.selector);
        desultory.borrowDUSD(1, 3_000e18);
    }

    function testOnlyPositionOwnerCanBorrowDusd() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__NotPositionOwner.selector, uint256(1)));
        desultory.borrowDUSD(1, 1e18);
    }

    function testDusdStabilityFeeAccruesEntirelyToReserves() public {
        vm.prank(desultory.owner());
        desultory.setDusdStabilityFee(1_000); // 10% annual

        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        uint256 reservesBefore = desultory.dusdReserves();

        vm.warp(block.timestamp + 365 days);
        desultory.accrueDusd();

        uint256 debtAfter = desultory.getPositionDusdDebt(1);
        uint256 feeCharged = debtAfter - 1_000e18;

        assertApproxEqRel(debtAfter, 1_100e18, 1e15, "10% annual fee on 1000 DUSD");
        assertEq(
            desultory.dusdReserves() - reservesBefore,
            feeCharged,
            "entire fee must go to reserves; there are no DUSD depositors"
        );
    }

    function testAccrualNeverDistributesMoreThanCharged() public {
        vm.prank(desultory.owner());
        desultory.setDusdStabilityFee(500);

        vm.prank(alice);
        desultory.deposit(0, weth, 100e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 50_000e18);

        for (uint256 i = 0; i < 6; i++) {
            uint256 debtBefore = desultory.getPositionDusdDebt(1);
            uint256 resBefore = desultory.dusdReserves();

            vm.warp(block.timestamp + 97 days + 1337);
            desultory.accrueDusd();

            uint256 charged = desultory.getPositionDusdDebt(1) - debtBefore;
            uint256 distributed = desultory.dusdReserves() - resBefore;
            assertLe(distributed, charged, "must never distribute more than charged");
        }
    }

    function testRepayDusdBurnsAndClearsDebt() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        vm.prank(alice);
        desultory.repayDUSD(1, 1_000e18);

        assertEq(dusd.balanceOf(alice), 0, "DUSD should be burned on repay");
        assertEq(desultory.getPositionDusdDebt(1), 0, "debt should be cleared");
    }

    function testRepayDusdIsPermissionless() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        // bob acquires DUSD and settles alice's debt
        vm.prank(alice);
        dusd.transfer(bob, 1_000e18);

        vm.prank(bob);
        desultory.repayDUSD(1, 1_000e18);

        assertEq(desultory.getPositionDusdDebt(1), 0);
    }

    ///////////////////////
    // Risk Parameter Tests
    ///////////////////////

    function testRiskParametersAreStored() public view {
        Desultory.Collateral memory w = desultory.getTokenInfo(weth);
        assertEq(w.ltvRatio, 70, "weth ltv");
        assertEq(w.liquidationThreshold, 75, "weth threshold");
        assertEq(w.liquidationBonusBps, 1_000, "weth bonus");

        Desultory.Collateral memory u = desultory.getTokenInfo(usdc);
        assertEq(u.ltvRatio, 85, "usdc ltv");
        assertEq(u.liquidationThreshold, 90, "usdc threshold");
        assertEq(u.liquidationBonusBps, 500, "usdc bonus");
    }

    function testConstructorRejectsThresholdBelowLtv() public {
        Desultory.TokenConfig[] memory configs = new Desultory.TokenConfig[](1);
        configs[0] = Desultory.TokenConfig({
            token: weth,
            priceFeed: desultory.getPriceFeedForToken(weth),
            feedDecimals: 18,
            tokenDecimals: 18,
            ltvRatio: 80,
            liquidationThreshold: 75, // below ltv — must revert
            liquidationBonusBps: 1_000,
            borrowRate: 400
        });

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, weth));
        new Desultory(configs, address(position), address(dusd));
    }

    function testConstructorRejectsExcessiveBonus() public {
        Desultory.TokenConfig[] memory configs = new Desultory.TokenConfig[](1);
        configs[0] = Desultory.TokenConfig({
            token: weth,
            priceFeed: desultory.getPriceFeedForToken(weth),
            feedDecimals: 18,
            tokenDecimals: 18,
            ltvRatio: 70,
            liquidationThreshold: 75,
            liquidationBonusBps: 2_001, // above MAX_BONUS_BPS
            borrowRate: 400
        });

        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, weth));
        new Desultory(configs, address(position), address(dusd));
    }

    ///////////////////////
    // Liquidation Tests
    ///////////////////////

    /// @dev puts position 1 under water: alice deposits 1 WETH, borrows to the LTV cap,
    /// then WETH falls far enough to cross the 75% threshold.
    function _makeLiquidatable() internal {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 2_100e18);

        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2500e18); // seize line 1875 < 2100
        assertFalse(desultory.isPositionHealthy(1), "fixture must be liquidatable");
    }

    /// @dev bob needs DUSD to repay alice's DUSD debt; he borrows his own against WETH
    function _fundBobWithDusd(uint256 amount) internal {
        vm.prank(bob);
        desultory.deposit(0, weth, 100e18);
        vm.prank(bob);
        desultory.borrowDUSD(2, amount);
    }

    /// @dev leaves the USDC pool with zero available liquidity but non-zero cash, and
    /// position 1 (alice, USDC collateral, WETH debt) deeply liquidatable.
    ///
    /// available = max(0, deposits - debt) and cash = deposits + reserves - debt, so
    /// available = max(0, cash - reserves). Lending out all but 1k of the pool and then
    /// letting a year of interest accrue puts reserves well above that 1k, which drives
    /// available to zero while 1k of real USDC is still sitting in the contract. That 1k is
    /// exactly what the backstop exists to unlock.
    function _saturatedUsdcPool() internal {
        MockERC20(usdc).mint(alice, 200_000e18);

        vm.prank(alice);
        desultory.deposit(0, usdc, 200_000e18); // position 1

        vm.prank(bob);
        desultory.deposit(0, weth, 1_000e18); // position 2

        vm.prank(alice);
        desultory.borrow(1, weth, 50e18); // alice owes WETH against USDC collateral

        vm.prank(bob);
        desultory.borrow(2, usdc, 199_000e18); // 1k of USDC cash left behind

        vm.warp(block.timestamp + 365 days); // interest -> reserves on the next accrual

        // refresh the USDC feed's timestamp so the health check below doesn't revert on
        // staleness (OracleLib.TIMEOUT is 3 hours); the price itself is unchanged.
        MockV3Aggregator(deploy.getFeedI(1)).updateAnswer(100_000_000);
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(30_000e18); // WETH up, alice underwater
        assertLt(desultory.healthFactor(1), 1e18, "alice must be liquidatable");

        // persist the year of accrual on both pools now, via trivial deposits. A test that
        // only ever triggers accrual through a call expected to revert would read pre-warp
        // figures afterward — a revert unwinds every storage write made during that call,
        // including its own accrual. Likewise a "before" snapshot taken here (e.g. a
        // position's WETH debt) must reflect the post-warp state, or a later comparison
        // against an "after" figure read past a real accrual is comparing apples to
        // oranges. These deposits are economically negligible against the pools' balances
        // (1 wei rounds to a zero scaled credit and reverts, so small whole-token amounts
        // are used instead).
        MockERC20(usdc).mint(alice, 1e18);
        vm.prank(alice);
        desultory.deposit(1, usdc, 1e18);

        MockERC20(weth).mint(bob, 1e18);
        vm.prank(bob);
        desultory.deposit(2, weth, 1e18);
    }

    /// @dev a liquidator holding WETH, approved, ready to repay alice's WETH debt
    function _wethLiquidator() internal returns (address who) {
        who = makeAddr("backstopLiquidator");
        MockERC20(weth).mint(who, 1_000e18);
        vm.prank(who);
        MockERC20(weth).approve(address(desultory), type(uint256).max);
    }

    function testOrdinaryLiquidationCannotFillAgainstASaturatedPool() public {
        _saturatedUsdcPool();
        address who = _wethLiquidator();

        vm.prank(who);
        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.liquidate(1, weth, usdc, 10e18);

        assertEq(desultory.getAvailableLiquidity(usdc), 0, "pool must be saturated for this to mean anything");
        assertGt(desultory.getPoolInfo(usdc).reserves, 0, "and must hold reserves the backstop can draw on");
    }

    function testBackstopFillsAgainstASaturatedPool() public {
        _saturatedUsdcPool();
        address who = _wethLiquidator();

        uint256 usdcBefore = MockERC20(usdc).balanceOf(who);
        uint256 debtBefore = desultory.getPositionBorrowForToken(1, weth);

        vm.prank(who);
        desultory.liquidateWithBackstop(1, weth, usdc, 10e18);

        assertGt(MockERC20(usdc).balanceOf(who) - usdcBefore, 0, "liquidator was actually paid");
        assertLt(desultory.getPositionBorrowForToken(1, weth), debtBefore, "debt was actually retired");
        assertGt(desultory.getPoolInfo(usdc).backstopScaledDeposits, 0, "reserves were committed");
    }

    /// @dev the backstop must not leave the pool materially under-collateralized. Within a
    /// couple of wei it can, and does: _seizeCollateral removes the scaled deposit with
    /// __toScaledUp while the availability bound is computed in token units, so a seizure
    /// that exactly saturates the cap lands a wei or two short. That seam is documented and
    /// deliberately unpatched — see Known limitations in docs/Protocol/Liquidations.md; the
    /// obvious fix is an unexplained -1.
    ///
    /// The backstop meets that seam on EVERY call rather than occasionally, because it sets
    /// seizeCap to exactly the availability it just unlocked. So this asserts the bound that
    /// actually matters: the shortfall is dust, not a deficit. The invariant it protects,
    /// property_borrowIndexOutpacesLiquidityIndex, needs roughly a 10% gap to trip.
    function testBackstopLeavesDepositsCoveringDebtWithinRoundingDust() public {
        _saturatedUsdcPool();
        address who = _wethLiquidator();

        vm.prank(who);
        desultory.liquidateWithBackstop(1, weth, usdc, 10e18);

        Desultory.Pool memory pool = desultory.getPoolInfo(usdc);
        uint256 deposits = pool.totalScaledDeposits * pool.liquidityIndex / 1e18;
        uint256 debt = (pool.totalScaledBorrows * pool.borrowIndex + 1e18 - 1) / 1e18;

        uint256 shortfall = debt > deposits ? debt - deposits : 0;
        assertLe(shortfall, 10, "deposits must cover debt to within rounding dust");

        assertLe(uint256(desultory.getUtilization(usdc)), 10_000, "utilization must not exceed 100%");
    }

    function testBackstopPreservesCustody() public {
        _saturatedUsdcPool();
        address who = _wethLiquidator();

        vm.prank(who);
        desultory.liquidateWithBackstop(1, weth, usdc, 10e18);

        Desultory.Pool memory pool = desultory.getPoolInfo(usdc);
        uint256 deposits = pool.totalScaledDeposits * pool.liquidityIndex / 1e18;
        uint256 debt = (pool.totalScaledBorrows * pool.borrowIndex + 1e18 - 1) / 1e18;
        uint256 balance = MockERC20(usdc).balanceOf(address(desultory));

        // the same identity property_custodyReconciles asserts
        assertGe(balance + debt, deposits + pool.reserves, "custody must still cover obligations");
    }

    function testBackstopWithNoReservesBehavesLikeOrdinaryLiquidation() public {
        // no warp, so no interest and no reserves; the whole pool is lent out, so there is
        // no cash either and the backstop has nothing to unlock
        MockERC20(usdc).mint(alice, 200_000e18);

        vm.prank(alice);
        desultory.deposit(0, usdc, 200_000e18);
        vm.prank(bob);
        desultory.deposit(0, weth, 1_000e18);
        vm.prank(alice);
        desultory.borrow(1, weth, 50e18);
        vm.prank(bob);
        desultory.borrow(2, usdc, 200_000e18);

        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(30_000e18);
        assertLt(desultory.healthFactor(1), 1e18, "alice must be liquidatable");
        assertEq(desultory.getPoolInfo(usdc).reserves, 0, "fixture must have no reserves");

        address who = _wethLiquidator();

        vm.prank(who);
        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.liquidateWithBackstop(1, weth, usdc, 10e18);

        assertEq(desultory.getPoolInfo(usdc).backstopScaledDeposits, 0, "nothing to commit, nothing committed");
    }

    function testBackstopCommitsNothingOnALiquidPool() public {
        _makeLiquidatable();
        _fundBobWithDusd(2_000e18);

        // 1 WETH of collateral against 101 WETH of deposits and zero WETH borrows: the pool
        // is liquid with room to spare, so _commitBackstop returns at its FIRST branch
        // (need = debt + want <= deposits) without looking at reserves at all. Nothing here
        // exercises the sizing against seizeCap — for that see
        // testBackstopCommitsSizedToCollateralWhenBothBind.
        uint256 liquidityBefore = desultory.getAvailableLiquidity(weth);

        vm.prank(bob);
        desultory.liquidateWithBackstop(1, address(dusd), weth, 500e18);

        // the pool must actually have been liquid relative to the seizure, or the assertion
        // below proves nothing: 500 DUSD repaid at 2500/WETH with a 1000bps bonus seizes
        // about 0.22 WETH, far inside available liquidity.
        assertGt(liquidityBefore, 1e18, "fixture must leave the pool liquid past the seizure");
        assertEq(desultory.getPoolInfo(weth).backstopScaledDeposits, 0, "a liquid pool commits nothing");
    }

    /// @dev the case the test above does NOT cover: collateral binds AND the pool is short.
    /// alice keeps most of her collateral in WETH and only a sliver in USDC, so a USDC
    /// seizure is capped far below what the repayment warrants, while the USDC pool itself
    /// is saturated and holds reserves. A commit must still happen — sizing against
    /// seizeCap bounds it, it does not suppress it — and must be sized to the reduced cap.
    function testBackstopCommitsSizedToCollateralWhenBothBind() public {
        // alice: 5 WETH of real collateral plus a 100 USDC sliver (position 1)
        vm.prank(alice);
        desultory.deposit(0, weth, 5e18);
        vm.prank(alice);
        desultory.deposit(1, usdc, 100e18);

        // carol supplies the USDC pool (position 2)
        address carol = makeAddr("carol");
        MockERC20(usdc).mint(carol, 200_000e18);
        vm.startPrank(carol);
        MockERC20(usdc).approve(address(desultory), type(uint256).max);
        desultory.deposit(0, usdc, 200_000e18);
        vm.stopPrank();

        // dave drains it to ~99.5% utilization, leaving 1k of USDC cash behind (position 3)
        address dave = makeAddr("dave");
        MockERC20(weth).mint(dave, 1_000e18);
        vm.startPrank(dave);
        MockERC20(weth).approve(address(desultory), type(uint256).max);
        desultory.deposit(0, weth, 1_000e18);
        desultory.borrow(3, usdc, 199_000e18);
        vm.stopPrank();

        // alice borrows DUSD against the pair, inside her LTV cap (5 * 3000 * 0.7 + 100 *
        // 0.85 = 10_585)
        vm.prank(alice);
        desultory.borrowDUSD(1, 10_000e18);

        vm.warp(block.timestamp + 365 days); // interest -> reserves on the next accrual

        MockV3Aggregator(deploy.getFeedI(1)).updateAnswer(100_000_000); // refresh, same price
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2500e18); // WETH down, alice under
        assertLt(desultory.healthFactor(1), 1e18, "alice must be liquidatable");

        vm.prank(dave);
        desultory.borrowDUSD(3, 1_000e18); // dave is the liquidator and needs DUSD to repay

        // persist the year of accrual on the USDC pool before snapshotting it: a figure read
        // pre-accrual is not comparable with one read after the liquidation's own accrue()
        MockERC20(usdc).mint(carol, 1e18);
        vm.prank(carol);
        desultory.deposit(2, usdc, 1e18);

        Desultory.Pool memory before = desultory.getPoolInfo(usdc);
        uint256 depositsBefore = before.totalScaledDeposits * before.liquidityIndex / 1e18;
        uint256 debtBefore = (before.totalScaledBorrows * before.borrowIndex + 1e18 - 1) / 1e18;
        uint256 deficit = debtBefore > depositsBefore ? debtBefore - depositsBefore : 0;

        uint256 capBefore = desultory.getPositionCollateralForToken(1, usdc);
        // 500 DUSD repaid at $1 against USDC's 500bps bonus, USDC at $1. Kept under the
        // ~1.1k of USDC cash the fixture leaves in the pool, since reserves exceed the
        // deposit deficit by exactly that cash — a larger figure would make reserves the
        // binding constraint and the final bound would stop discriminating.
        uint256 seizeRequested = 525e18;

        // the two preconditions this test is named for. Without the first, collateral does
        // not bind; without the second, reserves are what limits the commit and the bound
        // asserted at the end would hold for any sizing at all.
        assertLt(capBefore, seizeRequested, "collateral must be what binds the seizure");
        assertGt(before.reserves, deficit + seizeRequested, "reserves must not be the binding constraint");
        assertEq(desultory.getAvailableLiquidity(usdc), 0, "the pool must be short of liquidity");

        vm.prank(dave);
        desultory.liquidateWithBackstop(1, address(dusd), usdc, 500e18);

        Desultory.Pool memory afterPool = desultory.getPoolInfo(usdc);
        uint256 committed = afterPool.backstopScaledDeposits * afterPool.liquidityIndex / 1e18;

        // it fired: a short pool commits even though collateral is what binds
        assertGt(committed, 0, "the backstop must commit when the pool is short");
        // and it was sized to the reduced cap: need = (debt - deposits) + seizeCap
        assertLe(committed, deficit + capBefore, "commit must be bounded by the reduced cap");
        // which is strictly less than what sizing against the requested seize would have
        // committed, and reserves would have covered that larger figure
        assertLt(committed, deficit + seizeRequested, "commit must not be sized to the requested seize");
    }

    /// @dev drive a backstop commit, then hand back how much is committed in token units
    function _commitViaLiquidation() internal returns (uint256 committed) {
        _saturatedUsdcPool();
        address who = _wethLiquidator();

        vm.prank(who);
        desultory.liquidateWithBackstop(1, weth, usdc, 10e18);

        Desultory.Pool memory pool = desultory.getPoolInfo(usdc);
        committed = pool.backstopScaledDeposits * pool.liquidityIndex / 1e18;
        assertGt(committed, 0, "fixture must have committed something");
    }

    function testReleaseBackstopIsBlockedWhileThePoolIsStillSaturated() public {
        uint256 committed = _commitViaLiquidation();

        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InsufficientLiquidity.selector, usdc));
        desultory.releaseBackstop(usdc, committed);
    }

    function testReleaseBackstopSucceedsOnceLiquidityReturns() public {
        // the fixture's return is deliberately dropped here: this test releases
        // type(uint256).max rather than the snapshotted figure (see below)
        _commitViaLiquidation();

        // bob repays his USDC debt, freeing the pool
        vm.prank(bob);
        desultory.repay(2, usdc, 150_000e18);

        uint256 reservesBefore = desultory.getPoolInfo(usdc).reserves;

        // type(uint256).max, not `committed`: bob's repay accrued the pool, so the backstop
        // deposit has grown past the figure snapshotted in the fixture. The full-balance
        // shortcut is the only way to land on exactly zero.
        vm.prank(desultory.owner());
        desultory.releaseBackstop(usdc, type(uint256).max);

        assertEq(desultory.getPoolInfo(usdc).backstopScaledDeposits, 0, "backstop fully released");
        assertGt(desultory.getPoolInfo(usdc).reserves, reservesBefore, "released into reserves");
    }

    function testReleaseBackstopMovesNoTokens() public {
        uint256 committed = _commitViaLiquidation();

        vm.prank(bob);
        desultory.repay(2, usdc, 150_000e18);

        uint256 balanceBefore = MockERC20(usdc).balanceOf(address(desultory));

        vm.prank(desultory.owner());
        desultory.releaseBackstop(usdc, committed);

        assertEq(
            MockERC20(usdc).balanceOf(address(desultory)), balanceBefore, "release is bookkeeping, not a transfer"
        );
    }

    function testReleasedBackstopExitsThroughWithdrawReserves() public {
        uint256 committed = _commitViaLiquidation();

        vm.prank(bob);
        desultory.repay(2, usdc, 150_000e18);

        vm.startPrank(desultory.owner());
        desultory.releaseBackstop(usdc, type(uint256).max);

        // the committed capital came back with the interest it earned while deposited
        uint256 reserves = desultory.getPoolInfo(usdc).reserves;
        assertGe(reserves, committed, "released capital is at least what went in");

        address treasury = makeAddr("treasury");
        desultory.withdrawReserves(usdc, treasury, committed);
        vm.stopPrank();

        assertEq(MockERC20(usdc).balanceOf(treasury), committed, "the one exit still works");
    }

    function testReleaseBackstopIsOwnerGated() public {
        uint256 committed = _commitViaLiquidation();

        vm.prank(alice);
        vm.expectRevert();
        desultory.releaseBackstop(usdc, committed);
    }

    function testReleaseBackstopRejectsAnEmptyBackstop() public {
        vm.prank(desultory.owner());
        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.releaseBackstop(usdc, 1e18);
    }

    function testHealthyPositionCannotBeLiquidated() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        _fundBobWithDusd(1_000e18);

        assertGe(desultory.healthFactor(1), 1e18, "fixture must be healthy");

        vm.prank(bob);
        vm.expectRevert(); // Desultory__NotLiquidatable; the HF it carries is read inside the call
        desultory.liquidate(1, address(dusd), weth, 100e18);
    }

    function testLiquidationRepaysDebtAndSeizesCollateralWithBonus() public {
        _makeLiquidatable();
        _fundBobWithDusd(2_000e18);

        uint256 repay = 500e18; // well under the 50% close factor of 2100
        uint256 bobWethBefore = MockERC20(weth).balanceOf(bob);

        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, repay);

        // debt fell by exactly the repayment
        assertEq(desultory.getPositionDusdDebt(1), 2_100e18 - repay, "debt retired");

        // seizure is repay * 1.10 in USD, at 2500/WETH, minus the protocol's 30% of the bonus
        uint256 seizeUSD = (repay * 11_000) / 10_000;          // 550 USD
        uint256 seizeWeth = (seizeUSD * 1e18) / 2500e18;       // 0.22 WETH
        uint256 baseWeth = (repay * 1e18) / 2500e18;           // 0.20 WETH
        uint256 cut = ((seizeWeth - baseWeth) * 3_000) / 10_000;

        // approximate, not exact: the contract derives `base` through repayFromSeize (which
        // ceils) while this test derives it straight from the price, so the two can differ by
        // a wei or two. The bonus direction and the split are what matter here.
        assertApproxEqAbs(MockERC20(weth).balanceOf(bob) - bobWethBefore, seizeWeth - cut, 1e12, "liquidator payout");
        assertApproxEqAbs(desultory.getPoolInfo(weth).reserves, cut, 1e12, "protocol cut to reserves");
        assertApproxEqAbs(desultory.getPositionCollateralForToken(1, weth), 1e18 - seizeWeth, 2, "collateral seized");
    }

    function testLiquidationClampsToCloseFactor() public {
        _makeLiquidatable();
        _fundBobWithDusd(3_000e18);

        // HF here is 1875/2100 = 0.892 -> below 0.95, so a FULL close is allowed
        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 5_000e18); // asks for more than the debt

        assertEq(desultory.getPositionDusdDebt(1), 0, "deep band allows a full close");
    }

    function testNormalBandAllowsOnlyHalf() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 2_100e18);

        // 2800 -> seize line 2100, HF == 1.0; nudge to 2790 -> HF 0.996, normal band
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2790e18);
        assertLt(desultory.healthFactor(1), 1e18);
        assertGt(desultory.healthFactor(1), 0.95e18);

        _fundBobWithDusd(3_000e18);

        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 5_000e18);

        assertEq(desultory.getPositionDusdDebt(1), 1_050e18, "only half may be closed");
    }

    function testLiquidatorWithoutApprovalReverts() public {
        // token debt, not DUSD: alice borrows usdc against weth
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        vm.prank(bob);
        desultory.deposit(0, usdc, 50_000e18); // supply the pool
        vm.prank(alice);
        desultory.borrow(1, usdc, 2_000e18);

        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2500e18);
        assertFalse(desultory.isPositionHealthy(1));

        address carol = makeAddr("carol");
        MockERC20(usdc).mint(carol, 10_000e18); // has the balance, never approved

        vm.prank(carol);
        vm.expectRevert();
        desultory.liquidate(1, usdc, weth, 500e18);

        // and nothing moved: the old engine would have paid him from protocol funds
        assertEq(desultory.getPositionBorrowForToken(1, usdc), 2_000e18, "debt untouched");
        assertEq(MockERC20(weth).balanceOf(carol), 0, "no collateral leaked");
    }

    function testLiquidationAccruesBeforeEvaluating() public {
        _makeLiquidatable();
        _fundBobWithDusd(3_000e18);

        vm.warp(block.timestamp + 365 days);
        // refresh the feed's timestamp so the health check below doesn't revert on
        // staleness (OracleLib.TIMEOUT is 3 hours); the price itself is unchanged.
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2500e18);

        uint256 staleDebt = 2_100e18;
        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 100e18);

        // the 2% stability fee must have been charged before the repayment was applied
        assertGt(desultory.getPositionDusdDebt(1) + 100e18, staleDebt, "accrual ran first");
    }

    function testLiquidationEmitsTheEvent() public {
        _makeLiquidatable();
        _fundBobWithDusd(2_000e18);

        vm.recordLogs();
        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 500e18);

        // one Liquidation event, from Desultory
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Desultory.Liquidation.selector) {
                found = true;
            }
        }
        assertTrue(found, "Liquidation event must be emitted");
    }

    /// @dev collateral crashes far enough that the full close factor cannot be covered
    function testSeizureClampsToCollateralHeldAndBackSolvesRepayment() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 2_100e18);

        // 1 WETH now worth 1000; debt is 2100 -> collateral cannot cover it
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(1000e18);

        _fundBobWithDusd(3_000e18);

        uint256 bobDusdBefore = dusd.balanceOf(bob);

        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 2_100e18); // ask for everything

        // seizure capped at the 1 WETH actually held
        assertEq(desultory.getPositionCollateralForToken(1, weth), 0, "all collateral taken");

        // and the repayment was scaled back to match: at 1000/WETH with a 10% bonus,
        // 1 WETH of seizure corresponds to ~909 DUSD of debt, not 2100
        uint256 paid = bobDusdBefore - dusd.balanceOf(bob);
        assertLt(paid, 1_000e18, "repayment back-solved from the capped seizure");
        assertGt(paid, 900e18, "but not arbitrarily small");
        assertEq(desultory.getPositionDusdDebt(1), 2_100e18 - paid, "debt reduced by exactly what was paid");
    }

    /// @dev regression for the bug the Chimera harness found once liquidation entered its
    /// target surface: _seizeCollateral used to move a pool's totalScaledDeposits with no
    /// getAvailableLiquidity-style bound, unlike withdraw()/borrow(). If the collateral
    /// asset being seized is also heavily borrowed by a DIFFERENT position, an unbounded
    /// seizure can push that pool's debt above its deposits. liquidate() now caps the
    /// seizure at min(collateral held, pool's available liquidity) and back-solves the
    /// repayment from whichever is smaller, same as the existing collateral-held clamp.
    function testSeizureIsBoundedByAvailableLiquidity() public {
        MockERC20(usdc).mint(alice, 200_000e18);

        // alice: 200k USDC collateral, will borrow WETH against it
        vm.prank(alice);
        desultory.deposit(0, usdc, 200_000e18);

        // bob: 1000 WETH collateral, funds his own borrow capacity first...
        vm.prank(bob);
        desultory.deposit(0, weth, 1000e18);

        // ...then alice borrows WETH (needs bob's WETH liquidity in the pool)
        vm.prank(alice);
        desultory.borrow(1, weth, 50e18);

        // bob then borrows almost all of the USDC pool alice supplied, leaving the USDC
        // pool with only 10k of uncommitted (available) liquidity
        vm.prank(bob);
        desultory.borrow(2, usdc, 190_000e18);

        uint256 availableBefore = desultory.getAvailableLiquidity(usdc);
        assertEq(availableBefore, 10_000e18, "USDC pool almost fully lent out");

        // crash WETH's price UP so alice's WETH debt overwhelms her USDC collateral
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(30_000e18);
        assertLt(desultory.healthFactor(1), 1e18, "alice must be liquidatable");

        address liquidatorAddr = makeAddr("seizureLiquidator");
        MockERC20(weth).mint(liquidatorAddr, 1_000e18);
        vm.prank(liquidatorAddr);
        MockERC20(weth).approve(address(desultory), type(uint256).max);

        // ask to repay everything the close factor would allow; the collateral side
        // alone (200k USDC) can't be the binding constraint, the pool's cash can
        vm.prank(liquidatorAddr);
        desultory.liquidate(1, weth, usdc, 50e18);

        // it must have partially filled rather than reverting
        assertGt(desultory.getPositionBorrowForToken(1, weth), 0, "WETH debt only partially repaid");

        // the pool must still satisfy deposits >= debt: the seizure could not have taken
        // more than the pool's available liquidity
        Desultory.Pool memory usdcPool = desultory.getPoolInfo(usdc);
        uint256 usdcDeposits = usdcPool.totalScaledDeposits * usdcPool.liquidityIndex / 1e18;
        uint256 usdcDebt = (usdcPool.totalScaledBorrows * usdcPool.borrowIndex + 1e18 - 1) / 1e18;
        assertGe(usdcDeposits, usdcDebt, "USDC pool debt must not exceed deposits");
    }

    function testBadDebtIsRecordedWhenCollateralIsExhausted() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 2_100e18);

        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(1000e18);
        _fundBobWithDusd(3_000e18);

        assertEq(desultory.totalBadDebtUSD(), 0, "clean to start");

        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 2_100e18);

        assertEq(desultory.getPositionCollateralForToken(1, weth), 0, "no collateral left");
        assertGt(desultory.getPositionDusdDebt(1), 0, "debt remains");
        assertEq(
            desultory.totalBadDebtUSD(),
            desultory.userBorrowedAmountUSD(1),
            "the whole remaining debt is recognized as bad"
        );
    }

    function testNoBadDebtWhenCollateralRemains() public {
        _makeLiquidatable();
        _fundBobWithDusd(2_000e18);

        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 500e18);

        assertGt(desultory.getPositionCollateralForToken(1, weth), 0);
        assertEq(desultory.totalBadDebtUSD(), 0, "collateral remains, nothing is written off");
    }

    ///////////////////////
    // Treasury Tests
    ///////////////////////

    /// @dev builds real reserves: alice borrows, time passes, the reserve factor takes
    /// its 10% cut of the interest, then she repays so the cash is actually on hand.
    function _accrueReserves() internal returns (uint256) {
        vm.prank(bob);
        desultory.deposit(0, usdc, 50_000e18);

        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrow(2, usdc, 10_000e18);

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        desultory.repay(2, usdc, type(uint256).max);

        uint256 reserves = desultory.getPoolInfo(usdc).reserves;
        assertGt(reserves, 0, "fixture must accrue reserves");
        return reserves;
    }

    function testOwnerCanWithdrawReserves() public {
        uint256 reserves = _accrueReserves();
        address treasury = makeAddr("treasury");

        vm.prank(desultory.owner());
        desultory.withdrawReserves(usdc, treasury, reserves);

        assertEq(MockERC20(usdc).balanceOf(treasury), reserves, "treasury received the reserves");
        assertEq(desultory.getPoolInfo(usdc).reserves, 0, "reserves drained");
    }

    function testNonOwnerCannotWithdrawReserves() public {
        uint256 reserves = _accrueReserves();

        vm.prank(alice);
        vm.expectRevert();
        desultory.withdrawReserves(usdc, alice, reserves);
    }

    function testCannotWithdrawMoreReservesThanExist() public {
        uint256 reserves = _accrueReserves();

        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InsufficientReserves.selector, usdc));
        desultory.withdrawReserves(usdc, makeAddr("treasury"), reserves + 1);
    }

    function testWithdrawReservesRejectsZeroRecipient() public {
        uint256 reserves = _accrueReserves();

        vm.prank(desultory.owner());
        vm.expectRevert(Desultory.Desultory__ZeroAddress.selector);
        desultory.withdrawReserves(usdc, address(0), reserves);
    }

    /// @dev reserves keep growing while interest accrues, so the call must settle the
    /// pool before reading them — otherwise the owner is paid a stale figure.
    function testWithdrawReservesAccruesFirst() public {
        vm.prank(bob);
        desultory.deposit(0, usdc, 50_000e18);
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrow(2, usdc, 10_000e18);

        uint256 stale = desultory.getPoolInfo(usdc).reserves;
        vm.warp(block.timestamp + 365 days);

        vm.prank(desultory.owner());
        desultory.withdrawReserves(usdc, makeAddr("treasury"), 1);

        assertGt(desultory.getPoolInfo(usdc).reserves + 1, stale, "accrual must run before the read");
    }

    /// @dev the identity getAvailableLiquidity documents: cash = deposits + reserves - debt.
    /// Both sides of it fall by the same amount, so a withdrawal cannot strand depositors.
    function testWithdrawingReservesLeavesDepositorsWhole() public {
        uint256 reserves = _accrueReserves();

        vm.prank(desultory.owner());
        desultory.withdrawReserves(usdc, makeAddr("treasury"), reserves);

        Desultory.Pool memory pool = desultory.getPoolInfo(usdc);
        uint256 deposits = pool.totalScaledDeposits * pool.liquidityIndex / WAD;
        uint256 borrows = (pool.totalScaledBorrows * pool.borrowIndex + WAD - 1) / WAD;
        uint256 balance = MockERC20(usdc).balanceOf(address(desultory));

        assertGe(balance + borrows, deposits + pool.reserves, "custody must still cover obligations");
    }

    ///////////////////////
    // Backstop Tests
    ///////////////////////

    function testBackstopStartsEmptyOnEveryPool() public view {
        assertEq(desultory.getPoolInfo(weth).backstopScaledDeposits, 0, "WETH backstop starts empty");
        assertEq(desultory.getPoolInfo(usdc).backstopScaledDeposits, 0, "USDC backstop starts empty");
    }

    function testBackstopEntryPointInvertsTheBonusSplit() public {
        _makeLiquidatable();
        _fundBobWithDusd(2_000e18);

        uint256 repay = 500e18; // well under the 50% close factor of 2100
        uint256 bobWethBefore = MockERC20(weth).balanceOf(bob);

        vm.prank(bob);
        desultory.liquidateWithBackstop(1, address(dusd), weth, repay);

        assertEq(desultory.getPositionDusdDebt(1), 2_100e18 - repay, "debt retired");

        // same seizure as the ordinary path — the borrower gives up exactly as much —
        // but the protocol keeps 70% of the bonus instead of 30%
        uint256 seizeUSD = (repay * 11_000) / 10_000; // 550 USD
        uint256 seizeWeth = (seizeUSD * 1e18) / 2500e18; // 0.22 WETH
        uint256 baseWeth = (repay * 1e18) / 2500e18; // 0.20 WETH
        uint256 cut = ((seizeWeth - baseWeth) * 7_000) / 10_000;

        // approximate for the same reason the ordinary-path test is: the contract derives
        // `base` through repayFromSeize (which ceils) while this derives it from the price
        assertApproxEqAbs(MockERC20(weth).balanceOf(bob) - bobWethBefore, seizeWeth - cut, 1e12, "liquidator payout");
        assertApproxEqAbs(desultory.getPoolInfo(weth).reserves, cut, 1e12, "protocol cut to reserves");
        assertApproxEqAbs(desultory.getPositionCollateralForToken(1, weth), 1e18 - seizeWeth, 2, "collateral seized");

        // the WETH pool was never short, so nothing should have been committed
        assertEq(desultory.getPoolInfo(weth).backstopScaledDeposits, 0, "no commit on a liquid pool");
    }

    function testLiquidatorStillProfitsOnTheBackstopPath() public {
        _makeLiquidatable();
        _fundBobWithDusd(2_000e18);

        uint256 repay = 500e18;
        uint256 bobWethBefore = MockERC20(weth).balanceOf(bob);

        vm.prank(bob);
        desultory.liquidateWithBackstop(1, address(dusd), weth, repay);

        // 500 USD of DUSD debt burned buys strictly more than 500 USD of WETH at 2500
        uint256 gained = MockERC20(weth).balanceOf(bob) - bobWethBefore;
        assertGt(gained * 2500e18 / 1e18, repay, "liquidator must still clear a profit at 7000 bps");
    }

    ///////////////////////
    // Redemption Tests
    ///////////////////////

    /// @dev alice holds 10 WETH and owes 5000 DUSD — comfortably healthy, so redeemable.
    /// bob holds DUSD to redeem with.
    function _redeemableAlice() internal {
        // anchor the price rather than inherit the deploy default of 3000 — the expected
        // values below are computed at 2000, and a fixture that states its own assumption
        // is what the rest of this file does (see _makeLiquidatable)
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2_000e18);

        vm.prank(alice);
        desultory.deposit(0, weth, 10e18); // position 1, $20k at 2000/WETH
        vm.prank(alice);
        desultory.borrowDUSD(1, 5_000e18);

        assertGe(desultory.healthFactor(1), 1e18, "alice must be healthy to be redeemable");

        _fundBobWithDusd(3_000e18); // position 2
    }

    function testRedeemBurnsDusdAndReturnsCollateral() public {
        _redeemableAlice();

        uint256 bobWethBefore = MockERC20(weth).balanceOf(bob);
        uint256 supplyBefore = dusd.totalSupply();

        vm.prank(bob);
        desultory.redeem(1, weth, 1_000e18);

        // the position's DUSD debt fell by the full amount burned
        assertApproxEqAbs(desultory.getPositionDusdDebt(1), 4_000e18, 1e12, "debt cancelled at par");
        assertEq(supplyBefore - dusd.totalSupply(), 1_000e18, "supply fell by exactly what was burned");

        // bob received 995 USD of WETH at 2000/WETH = 0.4975 WETH
        uint256 expected = (995e18 * 1e18) / 2000e18;
        assertApproxEqAbs(MockERC20(weth).balanceOf(bob) - bobWethBefore, expected, 1e12, "collateral net of fee");
    }

    /// @dev the fee stays with the position: it gives up 995 USD of collateral while
    /// 1000 USD of debt is cancelled, so it is strictly better off by the 5 USD fee
    function testRedeemLeavesTheFeeWithThePosition() public {
        _redeemableAlice();

        uint256 collatBefore = desultory.getPositionCollateralForToken(1, weth);
        uint256 reservesBefore = desultory.getPoolInfo(weth).reserves;

        vm.prank(bob);
        desultory.redeem(1, weth, 1_000e18);

        uint256 removed = collatBefore - desultory.getPositionCollateralForToken(1, weth);
        uint256 removedUSD = (removed * 2000e18) / 1e18;

        assertApproxEqAbs(removedUSD, 995e18, 1e12, "position gives up only the net amount");
        assertEq(desultory.getPoolInfo(weth).reserves, reservesBefore, "no protocol cut on the ordinary path");
    }

    /// @dev the property the healthy-only gate rests on
    function testRedeemImprovesTheTargetHealthFactor() public {
        _redeemableAlice();

        uint256 hfBefore = desultory.healthFactor(1);

        vm.prank(bob);
        desultory.redeem(1, weth, 1_000e18);

        assertGt(desultory.healthFactor(1), hfBefore, "redemption must leave the target safer");
    }

    function testRedeemRejectsAnUnhealthyPosition() public {
        _makeLiquidatable(); // alice: 1 WETH, 2100 DUSD debt, WETH crashed to 2500 seize line
        _fundBobWithDusd(2_000e18);

        assertLt(desultory.healthFactor(1), 1e18, "fixture must be unhealthy");

        vm.prank(bob);
        vm.expectRevert(); // Desultory__NotRedeemable; the HF it carries is read inside the call
        desultory.redeem(1, weth, 500e18);
    }

    /// @dev redemption and liquidation partition the book: the position the previous test
    /// refused is exactly the one liquidate() accepts
    function testUnhealthyPositionIsLiquidatableInsteadOfRedeemable() public {
        _makeLiquidatable();
        _fundBobWithDusd(2_000e18);

        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 500e18);

        assertLt(desultory.getPositionDusdDebt(1), 2_100e18, "liquidation is the right tool here");
    }

    function testRedeemRevertsAgainstAPositionWithNoDusdDebt() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18); // position 1, no DUSD debt
        _fundBobWithDusd(1_000e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__NoDusdDebt.selector, 1));
        desultory.redeem(1, weth, 100e18);
    }

    function testRedeemClampsToThePositionsDusdDebt() public {
        _redeemableAlice();

        vm.prank(bob);
        desultory.redeem(1, weth, 3_000e18); // bob has exactly 3000; alice owes 5000

        assertApproxEqAbs(desultory.getPositionDusdDebt(1), 2_000e18, 1e12, "clamped, not reverted");
    }

    /// @dev the USDC pool saturated (zero available liquidity, real reserves) with a
    /// HEALTHY position holding USDC collateral and owing DUSD, so it is redeemable but
    /// the pool cannot pay without the backstop.
    function _saturatedPoolWithRedeemablePosition() internal returns (address who) {
        MockERC20(usdc).mint(alice, 200_000e18);

        vm.prank(alice);
        desultory.deposit(0, usdc, 200_000e18); // position 1, alice
        vm.prank(bob);
        desultory.deposit(0, weth, 1_000e18); // position 2, bob

        vm.prank(alice);
        desultory.borrowDUSD(1, 20_000e18); // healthy: $180k capacity against $20k debt

        vm.prank(bob);
        desultory.borrow(2, usdc, 199_000e18); // drain the USDC pool, leaving 1k of cash

        vm.warp(block.timestamp + 365 days); // interest -> reserves on the next accrual

        // both feeds must be refreshed after the warp or OracleLib's 3h timeout reverts
        MockV3Aggregator(deploy.getFeedI(1)).updateAnswer(100_000_000); // USDC, $1
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2000e18); // WETH, unchanged

        assertGe(desultory.healthFactor(1), 1e18, "alice must stay healthy");

        // a redeemer holding DUSD
        who = makeAddr("redeemer");
        vm.prank(alice);
        dusd.transfer(who, 10_000e18);
    }

    function testOrdinaryRedeemCannotFillAgainstASaturatedPool() public {
        address who = _saturatedPoolWithRedeemablePosition();

        vm.prank(who);
        vm.expectRevert(Desultory.Desultory__ZeroAmount.selector);
        desultory.redeem(1, usdc, 5_000e18);
    }

    function testBackstoppedRedeemFillsAgainstASaturatedPool() public {
        address who = _saturatedPoolWithRedeemablePosition();

        uint256 usdcBefore = MockERC20(usdc).balanceOf(who);

        vm.prank(who);
        desultory.redeemWithBackstop(1, usdc, 5_000e18);

        assertGt(MockERC20(usdc).balanceOf(who) - usdcBefore, 0, "redeemer was actually paid");
        assertGt(desultory.getPoolInfo(usdc).backstopScaledDeposits, 0, "reserves were committed");
    }

    /// @dev the fee goes to the protocol when the protocol funded the redemption
    function testBackstoppedRedeemBooksTheFeeToReserves() public {
        address who = _saturatedPoolWithRedeemablePosition();

        vm.recordLogs();
        vm.prank(who);
        desultory.redeemWithBackstop(1, usdc, 5_000e18);

        // pull feeToReserves out of the Redemption event rather than differencing
        // pool.reserves, which the backstop commit also moves in the same call
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeToReserves;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Desultory.Redemption.selector) {
                (,, feeToReserves) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        assertGt(feeToReserves, 0, "the protocol takes the fee when it funds the redemption");
    }

    function testBackstoppedRedeemPreservesCustody() public {
        address who = _saturatedPoolWithRedeemablePosition();

        vm.prank(who);
        desultory.redeemWithBackstop(1, usdc, 5_000e18);

        Desultory.Pool memory pool = desultory.getPoolInfo(usdc);
        uint256 deposits = pool.totalScaledDeposits * pool.liquidityIndex / 1e18;
        uint256 debt = (pool.totalScaledBorrows * pool.borrowIndex + 1e18 - 1) / 1e18;
        uint256 balance = MockERC20(usdc).balanceOf(address(desultory));

        assertGe(balance + debt, deposits + pool.reserves, "custody must still cover obligations");
    }
}
