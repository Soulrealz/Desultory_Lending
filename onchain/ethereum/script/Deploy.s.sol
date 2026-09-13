pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";

import { Config } from "./Config.s.sol";

import { Desultory } from "../src/Desultory.sol";
import { Position } from "../src/PositionNFT.sol";
import { DUSD } from "../src/DUSD.sol";
import { Adapter } from "../src/crosschain/Adapter.sol";

contract Deploy is Script
{
    Desultory.TokenConfig[] configs;

    // both kept purely for the getAddrI / getFeedI accessors the tests use
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    Desultory desultory;
    Position position;
    DUSD dusd;
    Adapter adapter;

    function run() external returns (address, address, address)
    {
        Config config = new Config();

        (address wethF, address usdcF) = config.feeds();
        (address wethT, address usdcT) = config.tokens();

        tokenAddresses = [wethT, usdcT];
        priceFeedAddresses = [wethF, usdcF];

        configs.push(
            Desultory.TokenConfig({
                token: wethT,
                priceFeed: wethF,
                feedDecimals: 18,
                tokenDecimals: 18,
                ltvRatio: 70,
                liquidationThreshold: 75,
                liquidationBonusBps: 1_000,
                borrowRate: 400
            })
        );
        configs.push(
            Desultory.TokenConfig({
                token: usdcT,
                priceFeed: usdcF,
                feedDecimals: 8,
                tokenDecimals: 18,
                ltvRatio: 85,
                liquidationThreshold: 90,
                liquidationBonusBps: 500,
                borrowRate: 200
            })
        );

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        // the account that actually performs the CREATEs below, and therefore the
        // one every Ownable deployed here must be owned by
        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);

        position = new Position("Desultor", "DST");
        dusd = new DUSD("DesultoryUSD", "DUSD", config.lz(), deployer);
        desultory = new Desultory(configs, address(position), address(dusd));

        dusd.setMinter(address(desultory), true);

        // Peers and allowed destinations are per-deployment configuration and are
        // deliberately NOT set here: a single-chain local deploy has no peer.
        adapter = new Adapter(config.lz(), deployer, address(dusd));
        adapter.setDesultory(address(desultory));
        dusd.setMinter(address(adapter), true);
        desultory.setAdapter(address(adapter));

        position.setProtocol(address(desultory));
        position.transferOwnership(address(desultory));

        vm.stopBroadcast();

        return (address(desultory), address(position), address(dusd));
    }

    function getAddrI(uint256 index) external view returns (address)
    {
        return tokenAddresses[index];
    }

    function getFeedI(uint256 index) external view returns (address) {
        return priceFeedAddresses[index];
    }
}
