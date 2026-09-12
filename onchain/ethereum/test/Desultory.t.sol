pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

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
}
