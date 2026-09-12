// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev the protocol's stablecoin, and the only asset borrowable across chains.
 *
 * As an OFT it moves between chains by burn-and-mint through LayerZero, which is
 * what lets a user repay a debt at home using DUSD they were issued elsewhere
 * without the protocol sending any message of its own.
 *
 * Minting is restricted to the protocol: Desultory for local borrows, Adapter for
 * mints authorized from another chain.
 */
contract DUSD is OFT {
    error DUSD__NotMinter();

    mapping(address account => bool allowed) public isMinter;

    event MinterSet(address indexed account, bool allowed);

    constructor(string memory _name, string memory _symbol, address _lzEndpoint, address _delegate)
        OFT(_name, _symbol, _lzEndpoint, _delegate)
        Ownable(_delegate)
    {}

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert DUSD__NotMinter();
        _;
    }

    function setMinter(address account, bool allowed) external onlyOwner {
        isMinter[account] = allowed;
        emit MinterSet(account, allowed);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }
}
