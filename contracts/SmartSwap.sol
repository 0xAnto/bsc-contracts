pragma solidity ^0.6.0;

import "./BEP20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SmartSwap is BEP20, Ownable {
    using SafeMath for uint256;

    constructor() public BEP20("Smart Swap", "SSWAP") {
        _mint(msg.sender, uint256(100000000).mul(10**18));
        transferOwnership(msg.sender);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {}
}
