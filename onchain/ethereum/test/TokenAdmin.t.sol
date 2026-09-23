pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Desultory} from "../src/Desultory.sol";
import {Position} from "../src/PositionNFT.sol";
import {DUSD} from "../src/DUSD.sol";
import {Deploy} from "../script/Deploy.s.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockV3Aggregator.sol";

/**
 * @dev the token listing admin: addToken and setTokenRetired.
 *
 * The load-bearing test here is testRetiredTokenPositionIsUntouchedAndStillUnwinds.
 * Retirement deliberately does NOT shrink __tokenList or clear __tokenInfos, because
 * every health computation iterates that list: a removal would make an existing
 * position's collateral and debt in the asset vanish from the sum at once. The rest of
 * the file is the validation surface around that decision.
 */
contract TokenAdminTest is Test {
    Desultory desultory;
    Position position;
    DUSD dusd;
    Deploy deploy;

    address weth;
    address usdc;

    // a third asset, deployed but NOT listed at construction — the subject of addToken
    MockERC20 dai;
    MockV3Aggregator daiFeed;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    address dead = 0x000000000000000000000000000000000000dEaD;

    uint256 constant WAD = 1e18;
    uint16 constant MAX_BPS = 10_000;
    uint256 constant MAX_SUPPORTED_TOKENS = 32;

    function setUp() public {
        deploy = new Deploy();
        (address addr1, address addr2, address addr3) = deploy.run();
        desultory = Desultory(addr1);
        position = Position(addr2);
        dusd = DUSD(addr3);

        weth = deploy.getAddrI(0);
        usdc = deploy.getAddrI(1);

        dai = new MockERC20("DAI", "DAI");
        daiFeed = new MockV3Aggregator(18, 1e18);

        MockERC20(weth).mint(alice, 1_000e18);
        MockERC20(usdc).mint(alice, 100_000e18);
        dai.mint(alice, 100_000e18);
        MockERC20(weth).mint(bob, 1_000e18);
        MockERC20(usdc).mint(bob, 100_000e18);
        dai.mint(bob, 100_000e18);

        vm.startPrank(alice);
        MockERC20(weth).approve(address(desultory), type(uint256).max);
        MockERC20(usdc).approve(address(desultory), type(uint256).max);
        dai.approve(address(desultory), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(weth).approve(address(desultory), type(uint256).max);
        MockERC20(usdc).approve(address(desultory), type(uint256).max);
        dai.approve(address(desultory), type(uint256).max);
        vm.stopPrank();
    }

    function _daiConfig() internal view returns (Desultory.TokenConfig memory) {
        return Desultory.TokenConfig({
            token: address(dai),
            priceFeed: address(daiFeed),
            feedDecimals: 18,
            tokenDecimals: 18,
            ltvRatio: 80,
            liquidationThreshold: 85,
            liquidationBonusBps: 500,
            borrowRate: 100
        });
    }

    function _addDai() internal {
        vm.prank(desultory.owner());
        desultory.addToken(_daiConfig());
    }

    ///////////////////////
    // addToken
    ///////////////////////

    function testAddTokenListsAssetThatAcceptsDepositAndBorrow() public {
        assertEq(desultory.getPriceFeedForToken(address(dai)), address(0), "dai must start unlisted");

        vm.prank(desultory.owner());
        vm.expectEmit(true, true, true, true);
        emit Desultory.TokenAdded(address(dai), address(daiFeed));
        desultory.addToken(_daiConfig());

        Desultory.Collateral memory info = desultory.getTokenInfo(address(dai));
        assertEq(info.priceFeed, address(daiFeed));
        assertEq(info.ltvRatio, 80);
        assertEq(info.liquidationThreshold, 85);
        assertEq(info.liquidationBonusBps, 500);

        Desultory.Pool memory pool = desultory.getPoolInfo(address(dai));
        assertEq(pool.liquidityIndex, WAD, "fresh pool starts at WAD");
        assertEq(pool.borrowIndex, WAD, "fresh pool starts at WAD");
        assertEq(pool.totalScaledDeposits, 0);
        assertEq(pool.totalScaledBorrows, 0);
        assertEq(pool.reserves, 0);
        assertEq(pool.lastUpdate, uint40(block.timestamp), "fresh pool must not carry a stale timestamp");

        // the new asset is usable end to end: it is collateral, it is liquidity, and it is
        // borrowable, and it also counts toward the health computation of a position whose
        // other collateral predates it
        vm.prank(alice);
        desultory.deposit(0, address(dai), 1_000e18);
        assertEq(desultory.getPositionCollateralForToken(1, address(dai)), 1_000e18);
        assertEq(desultory.userCollateralValueUSD(1), 1_000e18, "dai priced at $1");

        vm.prank(alice);
        desultory.borrow(1, address(dai), 100e18);
        assertEq(desultory.getPositionBorrowForToken(1, address(dai)), 100e18);
    }

    function testAddTokenIsOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        desultory.addToken(_daiConfig());

        assertEq(desultory.getPriceFeedForToken(address(dai)), address(0), "listing must not have happened");
    }

    function testAddTokenRejectsDuplicate() public {
        _addDai();

        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenAlreadyListed.selector, address(dai)));
        desultory.addToken(_daiConfig());

        // and the same for an asset listed by the constructor
        Desultory.TokenConfig memory c = _daiConfig();
        c.token = weth;
        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenAlreadyListed.selector, weth));
        desultory.addToken(c);
    }

    function testAddTokenRejectsZeroAddress() public {
        Desultory.TokenConfig memory c = _daiConfig();
        c.token = address(0);

        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, address(0)));
        desultory.addToken(c);
    }

    function testAddTokenRejectsZeroPriceFeed() public {
        Desultory.TokenConfig memory c = _daiConfig();
        c.priceFeed = address(0);

        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, address(dai)));
        desultory.addToken(c);
    }

    /// @dev DUSD is debt-only. Listing it would give it a second accounting path through
    /// __pools alongside __scaledDusdDebt, and userBorrowedAmountUSD would count both.
    function testAddTokenRejectsDusd() public {
        Desultory.TokenConfig memory c = _daiConfig();
        c.token = address(dusd);

        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, address(dusd)));
        desultory.addToken(c);
    }

    /// @dev addToken must reuse the constructor's validation, not carry its own. The
    /// threshold <= 100 bound in particular is quantified over every listed token by the
    /// redemption and liquidation safety arguments.
    function testAddTokenRejectsInvalidRiskParams() public {
        address owner = desultory.owner();

        // threshold equal to the LTV: no buffer band at all
        Desultory.TokenConfig memory c = _daiConfig();
        c.ltvRatio = 85;
        c.liquidationThreshold = 85;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, address(dai)));
        desultory.addToken(c);

        // threshold below the LTV
        c = _daiConfig();
        c.ltvRatio = 90;
        c.liquidationThreshold = 85;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, address(dai)));
        desultory.addToken(c);

        // threshold above 100%
        c = _daiConfig();
        c.liquidationThreshold = 101;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, address(dai)));
        desultory.addToken(c);

        // bonus above MAX_BONUS_BPS (20%)
        c = _daiConfig();
        c.liquidationBonusBps = 2_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__InvalidRiskParams.selector, address(dai)));
        desultory.addToken(c);

        assertEq(desultory.getPriceFeedForToken(address(dai)), address(0), "none of those may have listed");

        // the boundary values themselves are accepted
        c = _daiConfig();
        c.liquidationThreshold = 100;
        c.liquidationBonusBps = 2_000;
        vm.prank(owner);
        desultory.addToken(c);
        assertEq(desultory.getTokenInfo(address(dai)).liquidationThreshold, 100);
    }

    /// @dev every health check is O(supported tokens), so the list is capped. Two assets
    /// are already listed by the deploy script.
    function testAddTokenPastTheLimitReverts() public {
        address owner = desultory.owner();

        for (uint256 i = 2; i < MAX_SUPPORTED_TOKENS; i++) {
            Desultory.TokenConfig memory c = _daiConfig();
            c.token = address(new MockERC20("FILL", "FILL"));
            c.priceFeed = address(new MockV3Aggregator(18, 1e18));

            vm.prank(owner);
            desultory.addToken(c);
        }

        Desultory.TokenConfig memory over = _daiConfig();
        vm.prank(owner);
        vm.expectRevert(Desultory.Desultory__TokenLimitReached.selector);
        desultory.addToken(over);
    }

    /// @dev the constructor shares _listToken, so it is bounded by the same number
    function testConstructorEnforcesTheSameLimit() public {
        Desultory.TokenConfig[] memory configs = new Desultory.TokenConfig[](MAX_SUPPORTED_TOKENS + 1);
        for (uint256 i = 0; i < configs.length; i++) {
            configs[i] = _daiConfig();
            configs[i].token = address(uint160(i + 1));
        }

        vm.expectRevert(Desultory.Desultory__TokenLimitReached.selector);
        new Desultory(configs, address(position), address(dusd));
    }

    /**
     * @dev a pool listed long after deployment must charge interest from its listing, not
     * from block zero. Pinned by comparing the borrow index after exactly one day against
     * the index that one day at the pool's own rate produces.
     */
    function testFreshPoolChargesNoInterestForTimeBeforeListing() public {
        vm.warp(block.timestamp + 400 days);
        daiFeed.updateAnswer(1e18); // the feed predates the warp; refresh it, same price
        _addDai();

        assertEq(desultory.getPoolInfo(address(dai)).lastUpdate, uint40(block.timestamp));

        vm.prank(alice);
        desultory.deposit(0, address(dai), 1_000e18);
        vm.prank(alice);
        desultory.borrow(1, address(dai), 100e18);

        // nothing has elapsed since listing, so nothing may have accrued
        assertEq(desultory.getPoolInfo(address(dai)).borrowIndex, WAD, "index moved with zero elapsed time");
        assertEq(desultory.getPositionBorrowForToken(1, address(dai)), 100e18);

        vm.warp(block.timestamp + 1 days);
        daiFeed.updateAnswer(1e18); // refresh the feed so the health check stays fresh

        // the rate accrue() uses is taken from PRE-accrual utilization, so read it here
        uint32 rate = desultory.getBorrowRate(address(dai), desultory.getUtilization(address(dai)));

        vm.prank(bob);
        desultory.deposit(1, address(dai), 1e18); // triggers accrue on the dai pool

        uint256 factor = (uint256(rate) * 1 days * WAD) / (uint256(365 days) * MAX_BPS);
        assertEq(
            desultory.getPoolInfo(address(dai)).borrowIndex,
            WAD + (WAD * factor) / WAD,
            "exactly one day of interest, not 401"
        );
    }

    ///////////////////////
    // setTokenRetired
    ///////////////////////

    function testSetTokenRetiredBlocksDepositAndBorrow() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 10e18);

        vm.prank(desultory.owner());
        vm.expectEmit(true, true, true, true);
        emit Desultory.TokenRetired(weth, true);
        desultory.setTokenRetired(weth, true);

        assertTrue(desultory.isTokenRetired(weth));
        assertFalse(desultory.isTokenRetired(usdc), "retirement is per token");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenRetired.selector, weth));
        desultory.deposit(1, weth, 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenRetired.selector, weth));
        desultory.borrow(1, weth, 1e18);

        // the untouched asset is unaffected
        vm.prank(alice);
        desultory.deposit(1, usdc, 100e18);
    }

    function testSetTokenRetiredIsReversible() public {
        address owner = desultory.owner();

        vm.prank(owner);
        desultory.setTokenRetired(weth, true);
        assertTrue(desultory.isTokenRetired(weth));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit Desultory.TokenRetired(weth, false);
        desultory.setTokenRetired(weth, false);
        assertFalse(desultory.isTokenRetired(weth));

        vm.prank(alice);
        desultory.deposit(0, weth, 1e18);
        assertEq(desultory.getPositionCollateralForToken(1, weth), 1e18);
    }

    function testSetTokenRetiredIsOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        desultory.setTokenRetired(weth, true);

        assertFalse(desultory.isTokenRetired(weth));
    }

    function testSetTokenRetiredRejectsUnlistedToken() public {
        vm.prank(desultory.owner());
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenNotWhitelisted.selector, dead));
        desultory.setTokenRetired(dead, true);
    }

    /**
     * @dev THE load-bearing test.
     *
     * A position holding both collateral and debt in an asset that is then retired must be
     * completely unaffected: the same health factor, and every unwind path still open. If
     * retirement shrank __tokenList or blanked the price feed instead, the position's WETH
     * collateral and WETH debt would both drop out of the sums here and the health factor
     * would jump — in whichever direction the larger leg happened to be.
     */
    function testRetiredTokenPositionIsUntouchedAndStillUnwinds() public {
        // bob supplies the WETH liquidity alice borrows against
        vm.prank(bob);
        desultory.deposit(0, weth, 100e18); // position 1

        vm.prank(alice);
        desultory.deposit(0, weth, 10e18); // position 2 — $30k collateral
        vm.prank(alice);
        desultory.borrow(2, weth, 1e18); // WETH debt, same asset as the collateral
        vm.prank(alice);
        desultory.borrowDUSD(2, 10_000e18); // plus DUSD, so the price move below bites

        uint256 hfBefore = desultory.healthFactor(2);
        uint256 collateralBefore = desultory.userCollateralValueUSD(2);
        uint256 debtBefore = desultory.userBorrowedAmountUSD(2);
        uint256 maxBorrowBefore = desultory.userMaxBorrowValueUSD(2);
        assertGt(hfBefore, WAD, "fixture must start healthy");

        vm.prank(desultory.owner());
        desultory.setTokenRetired(weth, true);

        // no time has passed, so every one of these is a pure function of state the
        // retirement must not have touched
        assertEq(desultory.healthFactor(2), hfBefore, "retirement moved the health factor");
        assertEq(desultory.userCollateralValueUSD(2), collateralBefore, "collateral vanished");
        assertEq(desultory.userBorrowedAmountUSD(2), debtBefore, "debt vanished");
        assertEq(desultory.userMaxBorrowValueUSD(2), maxBorrowBefore, "borrow capacity moved");
        assertEq(desultory.getPositionCollateralForToken(2, weth), 10e18);
        assertEq(desultory.getPositionBorrowForToken(2, weth), 1e18);

        // new exposure is closed...
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenRetired.selector, weth));
        desultory.deposit(2, weth, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__TokenRetired.selector, weth));
        desultory.borrow(2, weth, 1e18);

        // ...but every unwind path is open. Repay.
        vm.prank(alice);
        desultory.repay(2, weth, 0.5e18);
        assertEq(desultory.getPositionBorrowForToken(2, weth), 0.5e18, "repay must still work");

        // Repay DUSD.
        vm.prank(alice);
        desultory.repayDUSD(2, 1_000e18);
        assertEq(desultory.getPositionDusdDebt(2), 9_000e18, "repayDUSD must still work");

        // Withdraw.
        uint256 walletBefore = MockERC20(weth).balanceOf(alice);
        vm.prank(alice);
        desultory.withdraw(2, weth, 1e18);
        assertEq(MockERC20(weth).balanceOf(alice) - walletBefore, 1e18, "withdraw must still work");
        assertEq(desultory.getPositionCollateralForToken(2, weth), 9e18);

        // Liquidate. WETH falls: the 9 WETH of collateral is now $9k against $9.5k of
        // debt ($500 of WETH plus $9,000 of DUSD), so the position is under water.
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(1_000e18);
        MockV3Aggregator(deploy.getFeedI(1)).updateAnswer(1e8);
        assertLt(desultory.healthFactor(2), WAD, "fixture must be liquidatable");

        uint256 liquidatorBefore = MockERC20(weth).balanceOf(bob);
        vm.prank(bob);
        desultory.liquidate(2, weth, weth, 0.25e18);
        assertGt(MockERC20(weth).balanceOf(bob), liquidatorBefore, "liquidation must still pay out");
        assertLt(desultory.getPositionBorrowForToken(2, weth), 0.5e18, "liquidation must still retire debt");
    }

    /// @dev the owner's own loss-absorption and treasury paths stay open on a retired
    /// asset too — an admin must never be able to freeze the protocol's own unwinding.
    function testRetirementDoesNotBlockReserveAdmin() public {
        vm.prank(alice);
        desultory.deposit(0, weth, 100e18);
        vm.prank(alice);
        desultory.borrow(1, weth, 50e18);

        vm.warp(block.timestamp + 365 days);
        MockV3Aggregator(deploy.getFeedI(0)).updateAnswer(3_000e18);

        address owner = desultory.owner();
        vm.prank(owner);
        desultory.setTokenRetired(weth, true);

        // accrue the year of interest into reserves through a path that is still open
        vm.prank(alice);
        desultory.repay(1, weth, 1e18);

        uint256 reserves = desultory.getPoolInfo(weth).reserves;
        assertGt(reserves, 0, "fixture must have accrued reserves");

        vm.prank(owner);
        desultory.withdrawReserves(weth, bob, reserves);
        assertEq(desultory.getPoolInfo(weth).reserves, 0, "withdrawReserves must still work");
    }
}
