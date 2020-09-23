pragma solidity ^0.6.0;

import "../BEP20.sol";
import "../interfaces/IBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../lib/SafeBEP20.sol";

interface ISSWAPToken is IBEP20 {
    function mint(address to, uint256 amt) external;

    function burn(address from, uint256 amt) external;
}

// 本交换池仅支持bsc链上的 USDT，DAI，BUSD 兑换
contract StableSwapPool is
    BEP20("Smart Stable Swap Pool 1", "SSSP_1"),
    Ownable,
    ReentrancyGuard
{
    using SafeMath for uint256;
    // This can (and needs to) be changed at compile time
    uint256 private constant N_COINS = 3;

    uint256 private FEE_DENOMINATOR = 10**10;
    uint256 private LENDING_PRECISION = 10**18;
    uint256 private PRECISION = 10**18; // The precision to convert to
    uint256[] private PRECISION_MUL = [1, 1000000000000, 1000000000000];
    uint256[] private RATES = [
        1000000000000000000,
        1000000000000000000000000000000,
        1000000000000000000000000000000
    ];
    uint256 private FEE_INDEX = 2; // Which coin may potentially have fees (USDT)

    uint256 private MAX_ADMIN_FEE = 10 * 10**9;
    uint256 private MAX_FEE = 5 * 10**9;
    uint256 private MAX_A = 10**6;
    uint256 private MAX_A_CHANGE = 10;

    uint256 private ADMIN_ACTIONS_DELAY = 3 * 86400;
    uint256 private MIN_RAMP_TIME = 86400;

    address[] coins;
    uint256[] balances;
    uint256 fee; // fee * 1e10
    uint256 admin_fee; // admin_fee * 1e10

    ISSWAPToken token;

    uint256 initial_A;
    uint256 future_A;
    uint256 initial_A_time;
    uint256 future_A_time;

    uint256 admin_actions_deadline;
    uint256 transfer_ownership_deadline;
    uint256 future_fee;
    uint256 future_admin_fee;
    address future_owner;

    bool is_killed;
    uint256 kill_deadline;
    uint256 private KILL_DEADLINE_DT = 2 * 30 * 86400;
    // Events
    event TokenExchange(
        address buyer,
        uint256 sold_id,
        uint256 tokens_sold,
        uint256 bought_id,
        uint256 tokens_bought
    );

    event AddLiquidity(
        address provider,
        uint256[] token_amounts,
        uint256[] fees,
        uint256 invariant,
        uint256 token_supply
    );

    event RemoveLiquidity(
        address provider,
        uint256[] token_amounts,
        uint256[] fees,
        uint256 token_supply
    );

    event RemoveLiquidityOne(
        address provider,
        uint256 token_amount,
        uint256 coin_amount
    );

    event RemoveLiquidityImbalance(
        address provider,
        uint256[] token_amounts,
        uint256[] fees,
        uint256 invariant,
        uint256 token_supply
    );

    event CommitNewAdmin(uint256 deadline, address admin);

    event NewAdmin(address admin);

    event CommitNewFee(uint256 deadline, uint256 fee, uint256 admin_fee);

    event NewFee(uint256 fee, uint256 admin_fee);

    event RampA(
        uint256 old_A,
        uint256 new_A,
        uint256 initial_time,
        uint256 future_time
    );

    event StopRampA(uint256 A, uint256 t);

    constructor(
        address[] memory _coins,
        address _token,
        uint256 _A,
        uint256 _fee,
        uint256 _admin_fee
    ) public {
        transferOwnership(msg.sender);
        for (uint256 i = 0; i < _coins.length; i++) {
            require(_coins[i] != address(0), "BNB is not support.");
        }
        coins = _coins;
        initial_A = _A;
        future_A = _A;
        fee = _fee;
        admin_fee = _admin_fee;
        kill_deadline = block.timestamp + KILL_DEADLINE_DT;
        token = ISSWAPToken(_token);
    }

    function _A() internal view returns (uint256 A1) {
        // Handle ramping A up or down
        uint256 t1 = future_A_time;
        A1 = future_A;
        if (block.timestamp < t1) {
            uint256 A0 = initial_A;
            uint256 t0 = initial_A_time;
            // Expressions in uint256 cannot have negative numbers, thus "if"
            if (A1 > A0) {
                A1 = A0.add(
                    A1.sub(A0).mul(block.timestamp.sub(t0)).div(t1.sub(t0))
                );
            } else {
                A1 = A0.sub(
                    A0.sub(A1).mul(block.timestamp.sub(t0)).div(t1.sub(t0))
                );
            }
        } else {
            //if (t1 == 0 || block.timestamp >= t1)
            // retrun A1
        }
    }

    function A() external view returns (uint256 A1) {
        A1 = _A();
    }

    function _xp() internal view returns (uint256[] memory result) {
        result = RATES;
        for (uint256 i = 0; i < coins.length; i++) {
            result[i] = result[i].mul(balances[i]).div(LENDING_PRECISION);
        }
    }

    function _xp_mem(uint256[] memory _balances)
        internal
        view
        returns (uint256[] memory result)
    {
        result = RATES;
        for (uint256 i = 0; i < coins.length; i++) {
            result[i] = result[i].mul(_balances[i]).div(PRECISION);
        }
    }

    function get_D(uint256[] memory xp, uint256 amp)
        internal
        pure
        returns (uint256 D)
    {
        uint256 S = 0;
        for (uint256 i = 0; i < xp.length; i++) {
            uint256 _x = xp[i];
            S = S.add(_x);
        }
        if (S == 0) {
            D = 0;
        }
        uint256 Dprev = 0;
        D = S;
        uint256 Ann = amp.mul(uint256(N_COINS));
        for (uint256 i = 0; i < 255; i++) {
            uint256 D_P = D;
            for (uint256 j = 0; j < xp.length; j++) {
                uint256 _x = xp[j];
                D_P = D_P.mul(D).div(_x.mul(uint256(N_COINS))); // If division by 0, this will be borked: only withdrawal will work. And that is good
            }
            Dprev = D;
            uint256 numerator = Ann.mul(S).add(
                D_P.mul(uint256(N_COINS)).mul(D)
            );
            uint256 denominator = Ann.sub(uint256(1)).mul(D).add(
                uint256(N_COINS + 1).mul(D_P)
            );
            D = numerator.div(denominator);
            // Equality with the precision of 1
            if (D > Dprev) {
                if ((D - Dprev) <= 1) {
                    break;
                }
            } else {
                if ((Dprev - D) <= 1) {
                    break;
                }
            }
        }
    }

    function get_D_mem(uint256[] memory _balances, uint256 amp)
        internal
        view
        returns (uint256 D)
    {
        D = get_D(_xp_mem(_balances), amp);
    }

    function get_virtual_price() external view returns (uint256 price) {
        // Returns portfolio virtual price (for calculating profit)
        // scaled up by 1e18
        uint256 D = get_D(_xp(), _A());
        // # D is in the units similar to DAI (e.g. converted to precision 1e18)
        // # When balanced, D = n * x_u - total virtual value of the portfolio
        uint256 token_supply = token.totalSupply();
        price = D.mul(PRECISION).div(token_supply);
    }

    function calc_token_amount(uint256[] calldata amounts, bool deposit)
        external
        view
        returns (uint256 result)
    {
        // Simplified method to calculate addition or reduction in token supply at
        //     deposit or withdrawal without taking fees into account (but looking at
        //     slippage).
        //     Needed to prevent front-running, not for precise calculations!
        uint256[] memory _balances = balances;
        uint256 amp = _A();
        uint256 D0 = get_D_mem(_balances, amp);
        for (uint256 i = 0; i < coins.length; i++) {
            if (deposit) {
                _balances[i] = _balances[i].add(amounts[i]);
            } else {
                _balances[i] = _balances[i].sub(amounts[i]);
            }
        }
        uint256 D1 = get_D_mem(_balances, amp);
        uint256 token_amount = token.totalSupply();
        uint256 diff = 0;
        if (deposit) {
            diff = D1.sub(D0);
        } else {
            diff = D0.sub(D1);
        }
        result = diff.mul(token_amount).div(D0);
    }

    function add_liquidity(uint256[] calldata amounts, uint256 min_mint_amount)
        external
        nonReentrant
    {
        require(is_killed != true, "is killed");
        uint256[] memory fees = new uint256[](N_COINS);
        uint256 _fee = fee.mul(N_COINS).div(uint256(4 * (N_COINS - 1)));
        uint256 _admin_fee = admin_fee;
        uint256 amp = _A();

        uint256 token_supply = token.totalSupply();
        // # Initial invariant
        uint256 D0 = 0;
        uint256[] memory old_balances = balances;
        if (token_supply > 0) {
            D0 = get_D_mem(old_balances, amp);
        }
        uint256[] memory new_balances = old_balances;
        for (uint256 i = 0; i < coins.length; i++) {
            uint256 in_amount = amounts[i];
            if (token_supply == 0) {
                require(in_amount > 0, "initial deposit requires all coins"); // # dev: initial deposit requires all coins
            }
            address in_coin = coins[i];
            if (in_amount > 0) {
                // # Take coins from the sender
                if (i == FEE_INDEX) {
                    in_amount = IBEP20(in_coin).balanceOf(address(this));
                }
                SafeBEP20.safeTransferFrom(
                    IBEP20(in_coin),
                    msg.sender,
                    address(this),
                    amounts[i]
                );
                if (i == FEE_INDEX) {
                    in_amount =
                        IBEP20(in_coin).balanceOf(address(this)) -
                        in_amount;
                }
            }
            new_balances[i] = old_balances[i] + in_amount;
        }
        // # Invariant after change
        uint256 D1 = get_D_mem(new_balances, amp);
        require(D1 > D0, "D1 must bigger than D0");

        // # We need to recalculate the invariant accounting for fees
        // # to calculate fair user's share
        uint256 D2 = D1;
        if (token_supply > 0) {
            for (uint256 i = 0; i < coins.length; i++) {
                uint256 ideal_balance = D1.mul(old_balances[i]).div(D0);
                uint256 difference = 0;
                if (ideal_balance > new_balances[i]) {
                    difference = ideal_balance.sub(new_balances[i]);
                } else {
                    difference = new_balances[i].sub(ideal_balance);
                }
                fees[i] = _fee.mul(difference).div(FEE_DENOMINATOR);
                balances[i] = new_balances[i].sub(
                    fees[i].mul(_admin_fee).div(FEE_DENOMINATOR)
                );
                new_balances[i] -= fees[i];
            }
            D2 = get_D_mem(new_balances, amp);
        } else {
            balances = new_balances;
        }
        // # Calculate, how much pool tokens to mint
        uint256 mint_amount = 0;
        if (token_supply == 0) {
            mint_amount = D1; //# Take the dust if there was any
        } else {
            mint_amount = token_supply.mul(D2.sub(D0)).div(D0);
        }

        require(mint_amount >= min_mint_amount, "Slippage screwed you");

        // # Mint pool tokens
        token.mint(msg.sender, mint_amount);

        emit AddLiquidity(
            msg.sender,
            amounts,
            fees,
            D1,
            token_supply + mint_amount
        );
    }

    function get_y(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[] memory xp_
    ) internal view returns (uint256 y) {
        // # x in the input is converted to the same price/precision
        require(i != j, "dev: same coin");
        require(j >= 0, "dev: j below zero");
        require(j < N_COINS, "dev: j above N_COINS");

        // # should be unreachable, but good for safety
        require(i >= 0, "i must >= 0");
        require(i < N_COINS, "i must < n_coins");
        uint256 amp = _A();
        uint256 D = get_D(xp_, amp);
        uint256 c = D;
        uint256 S_ = 0;
        uint256 Ann = amp.mul(uint256(N_COINS));

        uint256 _x = 0;
        for (uint256 _i = 0; i < coins.length; _i++) {
            if (_i == i) {
                _x = x;
            } else if (_i != j) {
                _x = xp_[_i];
            } else {
                continue;
            }
            S_ = S_.add(_x);
            c = c.mul(D).div(_x.mul(uint256(N_COINS)));
        }
        c = c.mul(D).div(Ann.mul(N_COINS));
        uint256 b = S_.add(D.div(Ann)); //# - D
        uint256 y_prev = 0;
        y = D;
        for (uint256 _i = 0; i < 255; _i++) {
            y_prev = y;
            y = y.mul(y).add(c).div(y.mul(uint256(2)).add(b).sub(D));
            // # Equality with the precision of 1
            if (y > y_prev) {
                if ((y - y_prev) <= 1) {
                    break;
                }
            } else {
                if ((y_prev - y) <= 1) {
                    break;
                }
            }
        }
    }

    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256 result) {
        // # dx and dy in c-units
        uint256[] memory rates = RATES;
        uint256[] memory xp = _xp();

        uint256 x = xp[i].add(dx.mul(rates[i]).div(PRECISION));
        uint256 y = get_y(i, j, x, xp);
        uint256 dy = xp[j].sub(y).sub(1).mul(PRECISION).div(rates[j]);
        uint256 _fee = fee.mul(dy).div(FEE_DENOMINATOR);
        result = dy.sub(_fee);
    }

    function get_dy_underlying(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256 result) {
        //# dx and dy in underlying units
        uint256[] memory xp = _xp();
        uint256[] memory precisions = PRECISION_MUL;

        uint256 x = xp[i].add(dx.mul(precisions[i]));
        uint256 y = get_y(i, j, x, xp);
        uint256 dy = xp[j].sub(y).sub(uint256(1)).div(precisions[j]);
        uint256 _fee = fee.mul(dy).div(FEE_DENOMINATOR);
        result = dy.sub(_fee);
    }

    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external nonReentrant {
        require(is_killed == false, "dev: is killed");
        uint256[] memory rates = RATES;

        uint256[] memory old_balances = balances;
        uint256[] memory xp = _xp_mem(old_balances);

        // # Handling an unexpected charge of a fee on transfer (USDT, PAXG)
        uint256 dx_w_fee = dx;
        address input_coin = coins[i];
        if (i == FEE_INDEX) {
            dx_w_fee = IBEP20(input_coin).balanceOf(address(this));
        }
        // # "safeTransferFrom" which works for ERC20s which return bool or not
        SafeBEP20.safeTransferFrom(
            IBEP20(input_coin),
            msg.sender,
            address(this),
            dx
        );
        if (i == FEE_INDEX) {
            dx_w_fee = IBEP20(input_coin).balanceOf(address(this)).sub(
                dx_w_fee
            );
        }
        uint256 x = xp[i].add(dx_w_fee.mul(rates[i]).div(PRECISION));
        uint256 y = get_y(i, j, x, xp);

        uint256 dy = xp[j].sub(y).sub(uint256(1)); // # -1 just in case there were some rounding errors
        uint256 dy_fee = dy.mul(fee).div(FEE_DENOMINATOR);

        // # Convert all to real units
        dy = dy.sub(dy_fee).mul(PRECISION).div(rates[j]);
        require(dy >= min_dy, "Exchange resulted in fewer coins than expected");

        uint256 dy_admin_fee = dy_fee.mul(admin_fee).div(FEE_DENOMINATOR);
        dy_admin_fee = dy_admin_fee.mul(PRECISION).div(rates[j]);

        // # Change balances exactly in same way as we change actual ERC20 coin amounts
        balances[i] = old_balances[i].add(dx_w_fee);
        // # When rounding errors happen, we undercharge admin fee in favor of LP
        balances[j] = old_balances[j].sub(dy).sub(dy_admin_fee);
        SafeBEP20.safeTransfer(IBEP20(coins[j]), msg.sender, dy);
        emit TokenExchange(msg.sender, i, dx, j, dy);
    }

    function remove_liquidity(uint256 _amount, uint256[] calldata min_amounts)
        external
        nonReentrant
    {
        uint256 total_supply = token.totalSupply();
        uint256[] memory amounts = new uint256[](N_COINS);
        uint256[] memory fees = new uint256[](N_COINS); //  # Fees are unused but we've got them historically in event
        for (uint256 i = 0; i < coins.length; i++) {
            uint256 value = balances[i].mul(_amount).div(total_supply);
            require(
                value >= min_amounts[i],
                "Withdrawal resulted in fewer coins than expected"
            );
            balances[i] = balances[i].sub(value);
            amounts[i] = value;
            SafeBEP20.safeTransfer(IBEP20(coins[i]), msg.sender, value);
        }
        token.burn(msg.sender, _amount); // # dev: insufficient funds

        emit RemoveLiquidity(msg.sender, amounts, fees, total_supply - _amount);
    }

    function remove_liquidity_imbalance(
        uint256[] calldata amounts,
        uint256 max_burn_amount
    ) external nonReentrant {
        require(is_killed == false, "is killed"); //not self.  # dev: is killed

        uint256 token_supply = token.totalSupply();
        require(token_supply != 0, "  # dev: zero total supply");
        uint256 _fee = fee.mul(N_COINS).div(N_COINS.sub(1).mul(4));
        uint256 _admin_fee = admin_fee;
        uint256 amp = _A();

        uint256[] memory old_balances = balances;
        uint256[] memory new_balances = old_balances;
        uint256 D0 = get_D_mem(old_balances, amp);
        for (uint256 i = 0; i < N_COINS; i++) {
            new_balances[i] = new_balances[i].sub(amounts[i]);
        }
        uint256 D1 = get_D_mem(new_balances, amp);
        uint256[] memory fees = new uint256[](N_COINS);
        for (uint256 i = 0; i < N_COINS; i++) {
            uint256 ideal_balance = D1.mul(old_balances[i]).div(D0);
            uint256 difference = 0;
            if (ideal_balance > new_balances[i]) {
                difference = ideal_balance.sub(new_balances[i]);
            } else {
                difference = new_balances[i].sub(ideal_balance);
            }
            fees[i] = _fee.mul(difference).div(FEE_DENOMINATOR);
            balances[i] = new_balances[i].sub(
                fees[i].mul(_admin_fee).div(FEE_DENOMINATOR)
            );
            new_balances[i] = new_balances[i].sub(fees[i]);
        }
        uint256 D2 = get_D_mem(new_balances, amp);

        uint256 token_amount = D0.sub(D2).mul(token_supply).div(D0);
        require(token_amount != 0, " # dev: zero tokens burned");
        token_amount += 1; //  # In case of rounding errors - make it unfavorable for the "attacker"
        require(token_amount <= max_burn_amount, "Slippage screwed you");

        token.burn(msg.sender, token_amount); //  # dev: insufficient funds
        for (uint256 i = 0; i < N_COINS; i++) {
            if (amounts[i] != 0) {
                SafeBEP20.safeTransfer(
                    IBEP20(coins[i]),
                    msg.sender,
                    amounts[i]
                );
            }
        }
        emit RemoveLiquidityImbalance(
            msg.sender,
            amounts,
            fees,
            D1,
            token_supply - token_amount
        );
    }

    function get_y_D(
        uint256 A_,
        uint256 i,
        uint256[] memory xp,
        uint256 D
    ) internal view returns (uint256 y) {
        //Calculate x[i] if one reduces D from being calculated for xp to D
        // Done by solving quadratic equation iteratively.
        // x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
        // x_1**2 + b*x_1 = c
        // x_1 = (x_1**2 + c) / (2*x_1 + b)
        // # x in the input is converted to the same price/precision

        require(i >= 0, "# dev: i below zero");
        require(i < N_COINS, "  # dev: i above N_COINS");

        uint256 c = D;
        uint256 S_ = 0;
        uint256 Ann = A_ * N_COINS;

        uint256 _x = 0;
        for (uint256 _i = 0; _i < N_COINS; _i++) {
            if (_i != i) {
                _x = xp[_i];
            } else {
                continue;
            }
            S_ = S_.add(_x);
            c = c.mul(D).div(_x.mul(N_COINS));
        }
        c = c.mul(D).div(Ann.mul(N_COINS));
        uint256 b = S_.add(D.div(Ann));
        uint256 y_prev = 0;
        y = D;
        for (uint256 _i = 0; _i < 255; _i++) {
            y_prev = y;
            y = y.mul(y).add(c).div(y.mul(uint256(2)).add(b).sub(D));
            // # Equality with the precision of 1
            if (y > y_prev) {
                if ((y - y_prev) <= 1) {
                    break;
                }
            } else {
                if ((y_prev - y) <= 1) {
                    break;
                }
            }
        }
    }

    function _calc_withdraw_one_coin(uint256 _token_amount, uint256 i)
        internal
        view
        returns (uint256 r1, uint256 r2)
    {
        //# First, need to calculate
        // # * Get current D
        // # * Solve Eqn against y_i for D - _token_amount
        uint256 amp = _A();
        uint256 _fee = fee.mul(N_COINS).div(4 * (N_COINS - 1));
        uint256[] memory precisions = PRECISION_MUL;
        uint256 total_supply = token.totalSupply();

        uint256[] memory xp = _xp();

        uint256 D0 = get_D(xp, amp);
        uint256 D1 = D0.sub(_token_amount.mul(D0).div(total_supply));
        uint256[] memory xp_reduced = xp;

        uint256 new_y = get_y_D(amp, i, xp, D1);
        uint256 dy_0 = xp[i].sub(new_y).div(precisions[i]); //# w/o fees

        for (uint256 j = 0; j < N_COINS; j++) {
            uint256 dx_expected = 0;
            if (j == i) {
                dx_expected = xp[j].mul(D1).div(D0).sub(new_y);
            } else {
                dx_expected = xp[j].sub(xp[j].mul(D1).div(D0));
            }
            xp_reduced[j] = xp_reduced[j].sub(
                _fee.mul(dx_expected).div(FEE_DENOMINATOR)
            );
        }
        uint256 dy = xp_reduced[i].sub(get_y_D(amp, i, xp_reduced, D1));
        dy = dy.sub(uint256(1)).div(precisions[i]); // # Withdraw less to account for rounding errors
        r1 = dy;
        r2 = dy_0 - dy;
    }

    function calc_withdraw_one_coin(uint256 _token_amount, uint256 i)
        external
        view
        returns (uint256 result)
    {
        (result, ) = _calc_withdraw_one_coin(_token_amount, i);
    }
}
