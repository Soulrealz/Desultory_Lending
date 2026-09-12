// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

import {Adapter} from "../../src/crosschain/Adapter.sol";
import {DUSD} from "../../src/DUSD.sol";

contract AdapterTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private constant A_EID = 1;
    uint32 private constant B_EID = 2;

    Adapter private adapterA;
    Adapter private adapterB;
    DUSD private dusdA;
    DUSD private dusdB;

    address private desultoryA = address(0xD1);
    address private alice = address(0xA11CE);

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

        adapterA.setDesultory(desultoryA);
        dusdB.setMinter(address(adapterB), true);

        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        vm.deal(desultoryA, 100 ether);
    }

    function test_mintAuthorizationCrossesChains() public {
        MessagingFee memory fee = adapterA.quoteMint(B_EID, alice, 1_000e18, options);

        vm.prank(desultoryA);
        adapterA.sendMint{value: fee.nativeFee}(B_EID, alice, 1_000e18, options, desultoryA);

        assertEq(dusdB.balanceOf(alice), 0, "not minted until the packet is delivered");

        verifyPackets(B_EID, addressToBytes32(address(adapterB)));

        assertEq(dusdB.balanceOf(alice), 1_000e18, "DUSD should be minted on the destination");
        assertEq(dusdA.balanceOf(alice), 0, "nothing should be minted on the source");
    }

    function test_onlyDesultoryCanSend() public {
        MessagingFee memory fee = adapterA.quoteMint(B_EID, alice, 1e18, options);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Adapter.Adapter__NotDesultory.selector);
        adapterA.sendMint{value: fee.nativeFee}(B_EID, alice, 1e18, options, alice);
    }

    /// @dev the receive path must mint for a recipient with no position and no
    /// history — proving it is genuinely unconditional
    function test_receiveIsUnconditional() public {
        address stranger = address(0xBEEF);
        MessagingFee memory fee = adapterA.quoteMint(B_EID, stranger, 7e18, options);

        vm.prank(desultoryA);
        adapterA.sendMint{value: fee.nativeFee}(B_EID, stranger, 7e18, options, desultoryA);
        verifyPackets(B_EID, addressToBytes32(address(adapterB)));

        assertEq(dusdB.balanceOf(stranger), 7e18);
    }
}
