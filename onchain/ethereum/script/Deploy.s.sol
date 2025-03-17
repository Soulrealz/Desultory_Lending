pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/Test.sol";

import { Config } from "./Config.s.sol";

import { Desultory } from "../src/Desultory.sol";
import { Position } from "../src/PositionNFT.sol";
import { DUSD } from "../src/DUSD.sol";

contract Deploy is Script
{
    address[] tokenAddresses;
    address[] priceFeedAddresses;
    uint8[] decimals;
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
        decimals = [18, 8];
        ltvRatios = [70, 85];
        rates = [400, 200];

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        position = new Position("Desultor", "DST");
        //dusd = new DUSD("DesultoryUSD", "DUSD", config.lz(), 0xEe8e7980c8E59B70051bE94687799D20Ff21eAe4);
        dusd = new DUSD("DesultoryUSD", "DUSD");
        desultory = new Desultory(tokenAddresses, priceFeedAddresses, decimals, ltvRatios, rates, address(position), address(dusd));

        position.transferOwnership(address(desultory));

        vm.stopBroadcast();

        return (address(desultory), address(position), address(dusd));
    }

    function getAddrI(uint256 index) external view returns (address)
    {
        return tokenAddresses[index];
    }
}