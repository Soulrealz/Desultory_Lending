pragma solidity 0.8.28;

import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DUSD is ERC20 {

    // constructor(
    //     string memory _name,
    //     string memory _symbol,
    //     address _lzEndpoint,
    //     address _delegate
    // ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) 
    // {
    //     //mint(10_000_000 * 1e18);
    // }

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

}