// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {Desultory} from "../../src/Desultory.sol";
import {Position} from "../../src/PositionNFT.sol";
import {DUSD} from "../../src/DUSD.sol";
import {Adapter} from "../../src/crosschain/Adapter.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/**
 * @dev the whole point of the feature: collateral on chain A, DUSD on chain B.
 *
 * Chain A carries a full deployment (collateral token, feed, Position, DUSD,
 * Desultory, Adapter). Chain B carries only DUSD and an Adapter — no liquidity
 * has to pre-exist there, which is what the optimistic mint buys us.
 */
contract CrossChainBorrowTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private constant A_EID = 1;
    uint32 private constant B_EID = 2;

    Desultory private desultoryA;
    Position private positionA;
    DUSD private dusdA;
    DUSD private dusdB;
    Adapter private adapterA;
    Adapter private adapterB;

    MockERC20 private wethA;
    MockV3Aggregator private wethFeedA;

    address private alice = makeAddr("alice");

    bytes private options;

    function setUp() public override {
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        dusdA = new DUSD("DesultoryUSD", "DUSD", endpoints[A_EID], address(this));
        dusdB = new DUSD("DesultoryUSD", "DUSD", endpoints[B_EID], address(this));

        adapterA = Adapter(
            _deployOApp(type(Adapter).creationCode, abi.encode(endpoints[A_EID], address(this), address(dusdA)))
        );
        adapterB = Adapter(
            _deployOApp(type(Adapter).creationCode, abi.encode(endpoints[B_EID], address(this), address(dusdB)))
        );

        address[] memory oapps = new address[](2);
        oapps[0] = address(adapterA);
        oapps[1] = address(adapterB);
        this.wireOApps(oapps);

        // DUSD is an OFT in its own right; wiring the two tokens as peers is what
        // lets a borrower bridge their own DUSD home to repay, with no protocol
        // message involved.
        address[] memory tokenOapps = new address[](2);
        tokenOapps[0] = address(dusdA);
        tokenOapps[1] = address(dusdB);
        this.wireOApps(tokenOapps);

        // --- the lending system, chain A only ---
        wethFeedA = new MockV3Aggregator(18, 3000e18);
        wethA = new MockERC20("WETH", "WETH");

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(wethA);
        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = address(wethFeedA);
        uint8[] memory feedDecimals = new uint8[](1);
        feedDecimals[0] = 18;
        uint8[] memory tokenDecimals = new uint8[](1);
        tokenDecimals[0] = 18;
        uint8[] memory ltvs = new uint8[](1);
        ltvs[0] = 70;
        uint16[] memory rates = new uint16[](1);
        rates[0] = 400;

        positionA = new Position("Desultor", "DST");
        desultoryA = new Desultory(
            tokenAddresses, priceFeeds, feedDecimals, tokenDecimals, ltvs, rates, address(positionA), address(dusdA)
        );

        // order matters: setProtocol must run while the deployer still owns the NFT
        positionA.setProtocol(address(desultoryA));
        positionA.transferOwnership(address(desultoryA));

        dusdA.setMinter(address(desultoryA), true);
        dusdB.setMinter(address(adapterB), true);

        adapterA.setDesultory(address(desultoryA));
        desultoryA.setAdapter(address(adapterA));
        desultoryA.setAllowedDestination(B_EID, true);

        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        wethA.mint(alice, 1_000e18);
        vm.prank(alice);
        wethA.approve(address(desultoryA), type(uint256).max);
    }

    function test_depositOnAborrowOnB() public {
        // alice deposits 10 WETH on chain A
        vm.prank(alice);
        desultoryA.deposit(0, address(wethA), 10e18);

        MessagingFee memory fee = adapterA.quoteMint(B_EID, alice, 1_000e18, options);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        desultoryA.borrowDUSDTo{value: fee.nativeFee}(1, B_EID, alice, 1_000e18, options);

        // debt is recorded at home immediately
        assertEq(desultoryA.getPositionDusdDebt(1), 1_000e18);
        assertEq(dusdB.balanceOf(alice), 0, "not yet delivered");

        verifyPackets(B_EID, addressToBytes32(address(adapterB)));

        assertEq(dusdB.balanceOf(alice), 1_000e18, "DUSD minted on chain B");
        assertEq(dusdA.balanceOf(alice), 0, "nothing minted at home");
    }

    function test_overLtvRevertsBeforeAnyMessageIsSent() public {
        vm.prank(alice);
        desultoryA.deposit(0, address(wethA), 1e18); // 2100 USD capacity

        MessagingFee memory fee = adapterA.quoteMint(B_EID, alice, 5_000e18, options);
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(Desultory.Desultory__CollateralValueNotEnough.selector);
        desultoryA.borrowDUSDTo{value: fee.nativeFee}(1, B_EID, alice, 5_000e18, options);

        assertEq(dusdB.balanceOf(alice), 0);
    }

    function test_disallowedDestinationReverts() public {
        vm.prank(alice);
        desultoryA.deposit(0, address(wethA), 10e18);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Desultory.Desultory__DestinationNotAllowed.selector, uint32(99)));
        desultoryA.borrowDUSDTo{value: 1 ether}(1, 99, alice, 1e18, options);
    }

    function test_repayAfterBridgingHome() public {
        vm.prank(alice);
        desultoryA.deposit(0, address(wethA), 10e18);
        MessagingFee memory fee = adapterA.quoteMint(B_EID, alice, 1_000e18, options);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        desultoryA.borrowDUSDTo{value: fee.nativeFee}(1, B_EID, alice, 1_000e18, options);
        verifyPackets(B_EID, addressToBytes32(address(adapterB)));

        // alice bridges her own DUSD home with the OFT's own send() -- this is the
        // whole reason repay needs no protocol message
        SendParam memory sendParam = SendParam({
            dstEid: A_EID,
            to: addressToBytes32(alice),
            amountLD: 1_000e18,
            minAmountLD: 1_000e18,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory bridgeFee = dusdB.quoteSend(sendParam, false);

        vm.prank(alice);
        dusdB.send{value: bridgeFee.nativeFee}(sendParam, bridgeFee, alice);
        verifyPackets(A_EID, addressToBytes32(address(dusdA)));

        assertEq(dusdA.balanceOf(alice), 1_000e18, "DUSD should have arrived home");
        assertEq(dusdB.balanceOf(alice), 0, "and been burned on the far side");

        vm.prank(alice);
        desultoryA.repayDUSD(1, 1_000e18);
        assertEq(desultoryA.getPositionDusdDebt(1), 0);
    }
}
