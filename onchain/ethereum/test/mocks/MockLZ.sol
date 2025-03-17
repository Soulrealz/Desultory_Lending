pragma solidity 0.8.28;

contract MockLZ
{
    event MessageSent(uint16 indexed dstChainId, bytes indexed toAddress, bytes payload);

    function send(
        uint16 _dstChainId,
        bytes calldata _toAddress,
        bytes calldata _payload,
        address payable, // _refundAddress
        address, // _zroPaymentAddress
        bytes calldata // _adapterParams
    ) external payable 
    {
        emit MessageSent(_dstChainId, _toAddress, _payload);
    }

    function estimateFees(
        uint16,
        address,
        bytes calldata,
        bool
    ) external pure returns (uint256 nativeFee, uint256 zroFee) 
    {
        return (0, 0); // No fees for local testing
    }
}
