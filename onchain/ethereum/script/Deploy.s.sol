pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";

import { Config } from "./Config.s.sol";

import { Desultory } from "../src/Desultory.sol";
import { Position } from "../src/PositionNFT.sol";
import { DUSD } from "../src/DUSD.sol";

contract Deploy is Script
{
    address[] tokenAddresses;
    address[] priceFeedAddresses;
    uint8[] feedDecimals;
    uint8[] tokenDecimals;
    uint8[] ltvRatios;
    uint16[] rates;

    Desultory desultory;
    Position position;
    DUSD dusd;

    function run() external returns (address, address, address)
    {
        Config config = new Config();

        (address wethF, address usdcF) = config.feeds();
        (address wethT, address usdcT) = config.tokens();

        priceFeedAddresses = [wethF, usdcF];
        tokenAddresses = [wethT, usdcT];
        feedDecimals = [18, 8];
        tokenDecimals = [18, 18];
        ltvRatios = [70, 85];
        rates = [400, 200];

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        position = new Position("Desultor", "DST");
        dusd = new DUSD("DesultoryUSD", "DUSD");
        desultory = new Desultory(
            tokenAddresses, priceFeedAddresses, feedDecimals, tokenDecimals, ltvRatios, rates, address(position), address(dusd)
        );

        position.setProtocol(address(desultory));
        position.transferOwnership(address(desultory));

        vm.stopBroadcast();

        return (address(desultory), address(position), address(dusd));
    }

    function getAddrI(uint256 index) external view returns (address)
    {
        return tokenAddresses[index];
    }
}
