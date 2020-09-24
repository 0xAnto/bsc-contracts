pragma solidity ^0.6.0;

import "./BEP20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// DAO token
contract SmartSwapToken is BEP20("Smart Swap Token", "SSWAP"), Ownable {
    using SafeMath for uint256;

    address minter;

    event TransferOwnership(address owner);

    event Mint(address to, uint256 amt);

    constructor() public {
        // _mint(msg.sender, uint256(100000000).mul(10**18));
        minter = msg.sender;
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

    function setMinter(address _minter) public onlyOwner {
        require(msg.sender == minter, "only minter can call this method.");
        minter = _minter;
    }

    function mint(address _to, uint256 _amount) public {
        require(msg.sender == minter, "only minter can call this method.");
        _mint(_to, _amount);
        emit Mint(_to, _amount);
    }

    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {BEP20-_burn}.
     */
    function burn(uint256 amount) public virtual {
        require(msg.sender == minter, "only minter can call this method.");
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {BEP20-_burn} and {BEP20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public virtual {
        require(msg.sender == minter, "only minter can call this method.");
        uint256 decreasedAllowance = allowance(account, _msgSender()).sub(
            amount,
            "BEP20: burn amount exceeds allowance"
        );

        _approve(account, _msgSender(), decreasedAllowance);
        _burn(account, amount);
    }
}
