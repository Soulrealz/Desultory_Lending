pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";

contract VoteToken is OFT {

    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _delegate
    ) OFT(_name, _symbol, _lzEndpoint, _delegate) Ownable(_delegate) 
    {
        mint(10_000_000 * 1e18);
    }

    function mint(uint256 amount) onlyOwner external
    {
        _mint(address(this), amount);
    }
}