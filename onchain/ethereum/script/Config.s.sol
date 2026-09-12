pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import { MockV3Aggregator } from "../test/mocks/MockV3Aggregator.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import {EndpointV2Mock} from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";

contract Config is Script 
{
    struct Feeds 
    {
        address weth;
        address usdc;
    }

    struct Tokens 
    {
        address weth;
        address usdc;
    }

    address public lz;
    uint32 public eid;

    Feeds public feeds;
    Tokens public tokens;

    constructor() 
    {
        if (block.chainid == 11_155_111) 
        {
            (feeds, tokens) = getSepoliaConfig();
            lz = 0x6EDCE65403992e310A62460808c4b910D972f10f;
            eid = 40161;
        } 
        else 
        {
            (feeds, tokens, lz, eid) = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaConfig() public pure returns (Feeds memory _feeds, Tokens memory _tokens) 
    {
        _tokens =
            Tokens({weth: 0x5f207d42F869fd1c71d7f0f81a2A67Fc20FF7323, usdc: 0x2C032Aa43D119D7bf4Adc42583F1f94f3bf3023a});
        _feeds =
            Feeds({weth: 0x694AA1769357215DE4FAC081bf1f309aDC325306, usdc: 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E});
    }

    function getOrCreateAnvilEthConfig()
        public
        returns (Feeds memory _feeds, Tokens memory _tokens, address _lz, uint32 _eid)
    {
        vm.startBroadcast();
        // the address actually performing the CREATEs below; under a broadcast this is
        // the broadcaster, not msg.sender as seen from this frame.
        (, address deployer,) = vm.readCallers();

        MockV3Aggregator wethAggr = new MockV3Aggregator(18, 3000e18);
        MockERC20 wethMock = new MockERC20("WETH", "WETH");

        MockV3Aggregator usdcAggr = new MockV3Aggregator(8, 1e8);
        MockERC20 usdcMock = new MockERC20("USDC", "USDC");

        // A real EndpointV2Mock, not a hand-rolled stub: DUSD is an OFT and needs a
        // live endpoint at construction. eid 1 is arbitrary but must match what
        // Deploy.s.sol and the tests assume for the local chain. Its owner must be
        // the CREATE sender: the constructor registers its blocked message library
        // through an onlyOwner path.
        _eid = 1;
        _lz = address(new EndpointV2Mock(_eid, deployer));

        vm.stopBroadcast();

        _tokens = Tokens({weth: address(wethMock), usdc: address(usdcMock)});
        _feeds = Feeds({weth: address(wethAggr), usdc: address(usdcAggr)});
    }
}
