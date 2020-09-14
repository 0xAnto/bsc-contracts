pragma solidity ^0.6.0;

import "./lib/BEP20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract SmartSwap is BEP20 {
    using SafeMath for uint256;

    constructor() public BEP20("Smart Swap", "SSWAP") {
        _mint(msg.sender, uint256(100000000).mul(10**18));
    }
}
