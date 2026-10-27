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

/**
 * @title FusingFeeSplitter
 * @notice Protocol fee recipient for every launch created after the
 * factories were pointed at it. A launch snapshots its recipient at
 * creation, so for those launches the lockers deliver the protocol's quote
 * share of fees here (native ETH and ERC-20s alike), and anyone may then
 * divide what has landed: `buybackBps` to the buyback wallet, the remainder
 * to the treasury.
 *
 * The factories also route the launch fee to the protocol fee recipient,
 * and that fee belongs to the treasury in full: when native ETH arrives from
 * one of the factories, `receive` passes it straight on to the treasury
 * rather than holding it for the split. If that forward fails the ETH just
 * sits here and leaves with the next flush; a launch never reverts over it.
 *
 * Nothing here is owned or configurable: the addresses and the proportion
 * are fixed when the contract is deployed. To change the split, deploy a
 * new splitter and point the factories at it, which shows up on chain as
 * `ProtocolFeeRecipientUpdated`.
 *
 * The receive path from the lockers is kept trivial (two address compares)
 * so their 50k-gas native transfer always succeeds; the actual split runs
 * in `flush`, at the caller's expense.
 */
contract FusingFeeSplitter {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Receives `buybackBps` of every flushed asset: the wallet the
    /// protocol's own buyback-and-burn is run from. The name predates V2;
    /// V1 pays the protocol cut straight to the treasury Safe with no splitter in between.
    address public immutable buyback;
    /// @notice Takes the rest of every flush plus the launch fees; funds protocol operations.
    address public immutable treasury;
    /// @notice Portion of each flush sent to `buyback`, in basis points.
    uint16 public immutable buybackBps;
    /// @notice The single-market factory; native ETH it sends is a launch fee.
    address public immutable factory;

    event Flushed(address indexed asset, uint256 toBuyback, uint256 toTreasury);
    /// @notice A factory's launch fee handed on to the treasury in full.
    event LaunchFeeForwarded(address indexed factory, uint256 amount);

    error ZeroAddress();
    error InvalidShare();
    error NativeTransferFailed(address to);

    constructor(address buyback_, address treasury_, uint16 buybackBps_, address factory_) {
        if (buyback_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (factory_ == address(0)) revert ZeroAddress();
        if (buybackBps_ == 0 || buybackBps_ > BASIS_POINTS) revert InvalidShare();
        buyback = buyback_;
        treasury = treasury_;
        buybackBps = buybackBps_;
        factory = factory_;
    }

    receive() external payable {
        if (msg.sender == factory) {
            // A launch fee, which belongs to the treasury whole. The factories
            // send with full gas so the forward has room; on failure the ETH
            // simply waits here for the next flush.
            (bool ok,) = treasury.call{value: msg.value}("");
            if (ok) emit LaunchFeeForwarded(msg.sender, msg.value);
        }
    }

    /**
     * @notice Divides this contract's entire balance of `asset` (address
     * zero for native ETH) between the two recipients. Open to anyone; does
     * nothing when there is no balance.
     */
    function flush(address asset) external returns (uint256 toBuyback, uint256 toTreasury) {
        return _flush(asset);
    }

    /// @notice Runs `flush` over several assets in a single transaction.
    function flushMany(address[] calldata assets) external {
        for (uint256 i = 0; i < assets.length; i++) {
            _flush(assets[i]);
        }
    }

    function _flush(address asset) private returns (uint256 toBuyback, uint256 toTreasury) {
        if (asset == address(0)) {
            uint256 balance = address(this).balance;
            if (balance == 0) return (0, 0);
            toBuyback = (balance * buybackBps) / BASIS_POINTS;
            toTreasury = balance - toBuyback;
            _sendNative(buyback, toBuyback);
            _sendNative(treasury, toTreasury);
        } else {
            IERC20 token = IERC20(asset);
            uint256 balance = token.balanceOf(address(this));
            if (balance == 0) return (0, 0);
            toBuyback = (balance * buybackBps) / BASIS_POINTS;
            toTreasury = balance - toBuyback;
            if (toBuyback > 0) token.safeTransfer(buyback, toBuyback);
            if (toTreasury > 0) token.safeTransfer(treasury, toTreasury);
        }
        emit Flushed(asset, toBuyback, toTreasury);
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to);
    }
}
