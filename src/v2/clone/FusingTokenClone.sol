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
 *  Launched on fusi.ng V3. Every launch pays 1.1% per trade, 60% to the
 *  creator side and 40% to the protocol. This token has no owner, no mint
 *  function, no pause and no blacklist, and its code can never change:
 *  it is an EIP-1167 minimal proxy, which has no upgrade path at all.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title FusingTokenClone
 * @notice The scanner trial for cloned launch tokens: one implementation,
 * and every launch a 45-byte EIP-1167 proxy of it, which is what takes a
 * launch from about 4M gas to a little over 1M. A clone has no constructor,
 * so the name, symbol and supply arrive through `initialize`, once.
 */
contract FusingTokenClone is ERC20, ERC20Burnable {
    string private _cloneName;
    string private _cloneSymbol;
    bool public initialized;
    address public launchFactory;

    error AlreadyInitialized();

    /// @dev The implementation itself is sealed so nobody can initialise it and pass it off as a launch.
    constructor() ERC20("", "") {
        initialized = true;
    }

    function initialize(string calldata name_, string calldata symbol_, address supplyRecipient, uint256 supply, address launchFactory_) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        _cloneName = name_;
        _cloneSymbol = symbol_;
        launchFactory = launchFactory_;
        _mint(supplyRecipient, supply);
    }

    function name() public view override returns (string memory) {
        return _cloneName;
    }

    function symbol() public view override returns (string memory) {
        return _cloneSymbol;
    }

    /// @notice Nobody owns, mints or pauses this token. Provided so scanners probing for a renounced owner see the zero address.
    function owner() external pure returns (address) {
        return address(0);
    }
}

/// @notice Deploys clones at CREATE2 addresses, so a vanity ending can still be mined, and initialises each in the same transaction.
contract FusingTokenCloner {
    address public immutable implementation;

    event Cloned(address indexed token, string name, string symbol);

    constructor() {
        implementation = address(new FusingTokenClone());
    }

    function clone(bytes32 salt, string calldata name_, string calldata symbol_, address supplyRecipient, uint256 supply) external returns (address token) {
        bytes memory init = abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
        assembly {
            token := create2(0, add(init, 32), mload(init), salt)
        }
        require(token != address(0), "cloner: create2");
        FusingTokenClone(token).initialize(name_, symbol_, supplyRecipient, supply, msg.sender);
        emit Cloned(token, name_, symbol_);
    }
}
