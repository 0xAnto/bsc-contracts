pragma solidity ^0.6.0;

import "./BEP20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SmartSwapToken is BEP20("Smart Swap", "SSWAP"), Ownable {
    using SafeMath for uint256;

    event TransferOwnership(address owner);

    event Mint(address to, uint256 amt);

    constructor() public {
        _mint(msg.sender, uint256(100000000).mul(10**18));
        transferOwnership(msg.sender);
        emit TransferOwnership(msg.sender);
    }

    function transferOwnderShipTo(address to) public onlyOwner {
        transferOwnership(to);
        emit TransferOwnership(msg.sender);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {}

    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
        emit Mint(_to, _amount);
    }
}
