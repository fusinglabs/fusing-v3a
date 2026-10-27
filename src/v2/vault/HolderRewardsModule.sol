// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {FuseModuleBase} from "./FuseModuleBase.sol";
import {Hop, HopKind} from "../libraries/Hop.sol";
import {IFusingLaunchFactory} from "../interfaces/ILaunchpadV2.sol";

interface IRewardsFactory is IFusingLaunchFactory {
    function poolKeyFor(address token) external view returns (PoolKey memory);
    function launchForwarder() external view returns (address);
}

interface IRewardsDeployer {
    function distributorOf(address token) external view returns (address);
}

interface IRewardsDistributor {
    function deposit() external payable;
    function depositToken(address asset, uint256 amount) external;
}

interface IRewardsRouter {
    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        payable
        returns (uint256 amountOut);
    function sellToEth(PoolKey calldata key, bool tokenIsCurrency0, uint256 tokensIn, Hop[] calldata leg, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut);
    function quoteToEth(Currency quote, uint256 amountIn, Hop[] calldata leg, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut);
    function ethToQuote(Currency quote, Hop[] calldata leg, uint256 minQuoteOut, address recipient)
        external
        payable
        returns (uint256 quoteOut);
}

interface IRewardsPricer {
    function route(address quoteToken) external view returns (Hop[] memory hops, bool qualifies);
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) external view returns (uint256);
    function isPriceable(address quoteToken) external view returns (bool);
}

/**
 * @title HolderRewardsModule
 * @notice Pays holders in up to five assets by share. ETH, the launch
 * token and the launch's own quote need no route; any other asset must be
 * priceable by the pricer (it is bought along that route). Each conversion
 * runs in its own try; a share whose swap fails is paid as what the module
 * holds instead, so one bad route never blocks the rest. Deposits go to the
 * launch's holder distributor, which pays every holder above the minimum
 * holding. Params: abi.encode(address[] assets, uint16[] bps).
 */
contract HolderRewardsModule is FuseModuleBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_ASSETS = 5;
    uint256 public constant TOLERANCE_BPS = 300;

    error NoDistributor(address token);

    struct Plan {
        address[] assets;
        uint16[] bps;
    }

    IRewardsFactory public immutable factory;
    IRewardsDeployer public immutable deployer;
    IRewardsRouter public immutable router;
    IRewardsPricer public immutable pricer;
    mapping(address token => Plan) private _plans;

    event Configured(address indexed token, address[] assets, uint16[] bps);
    event Rewarded(address indexed token, address indexed asset, uint256 amount, bool converted);

    constructor(address vault_, IRewardsFactory factory_, IRewardsDeployer deployer_, IRewardsRouter router_, IRewardsPricer pricer_)
        FuseModuleBase(vault_)
    {
        if (address(factory_) == address(0) || address(deployer_) == address(0) || address(router_) == address(0) || address(pricer_) == address(0)) {
            revert ZeroAddress();
        }
        factory = factory_;
        deployer = deployer_;
        router = router_;
        pricer = pricer_;
    }

    function planOf(address token) external view returns (address[] memory assets, uint16[] memory bps) {
        return (_plans[token].assets, _plans[token].bps);
    }

    function configure(address token, bytes calldata params) external onlyVault {
        (address[] memory assets, uint16[] memory bps) = abi.decode(params, (address[], uint16[]));
        _checkShares(assets.length, bps, MAX_ASSETS);
        address quote = factory.getLaunchedToken(token).pairToken;
        for (uint256 i = 0; i < assets.length; i++) {
            address a = assets[i];
            for (uint256 j = 0; j < i; j++) {
                if (assets[j] == a) revert BadParams();
            }
            // Free of routes: ETH, the token, its own quote. Anything else has to be priceable to be bought.
            if (a == address(0) || a == token || a == quote) continue;
            if (!pricer.isPriceable(a)) revert BadParams();
        }
        _plans[token] = Plan({assets: assets, bps: bps});
        emit Configured(token, assets, bps);
    }

    function onFees(address token, address currency, uint256 amount) external payable onlyVault nonReentrant {
        Plan storage p = _plans[token];
        if (p.assets.length == 0) revert BadParams();
        address dist = deployer.distributorOf(token);
        if (dist == address(0)) revert NoDistributor(token);
        // Use what arrived, not what we were told: a taxed quote delivers less.
        amount = _take(currency, amount);
        uint256 n = p.assets.length;
        uint256 handed;
        for (uint256 i = 0; i < n; i++) {
            uint256 share = i + 1 == n ? amount - handed : amount * p.bps[i] / 10_000;
            handed += share;
            if (share == 0) continue;
            address want = p.assets[i];
            if (want == currency) {
                _pay(dist, currency, share);
                emit Rewarded(token, want, share, false);
                continue;
            }
            (address got, uint256 gotAmount) = _convert(token, currency, share, want);
            _pay(dist, got, gotAmount);
            emit Rewarded(token, got, gotAmount, got == want);
        }
    }

    function _pay(address dist, address asset, uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) {
            IRewardsDistributor(dist).deposit{value: amount}();
        } else {
            IERC20(asset).forceApprove(dist, amount);
            IRewardsDistributor(dist).depositToken(asset, amount);
        }
    }

    /// @dev Converts `amount` of `have` into `want` via ETH. Returns what it ended up holding for this share.
    function _convert(address token, address have, uint256 amount, address want) private returns (address, uint256) {
        // Step one: to ETH.
        uint256 eth;
        if (have == address(0)) {
            eth = amount;
        } else {
            eth = _toEth(token, have, amount);
            if (eth == 0) return (have, amount);
        }
        if (want == address(0)) return (address(0), eth);
        // Step two: ETH to the wanted asset.
        uint256 got = _fromEth(token, want, eth);
        if (got == 0) return (address(0), eth);
        return (want, got);
    }

    function _router() private view returns (address r) {
        r = factory.launchForwarder();
        if (r == address(0)) r = address(router);
    }

    function _toEth(address token, address have, uint256 amount) private returns (uint256 got) {
        address r = _router();
        uint256 before = address(this).balance;
        IERC20(have).forceApprove(r, amount);
        if (have == token) {
            PoolKey memory key = factory.poolKeyFor(token);
            bool tokenIs0 = Currency.unwrap(key.currency0) == token;
            Hop[] memory none;
            try IRewardsRouter(r).sellToEth(key, tokenIs0, amount, none, 0, address(this)) {} catch {}
        } else {
            (Hop[] memory hops, bool qualifies) = pricer.route(have);
            if (qualifies && hops.length > 0) {
                uint256 quotePerEth = pricer.priceEthAmountInQuote(have, 1 ether);
                uint256 minOut = quotePerEth == 0 ? 0 : FullMath.mulDiv(amount, 1 ether, quotePerEth) * (10_000 - TOLERANCE_BPS) / 10_000;
                try IRewardsRouter(r).quoteToEth(Currency.wrap(have), amount, hops, minOut, address(this)) {} catch {}
            }
        }
        IERC20(have).forceApprove(r, 0);
        got = address(this).balance - before;
    }

    function _fromEth(address token, address want, uint256 eth) private returns (uint256 got) {
        address r = _router();
        uint256 before = IERC20(want).balanceOf(address(this));
        if (want == token) {
            PoolKey memory key = factory.poolKeyFor(token);
            if (Currency.unwrap(key.currency0) != address(0)) return 0; // buying the token needs its ETH pool
            try IRewardsRouter(r).swapExactIn{value: eth}(key, true, eth, 0, address(this)) {} catch {}
        } else {
            (Hop[] memory hops, bool qualifies) = pricer.route(want);
            if (!qualifies || hops.length == 0) return 0;
            uint256 atSpot = pricer.priceEthAmountInQuote(want, eth);
            uint256 minOut = atSpot * (10_000 - TOLERANCE_BPS) / 10_000;
            // The pricer lists hops from the asset to ETH; buying walks them the other way.
            Hop[] memory leg = new Hop[](hops.length);
            for (uint256 i = 0; i < hops.length; i++) {
                leg[i] = hops[hops.length - 1 - i];
            }
            try IRewardsRouter(r).ethToQuote{value: eth}(Currency.wrap(want), leg, minOut, address(this)) {} catch {}
        }
        got = IERC20(want).balanceOf(address(this)) - before;
    }
}
