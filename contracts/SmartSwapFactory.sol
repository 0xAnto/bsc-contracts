pragma solidity >=0.5.16;

import "./interfaces/ISmartSwapFactory.sol";
import "./SmartSwapPool.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SmartSwapFactory is ISmartSwapFactory, Ownable {
    address public override feeTo;
    address public override feeToSetter;
    event TransferOwnership(address owner);

    function transferOwnderShipTo(address to) public onlyOwner {
        transferOwnership(to);
        emit TransferOwnership(msg.sender);
    }

    mapping(address => mapping(address => address)) public override getPool;
    address[] public override allPools;

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        address pool,
        uint256
    );

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
        transferOwnership(msg.sender);
    }

    function allPoolsLength() external override view returns (uint256) {
        return allPools.length;
    }

    function createPool(address tokenA, address tokenB)
        external
        override
        returns (address pool)
    {
        require(tokenA != tokenB, "SmartSwap: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "SmartSwap: ZERO_ADDRESS");
        require(
            getPool[token0][token1] == address(0),
            "SmartSwap: POOL_EXISTS"
        ); // single check is sufficient
        bytes memory bytecode = type(SmartSwapPool).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pool := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        ISmartSwapPool(pool).initialize(token0, token1);
        getPool[token0][token1] = pool;
        getPool[token1][token0] = pool; // populate mapping in the reverse direction
        allPools.push(pool);
        emit PoolCreated(token0, token1, pool, allPools.length);
    }

    function setFeeTo(address _feeTo) external override {
        require(msg.sender == feeToSetter, "SmartSwap: FORBIDDEN");
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        require(msg.sender == feeToSetter, "SmartSwap: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
}
