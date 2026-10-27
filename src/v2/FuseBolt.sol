// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  fusi.ng  |  the Ethereum launchpad
 *  ----------------------------------
 *  Web:       https://fusi.ng
 *  X:         https://x.com/fusi_ng
 *  Telegram:  https://t.me/fusi_ng
 *  Docs:      https://fusi.ng/docs
 *
 *  Fusing V2 contracts. Every launch pays 1.1% per trade, 60% to the creator
 *  and 40% to the protocol, paid out in ETH. V2 puts the terms in the
 *  creator's hands: token limits, fee schedules, anti-sniper windows, holder
 *  rewards, five-way fee splits and the payout mode.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IQuotePricer {
    function probeAmountRequired(address asset) external view returns (uint256);
    function exactTransferProven(address asset) external view returns (bool);
    function proveExactTransfers(address asset, uint256 amount) external;
}

interface IV3SwapRouter {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function refundETH() external payable;
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title FuseBolt
 * @notice Runs the exact-transfer proof for a quote asset on behalf of a
 * creator whose wallet holds nothing but ETH.
 *
 * The proof itself is open and pays for itself by design: any address may
 * call FusingQuotePricer.proveExactTransfers, which pulls the probe amount
 * from the caller and returns it in the same call. That works well for
 * someone already holding the asset and not at all for the creator fusi.ng
 * is built around, who holds ETH and nothing else. Without this contract
 * such a creator would have to buy the asset, approve it, prove it, then
 * sell it back again: four transactions and a position they never asked
 * for, all to clear a check that costs them nothing.
 *
 * This contract collapses that into a single ETH-funded transaction: buy
 * precisely the probe amount, prove, sell it back, return the change. No
 * asset outlives the call, and neither does any ETH.
 *
 * It keeps no funds and has no owner. An asset proven through it is proven
 * for everyone, permanently, exactly as though the creator had done it by
 * hand, and the safety guarantee is untouched: a fee-on-transfer or
 * share-rounding quote still cannot get through, because the round trip
 * inside the pricer is the same round trip. A taxed asset just makes this
 * call revert instead, which is the right outcome and costs nothing but gas.
 *
 * Uniswap V3 only. Any hop the pricer accepts for a candidate quote is
 * measured against WETH or routed through USDC, and in practice the assets
 * creators actually reach for trade on V3. An asset whose only route lives
 * on V4 must be proven by hand; this contract reverts rather than pretend
 * otherwise.
 */
contract FuseBolt is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IQuotePricer public immutable pricer;
    IV3SwapRouter public immutable swapRouter;
    IWETH9 public immutable weth;

    /// @dev The asset is proven already, so there is nothing left to do or to pay for.
    error AlreadyProven(address asset);
    /// @dev The probe priced to zero, meaning the asset's route does not qualify yet.
    error NothingToProve(address asset);
    /// @dev Buying the probe cost more ETH than the caller was willing to spend.
    error TooMuchEth(uint256 spent, uint256 allowed);
    /// @dev The proof ended with this contract still holding the asset, which is never acceptable.
    error AssetStranded(address asset, uint256 balance);
    /// @dev Sending the caller's change back did not succeed.
    error RefundFailed();

    event Proven(address indexed asset, address indexed caller, uint256 probeAmount, uint256 ethSpent);

    constructor(IQuotePricer pricer_, IV3SwapRouter swapRouter_, IWETH9 weth_) {
        pricer = pricer_;
        swapRouter = swapRouter_;
        weth = weth_;
    }

    /**
     * @notice Buys the probe amount of `asset`, runs the exact-transfer
     * proof, sells whatever remains back into ETH and refunds the caller.
     * @param asset The quote asset being proven.
     * @param fee The Uniswap V3 fee tier of the pool pairing the asset with WETH.
     * @dev Send more ETH than the probe costs; the surplus comes back. The
     * probe is roughly one thousandth of the pricer's depth floor, so a few
     * thousandths of an ETH is more than enough.
     */
    function proveWithEth(address asset, uint24 fee) external payable nonReentrant {
        if (pricer.exactTransferProven(asset)) revert AlreadyProven(asset);
        uint256 required = pricer.probeAmountRequired(asset);
        if (required == 0) revert NothingToProve(asset);

        // 1. Buy exactly the probe amount. Exact-output on purpose: if the
        //    price moves between the caller's quote and inclusion, the cost
        //    changes instead of the probe coming up short.
        weth.deposit{value: msg.value}();
        weth.approve(address(swapRouter), msg.value);
        uint256 spentWeth = swapRouter.exactOutputSingle(
            IV3SwapRouter.ExactOutputSingleParams({
                tokenIn: address(weth),
                tokenOut: asset,
                fee: fee,
                recipient: address(this),
                amountOut: required,
                amountInMaximum: msg.value,
                sqrtPriceLimitX96: 0
            })
        );
        if (spentWeth > msg.value) revert TooMuchEth(spentWeth, msg.value);
        weth.approve(address(swapRouter), 0);

        // 2. Prove. The pricer pulls `required` from this contract and sends
        //    it straight back within the same call, reverting unless both
        //    legs land to the wei.
        IERC20(asset).forceApprove(address(pricer), required);
        pricer.proveExactTransfers(asset, required);
        IERC20(asset).forceApprove(address(pricer), 0);

        // 3. Sell the probe back. The caller came for a proof, not a position.
        uint256 held = IERC20(asset).balanceOf(address(this));
        if (held > 0) {
            IERC20(asset).forceApprove(address(swapRouter), held);
            swapRouter.exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: asset,
                    tokenOut: address(weth),
                    fee: fee,
                    recipient: address(this),
                    amountIn: held,
                    // The round trip pays the pool fee twice, and that is
                    // the entire cost of the exercise. There is no price worth
                    // protecting here, and a floor would only strand the asset.
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            IERC20(asset).forceApprove(address(swapRouter), 0);
        }
        uint256 leftover = IERC20(asset).balanceOf(address(this));
        if (leftover > 0) revert AssetStranded(asset, leftover);

        // 4. Sweep. This contract keeps no state and is meant to hold nothing
        //    between calls, so the full balance is returned rather than a
        //    computed difference: a delta would have to be correct on every
        //    path through the call to avoid stranding change, whereas a sweep
        //    cannot get that wrong. Any dust sent here goes to the next caller.
        uint256 wethBal = weth.balanceOf(address(this));
        if (wethBal > 0) weth.withdraw(wethBal);
        uint256 refund = address(this).balance;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }

        uint256 spent = refund >= msg.value ? 0 : msg.value - refund;
        emit Proven(asset, msg.sender, required, spent);
    }

    /// @notice The amount `proveWithEth` will need, so a caller can size the ETH they send.
    function probeAmount(address asset) external view returns (uint256) {
        return pricer.probeAmountRequired(asset);
    }

    receive() external payable {}
}
