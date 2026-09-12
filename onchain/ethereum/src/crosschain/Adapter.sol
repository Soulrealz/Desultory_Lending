// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IDUSDMintable {
    function mint(address to, uint256 amount) external;
}

/**
 * @dev LayerZero V2 OApp carrying DUSD mint authorizations between chains.
 *
 * Symmetric: the same contract is deployed everywhere and both sends and receives.
 * A chain is a "home" chain for positions opened there and a "destination" chain
 * for DUSD minted there; most chains are both.
 *
 * SECURITY: a compromised adapter on ANY chain can mint unlimited DUSD, spendable
 * on EVERY chain. Peer configuration is the entire security boundary.
 */
contract Adapter is OApp {
    error Adapter__NotDesultory();

    IDUSDMintable public immutable dusd;
    address public desultory;

    event DesultorySet(address indexed desultory);
    event MintAuthorized(uint32 indexed dstEid, address indexed recipient, uint256 amount);
    event MintReceived(uint32 indexed srcEid, address indexed recipient, uint256 amount);

    constructor(address _endpoint, address _delegate, address _dusd) OApp(_endpoint, _delegate) Ownable(_delegate) {
        dusd = IDUSDMintable(_dusd);
    }

    function setDesultory(address _desultory) external onlyOwner {
        desultory = _desultory;
        emit DesultorySet(_desultory);
    }

    function quoteMint(uint32 dstEid, address recipient, uint256 amount, bytes calldata options)
        external
        view
        returns (MessagingFee memory)
    {
        return _quote(dstEid, abi.encode(recipient, amount), options, false);
    }

    function sendMint(uint32 dstEid, address recipient, uint256 amount, bytes calldata options, address refund)
        external
        payable
        returns (MessagingReceipt memory)
    {
        if (msg.sender != desultory) revert Adapter__NotDesultory();
        emit MintAuthorized(dstEid, recipient, amount);
        return _lzSend(dstEid, abi.encode(recipient, amount), options, MessagingFee(msg.value, 0), refund);
    }

    /**
     * @dev mints, and does nothing else.
     *
     * NOTHING MAY BE ADDED HERE THAT CAN REVERT — no pause flag, no allowlist, no
     * supply cap, no balance check. Debt is already recorded on the source chain by
     * the time this runs. LayerZero persists undelivered messages and retry is
     * permissionless, so a transient failure self-heals; a permanent revert would
     * strand the message and leave the borrower owing DUSD they never received.
     */
    function _lzReceive(Origin calldata _origin, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        (address recipient, uint256 amount) = abi.decode(_message, (address, uint256));
        dusd.mint(recipient, amount);
        emit MintReceived(_origin.srcEid, recipient, amount);
    }
}
