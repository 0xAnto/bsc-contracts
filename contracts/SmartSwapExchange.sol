pragma solidity >=0.6.0;

import "./interfaces/ISmartSwapFactory.sol";
import "./lib/TransferHelper.sol";

import "./interfaces/ISmartSwapExchange.sol";
import "./lib/SmartSwapLibrary.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IBEP20.sol";
import "./interfaces/IBNB.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SmartSwapExchange is Ownable {
    event TransferOwnership(address owner);
    using SafeMath for uint256;

    address public immutable factory;
    address public immutable WBNB;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "SmartSwapExchange: EXPIRED");
        _;
    }

    constructor(address _factory, address _WBNB) public {
        factory = _factory;
        WBNB = _WBNB;
        transferOwnership(msg.sender);
    }

    receive() external payable {
        assert(msg.sender == WBNB); // only accept BNB via fallback from the WBNB contract
    }

    function transferOwnderShipTo(address to) public onlyOwner {
        transferOwnership(to);
        emit TransferOwnership(msg.sender);
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        // create the Pool if it doesn't exist yet
        if (ISmartSwapFactory(factory).getPool(tokenA, tokenB) == address(0)) {
            ISmartSwapFactory(factory).createPool(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = SmartSwapLibrary.getReserves(
            factory,
            tokenA,
            tokenB
        );
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = SmartSwapLibrary.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                require(
                    amountBOptimal >= amountBMin,
                    "SmartSwapExchange: INSUFFICIENT_B_AMOUNT"
                );
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = SmartSwapLibrary.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                require(
                    amountAOptimal >= amountAMin,
                    "SmartSwapExchange: INSUFFICIENT_A_AMOUNT"
                );
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin
        );
        address pool = SmartSwapLibrary.poolFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pool, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pool, amountB);
        liquidity = ISmartSwapPool(pool).mint(to);
    }

    function addLiquidityBNB(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        payable
        ensure(deadline)
        returns (
            uint256 amountToken,
            uint256 amountBNB,
            uint256 liquidity
        )
    {
        (amountToken, amountBNB) = _addLiquidity(
            token,
            WBNB,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountBNBMin
        );
        address pool = SmartSwapLibrary.poolFor(factory, token, WBNB);
        TransferHelper.safeTransferFrom(token, msg.sender, pool, amountToken);
        IBNB(WBNB).deposit{value: amountBNB}();
        assert(IBNB(WBNB).transfer(pool, amountBNB));
        liquidity = ISmartSwapPool(pool).mint(to);
        // refund dust BNB, if any
        if (msg.value > amountBNB)
            TransferHelper.safeTransferBNB(msg.sender, msg.value - amountBNB);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        public
        virtual
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        address pool = SmartSwapLibrary.poolFor(factory, tokenA, tokenB);
        ISmartSwapPool(pool).transferFrom(msg.sender, pool, liquidity); // send liquidity to Pool
        (uint256 amount0, uint256 amount1) = ISmartSwapPool(pool).burn(to);
        (address token0, ) = SmartSwapLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(
            amountA >= amountAMin,
            "SmartSwapExchange: INSUFFICIENT_A_AMOUNT"
        );
        require(
            amountB >= amountBMin,
            "SmartSwapExchange: INSUFFICIENT_B_AMOUNT"
        );
    }

    function removeLiquidityBNB(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline
    )
        public
        virtual
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountBNB)
    {
        (amountToken, amountBNB) = removeLiquidity(
            token,
            WBNB,
            liquidity,
            amountTokenMin,
            amountBNBMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IBNB(WBNB).withdraw(amountBNB);
        TransferHelper.safeTransferBNB(to, amountBNB);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityBNBSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountBNBMin,
        address to,
        uint256 deadline
    ) public virtual ensure(deadline) returns (uint256 amountBNB) {
        (, amountBNB) = removeLiquidity(
            token,
            WBNB,
            liquidity,
            amountTokenMin,
            amountBNBMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(
            token,
            to,
            IBEP20(token).balanceOf(address(this))
        );
        IBNB(WBNB).withdraw(amountBNB);
        TransferHelper.safeTransferBNB(to, amountBNB);
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first Pool
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = SmartSwapLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));
            address to = i < path.length - 2
                ? SmartSwapLibrary.poolFor(factory, output, path[i + 2])
                : _to;
            ISmartSwapPool(SmartSwapLibrary.poolFor(factory, input, output))
                .swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) returns (uint256[] memory amounts) {
        amounts = SmartSwapLibrary.getAmountsOut(factory, amountIn, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "SmartSwapExchange: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            SmartSwapLibrary.poolFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) returns (uint256[] memory amounts) {
        amounts = SmartSwapLibrary.getAmountsIn(factory, amountOut, path);
        require(
            amounts[0] <= amountInMax,
            "SmartSwapExchange: EXCESSIVE_INPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            SmartSwapLibrary.poolFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    function swapExactBNBForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        virtual
        payable
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WBNB, "SmartSwapExchange: INVALID_PATH");
        amounts = SmartSwapLibrary.getAmountsOut(factory, msg.value, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "SmartSwapExchange: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        IBNB(WBNB).deposit{value: amounts[0]}();
        assert(
            IBNB(WBNB).transfer(
                SmartSwapLibrary.poolFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        _swap(amounts, path, to);
    }

    function swapTokensForExactBNB(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) returns (uint256[] memory amounts) {
        require(
            path[path.length - 1] == WBNB,
            "SmartSwapExchange: INVALID_PATH"
        );
        amounts = SmartSwapLibrary.getAmountsIn(factory, amountOut, path);
        require(
            amounts[0] <= amountInMax,
            "SmartSwapExchange: EXCESSIVE_INPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            SmartSwapLibrary.poolFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IBNB(WBNB).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferBNB(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForBNB(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) returns (uint256[] memory amounts) {
        require(
            path[path.length - 1] == WBNB,
            "SmartSwapExchange: INVALID_PATH"
        );
        amounts = SmartSwapLibrary.getAmountsOut(factory, amountIn, path);
        require(
            amounts[amounts.length - 1] >= amountOutMin,
            "SmartSwapExchange: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            SmartSwapLibrary.poolFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IBNB(WBNB).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferBNB(to, amounts[amounts.length - 1]);
    }

    function swapBNBForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        virtual
        payable
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WBNB, "SmartSwapExchange: INVALID_PATH");
        amounts = SmartSwapLibrary.getAmountsIn(factory, amountOut, path);
        require(
            amounts[0] <= msg.value,
            "SmartSwapExchange: EXCESSIVE_INPUT_AMOUNT"
        );
        IBNB(WBNB).deposit{value: amounts[0]}();
        assert(
            IBNB(WBNB).transfer(
                SmartSwapLibrary.poolFor(factory, path[0], path[1]),
                amounts[0]
            )
        );
        _swap(amounts, path, to);
        // refund dust BNB, if any
        if (msg.value > amounts[0])
            TransferHelper.safeTransferBNB(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first Pool
    function _swapSupportingFeeOnTransferTokens(
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = SmartSwapLibrary.sortTokens(input, output);
            ISmartSwapPool pool = ISmartSwapPool(
                SmartSwapLibrary.poolFor(factory, input, output)
            );
            uint256 amountInput;
            uint256 amountOutput;
            {
                // scope to avoid stack too deep errors
                (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();
                (uint256 reserveInput, uint256 reserveOutput) = input == token0
                    ? (reserve0, reserve1)
                    : (reserve1, reserve0);
                amountInput = IBEP20(input).balanceOf(address(pool)).sub(
                    reserveInput
                );
                amountOutput = SmartSwapLibrary.getAmountOut(
                    amountInput,
                    reserveInput,
                    reserveOutput
                );
            }
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOutput)
                : (amountOutput, uint256(0));
            address to = i < path.length - 2
                ? SmartSwapLibrary.poolFor(factory, output, path[i + 2])
                : _to;
            pool.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) {
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            SmartSwapLibrary.poolFor(factory, path[0], path[1]),
            amountIn
        );
        uint256 balanceBefore = IBEP20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IBEP20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >=
                amountOutMin,
            "SmartSwapExchange: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactBNBForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual payable ensure(deadline) {
        require(path[0] == WBNB, "SmartSwapExchange: INVALID_PATH");
        uint256 amountIn = msg.value;
        IBNB(WBNB).deposit{value: amountIn}();
        assert(
            IBNB(WBNB).transfer(
                SmartSwapLibrary.poolFor(factory, path[0], path[1]),
                amountIn
            )
        );
        uint256 balanceBefore = IBEP20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IBEP20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >=
                amountOutMin,
            "SmartSwapExchange: INSUFFICIENT_OUTPUT_AMOUNT"
        );
    }

    function swapExactTokensForBNBSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual ensure(deadline) {
        require(
            path[path.length - 1] == WBNB,
            "SmartSwapExchange: INVALID_PATH"
        );
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            SmartSwapLibrary.poolFor(factory, path[0], path[1]),
            amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IBEP20(WBNB).balanceOf(address(this));
        require(
            amountOut >= amountOutMin,
            "SmartSwapExchange: INSUFFICIENT_OUTPUT_AMOUNT"
        );
        IBNB(WBNB).withdraw(amountOut);
        TransferHelper.safeTransferBNB(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public virtual pure returns (uint256 amountB) {
        return SmartSwapLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public virtual pure returns (uint256 amountOut) {
        return SmartSwapLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) public virtual pure returns (uint256 amountIn) {
        return SmartSwapLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint256 amountIn, address[] memory path)
        public
        virtual
        view
        returns (uint256[] memory amounts)
    {
        return SmartSwapLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path)
        public
        virtual
        view
        returns (uint256[] memory amounts)
    {
        return SmartSwapLibrary.getAmountsIn(factory, amountOut, path);
    }
}
