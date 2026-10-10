pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Desultory} from "../src/Desultory.sol";
import {Position} from "../src/PositionNFT.sol";
import {DUSD} from "../src/DUSD.sol";
import {Deploy} from "../script/Deploy.s.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockV3Aggregator.sol";

/**
 * @dev the DUSD debt ceiling (ADR 0010): a per-home-chain bound on total DUSD debt,
 * enforced send-side in _borrowDusd, fail-closed.
 *
 * The load-bearing test is testUnwindPathsIgnoreTheCeiling. The ceiling sits on the one
 * site that adds DUSD debt, so it must never be able to block any site that removes it —
 * not at zero, not below current debt.
 */
contract DusdDebtCeilingTest is Test {
    Desultory desultory;
    Position position;
    DUSD dusd;
    Deploy deploy;

    address weth;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant WAD = 1e18;
    uint256 constant DEPLOY_CEILING = 10_000_000e18;
    uint32 constant REMOTE_EID = 2;

    function setUp() public {
        deploy = new Deploy();
        (address addr1, address addr2, address addr3) = deploy.run();
        desultory = Desultory(addr1);
        position = Position(addr2);
        dusd = DUSD(addr3);

        weth = deploy.getAddrI(0);

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            MockERC20(weth).mint(users[i], 1_000e18);
            vm.prank(users[i]);
            MockERC20(weth).approve(address(desultory), type(uint256).max);
        }
    }

    function _setCeiling(uint256 ceiling) internal {
        vm.prank(desultory.owner());
        desultory.setDusdDebtCeiling(ceiling);
    }

    /// @dev re-post both feeds' current answers after a warp; OracleLib.TIMEOUT is 3 hours
    function _refreshFeeds() internal {
        MockV3Aggregator wethFeed = MockV3Aggregator(deploy.getFeedI(0));
        MockV3Aggregator usdcFeed = MockV3Aggregator(deploy.getFeedI(1));
        wethFeed.updateAnswer(wethFeed.latestAnswer());
        usdcFeed.updateAnswer(usdcFeed.latestAnswer());
    }

    function _ceilingError(uint256 totalDebt, uint256 ceiling) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(Desultory.Desultory__DusdDebtCeilingExceeded.selector, totalDebt, ceiling);
    }

    ///////////////////////
    // fail-closed
    ///////////////////////

    function testFreshDesultoryStartsWithTheCeilingClosed() public {
        Desultory.TokenConfig[] memory none = new Desultory.TokenConfig[](0);
        Desultory fresh = new Desultory(none, address(position), address(dusd));
        assertEq(fresh.dusdDebtCeiling(), 0, "storage default must be zero: fail closed");
    }

    function testDeploySetsTheConfiguredCeiling() public view {
        assertEq(desultory.dusdDebtCeiling(), DEPLOY_CEILING);
    }

    /// @dev the end-to-end half of fail-closed, on the deployed system: a zero ceiling
    /// rejects. (A directly constructed Desultory cannot borrow at all — its Position is
    /// owned by the deployed instance — so the default and its effect are pinned apart.)
    function testZeroCeilingRejectsBorrowDUSD() public {
        _setCeiling(0);
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.expectRevert(_ceilingError(1e18, 0));
        vm.prank(alice);
        desultory.borrowDUSD(1, 1e18);
    }

    ///////////////////////
    // the boundary
    ///////////////////////

    /// @dev index == WAD, so both scaled conversions are exact and the boundary is too
    function testBorrowExactlyToTheCeilingSucceeds() public {
        _setCeiling(1_000e18);
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);
        assertEq(desultory.getTotalDusdDebt(), 1_000e18);
    }

    function testOneWeiOverTheCeilingReverts() public {
        _setCeiling(1_000e18);
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.expectRevert(_ceilingError(1_000e18 + 1, 1_000e18));
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18 + 1);
    }

    /// @dev off WAD, the borrow's scaled amount rounds up and the total-debt read rounds up
    /// again, so the ceiling can bind up to two wei early — never late.
    function testAfterAccrualTheCeilingBindsAtMostTwoWeiEarly() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        vm.warp(block.timestamp + 365 days);
        _refreshFeeds();
        desultory.accrueDusd();
        assertGt(desultory.dusdBorrowIndex(), WAD, "the index must have moved for this to mean anything");

        _setCeiling(5_000e18);
        uint256 headroom = 5_000e18 - desultory.getTotalDusdDebt();

        uint256 snap = vm.snapshotState();

        // one wei past the headroom always binds: debt can only round up
        vm.expectPartialRevert(Desultory.Desultory__DusdDebtCeilingExceeded.selector);
        vm.prank(alice);
        desultory.borrowDUSD(1, headroom + 1);

        vm.revertToState(snap);

        // two wei inside it always fits
        vm.prank(alice);
        desultory.borrowDUSD(1, headroom - 2);
        assertLe(desultory.getTotalDusdDebt(), 5_000e18, "a successful borrow never leaves debt above the ceiling");
    }

    ///////////////////////
    // both entry points
    ///////////////////////

    /// @dev Deploy wires an Adapter but no peer for REMOTE_EID. If the ceiling did not fire
    /// first, sendMint would revert with a LayerZero no-peer error instead — so matching the
    /// exact ceiling payload proves the ceiling ran before any message was attempted.
    function testBorrowDusdToIsCappedBeforeAnyMessageIsSent() public {
        vm.prank(desultory.owner());
        desultory.setAllowedDestination(REMOTE_EID, true);
        _setCeiling(1_000e18);

        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.expectRevert(_ceilingError(1_000e18 + 1, 1_000e18));
        vm.prank(alice);
        desultory.borrowDUSDTo(1, REMOTE_EID, alice, 1_000e18 + 1, "");
    }

    ///////////////////////
    // debt above the ceiling
    ///////////////////////

    function testAccrualPastTheCeilingBlocksBorrowsUntilARepayment() public {
        _setCeiling(1_000e18);
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        vm.warp(block.timestamp + 365 days);
        _refreshFeeds();
        desultory.accrueDusd();
        assertGt(desultory.getTotalDusdDebt(), 1_000e18, "accrual alone must have carried debt over the ceiling");

        vm.expectPartialRevert(Desultory.Desultory__DusdDebtCeilingExceeded.selector);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1);

        vm.prank(alice);
        desultory.repayDUSD(1, 100e18);

        vm.prank(alice);
        desultory.borrowDUSD(1, 50e18);
        assertLe(desultory.getTotalDusdDebt(), 1_000e18, "borrowing reopened once debt fell back under");
    }

    function testCeilingEqualToDebtRejectsAnyFurtherBorrow() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);

        _setCeiling(1_000e18);

        vm.expectRevert(_ceilingError(1_000e18 + 1, 1_000e18));
        vm.prank(alice);
        desultory.borrowDUSD(1, 1);
    }

    /// @dev the ceiling sits on the single site that adds DUSD debt, so no value of it —
    /// zero included, below current debt included — may block any site that removes it.
    function testUnwindPathsIgnoreTheCeiling() public {
        // carol: position 1, borrowed to her LTV limit at 3000, liquidatable at 2500
        vm.prank(carol);
        desultory.deposit(0, weth, 1e18);
        vm.prank(carol);
        desultory.borrowDUSD(1, 2_100e18);

        // alice: position 2, comfortably healthy, so redeemable
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(2, 5_000e18);

        // bob: position 3, holds the DUSD that redeems and liquidates
        vm.prank(bob);
        desultory.deposit(0, weth, 100e18);
        vm.prank(bob);
        desultory.borrowDUSD(3, 5_000e18);

        // zero is both the floor and below the 12,100 DUSD outstanding
        _setCeiling(0);

        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(2_500e18);
        assertFalse(desultory.isPositionHealthy(1), "carol must be liquidatable");
        assertGe(desultory.healthFactor(2), WAD, "alice must be redeemable");

        // new issuance is shut — no time has passed, so the index is WAD and the payload exact
        vm.expectRevert(_ceilingError(12_100e18 + 1, 0));
        vm.prank(bob);
        desultory.borrowDUSD(3, 1);

        uint256 carolDebt = desultory.getPositionDusdDebt(1);
        vm.prank(bob);
        desultory.liquidate(1, address(dusd), weth, 100e18);
        assertLt(desultory.getPositionDusdDebt(1), carolDebt, "liquidation must still retire DUSD debt");

        uint256 aliceDebt = desultory.getPositionDusdDebt(2);
        vm.prank(bob);
        desultory.redeem(2, weth, 1_000e18);
        assertLt(desultory.getPositionDusdDebt(2), aliceDebt, "redemption must still retire DUSD debt");

        uint256 bobDebt = desultory.getPositionDusdDebt(3);
        vm.prank(bob);
        desultory.repayDUSD(3, 1_000e18);
        assertLt(desultory.getPositionDusdDebt(3), bobDebt, "repayment must still retire DUSD debt");
    }

    ///////////////////////
    // setter and view
    ///////////////////////

    function testSetterIsOwnerOnlyAndEmits() public {
        vm.prank(alice);
        vm.expectRevert();
        desultory.setDusdDebtCeiling(1);
        assertEq(desultory.dusdDebtCeiling(), DEPLOY_CEILING, "a non-owner must not move it");

        vm.prank(desultory.owner());
        vm.expectEmit(true, true, true, true);
        emit Desultory.DusdDebtCeilingSet(42e18);
        desultory.setDusdDebtCeiling(42e18);
        assertEq(desultory.dusdDebtCeiling(), 42e18);
    }

    function testMaxCeilingIsEffectivelyUnlimited() public {
        _setCeiling(type(uint256).max);
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);
        assertEq(desultory.getTotalDusdDebt(), 1_000e18);
    }

    /// @dev a borrow failing both checks reports the ceiling: it runs first because it is one
    /// storage read against a loop over every listed token
    function testCeilingIsCheckedBeforeHealth() public {
        _setCeiling(0);
        vm.prank(alice);
        desultory.deposit(0, weth, 1e18); // 2,100 DUSD of capacity at 3000

        vm.expectRevert(_ceilingError(1_000_000e18, 0));
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000_000e18);
    }

    function testTotalDusdDebtMatchesPositionsAndIncludesAccrual() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 1_000e18);
        vm.prank(bob);
        desultory.deposit(0, weth, 10e18);
        vm.prank(bob);
        desultory.borrowDUSD(2, 2_000e18);

        assertEq(desultory.getTotalDusdDebt(), 3_000e18);

        vm.warp(block.timestamp + 365 days);
        desultory.accrueDusd();

        uint256 total = desultory.getTotalDusdDebt();
        uint256 sum = desultory.getPositionDusdDebt(1) + desultory.getPositionDusdDebt(2);
        assertGt(total, 3_000e18, "accrued fee must be counted");
        // each figure is an independent ceiling division, so they differ by at most a wei each
        assertApproxEqAbs(total, sum, 2, "total must match the per-position sum within rounding");
    }

    /// @dev getTotalDusdDebt reads the STORED index, like every other view here. Between
    /// accruals it understates debt, so headroom computed from it is overstated, and a
    /// borrow of that "apparent" headroom is rejected. Callers must accrueDusd() first or
    /// leave margin; the view's natspec says so.
    function testStaleViewOverstatesHeadroom() public {
        _setCeiling(1_000e18);
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);
        vm.prank(alice);
        desultory.borrowDUSD(1, 900e18);

        vm.warp(block.timestamp + 365 days);
        _refreshFeeds();

        uint256 apparent = 1_000e18 - desultory.getTotalDusdDebt();
        assertEq(apparent, 100e18, "the view has not seen the year of accrual");

        vm.expectPartialRevert(Desultory.Desultory__DusdDebtCeilingExceeded.selector);
        vm.prank(alice);
        desultory.borrowDUSD(1, apparent);
    }
}
