// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  fusi.ng  |  the Ethereum launchpad
 *  ----------------------------------
 *  Web:       https://fusi.ng
 *  X:         https://x.com/fusi_ng
 *  Telegram:  https://t.me/fusi_ng
 *  Docs:      https://fusi.ng/docs
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IDeskPricer {
    function priceEthAmountInQuote(address quoteToken, uint256 ethAmount) external view returns (uint256);
}

interface IDeskSettlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
}

interface IDeskWeth is IERC20 {
    function withdraw(uint256 amount) external;
}

interface IDeskVault {
    function deposit(address token, address currency, uint256 amount) external payable;
}

/// @dev Where one stock's sale proceeds land, so WETH from different stocks never mixes. Hands over to the desk only.
contract FuseStockTill {
    address public immutable desk;

    constructor() {
        desk = msg.sender;
    }

    function sweep(IERC20 weth) external returns (uint256 amount) {
        require(msg.sender == desk, "till: desk only");
        amount = weth.balanceOf(address(this));
        if (amount > 0) require(weth.transfer(desk, amount), "till: transfer");
    }
}

/**
 * @title FuseStockDesk
 * @notice Turns fees that arrive as a tokenised stock into ETH. A stock has
 * no pool to sell it into, but solver networks (CoW Protocol) buy it at close
 * to its market price. A contract cannot sign an order, so the desk validates
 * its own (ERC-1271): anyone may post an order on its behalf, and the
 * settlement contract asks the desk whether it stands behind it. It does only
 * when the order sells a stock the desk holds, for WETH, into that stock's
 * own till, at no less than the oracle price less a tolerance, soon, as a
 * plain sell with no fee taken out of the amount. Nobody can make the desk
 * sell cheap or pay anyone else, so posting orders needs no permission.
 *
 * Fees are booked per account when the converter hands them over: a launch's
 * creator side (paid into the Fuse Vault for that launch) or a protocol
 * recipient (paid directly). A sale pays every account of that stock in
 * proportion to what it was owed, by running totals, so the cost of a payout
 * does not grow with the number of launches that pair the same ticker.
 */
contract FuseStockDesk is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes4 private constant MAGIC = 0x1626ba7e;
    bytes32 private constant ORDER_TYPE_HASH = keccak256(
        "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
    );
    bytes32 private constant KIND_SELL = keccak256("sell");
    bytes32 private constant BALANCE_ERC20 = keccak256("erc20");
    uint256 private constant RAY = 1e27;
    uint256 public constant TOLERANCE_BPS = 300;
    uint256 public constant MAX_VALIDITY = 30 minutes;

    /// @dev The order exactly as CoW Protocol hashes it (GPv2Order.Data).
    struct Order {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }

    /// @dev Per stock. `index` scales booked units down as stock is sold; `ethPerUnit` accumulates ETH per scaled unit.
    struct Book {
        uint256 totalScaled;
        uint256 index; // RAY-scaled; starts at RAY
        uint256 ethPerUnit; // RAY-scaled ETH per scaled unit
        uint256 held; // stock the desk believes it holds for this book
        uint256 epoch; // bumps each time the book sells out and starts over
    }

    struct Account {
        uint256 scaled;
        uint256 debt; // ethPerUnit at the last touch
        uint256 unpaid; // ETH earned and not yet sent
        uint256 epoch;
    }

    IDeskSettlement public immutable settlement;
    IDeskPricer public immutable pricer;
    IDeskWeth public immutable weth;
    IDeskVault public immutable vault;
    address public immutable converter;
    address public immutable tillImplementation;
    bytes32 private immutable _TILL_INIT_HASH;

    mapping(address stock => Book) public books;
    /// @dev account id: a launch token (its creator side, paid into the Vault) or a protocol recipient (paid directly).
    mapping(address stock => mapping(address account => Account)) public accounts;
    mapping(address account => bool) public isLaunch;
    /// @dev `ethPerUnit` as it stood when a book's epoch ended, so an account from that epoch is paid up to there and no further.
    mapping(address stock => mapping(uint256 epoch => uint256)) private _epochEnd;

    error NotConverter();
    error NothingToSettle();

    event Booked(address indexed stock, address indexed launchToken, uint256 creatorAmount, address indexed protocolRecipient, uint256 protocolAmount);
    event Sold(address indexed stock, uint256 stockSold, uint256 ethReceived);
    event Paid(address indexed stock, address indexed account, uint256 eth, bool toVault);

    constructor(IDeskSettlement settlement_, IDeskPricer pricer_, IDeskWeth weth_, IDeskVault vault_, address converter_) {
        settlement = settlement_;
        pricer = pricer_;
        weth = weth_;
        vault = vault_;
        converter = converter_;
        tillImplementation = address(new FuseStockTill());
        _TILL_INIT_HASH = keccak256(_tillInitCode());
    }

    receive() external payable {}

    // ------------------------------------------------------------------ booking

    /// @notice The converter hands over a launch's stock fees: the creator side and the protocol's. The stock must already be here.
    function book(address stock, address launchToken, uint256 creatorAmount, address protocolRecipient, uint256 protocolAmount) external {
        if (msg.sender != converter) revert NotConverter();
        Book storage b = books[stock];
        if (b.index == 0) {
            b.index = RAY;
            // The relayer moves the stock when an order fills; the till is where the WETH lands.
            IERC20(stock).forceApprove(settlement.vaultRelayer(), type(uint256).max);
        }
        isLaunch[launchToken] = true;
        _credit(stock, b, launchToken, creatorAmount);
        _credit(stock, b, protocolRecipient, protocolAmount);
        b.held += creatorAmount + protocolAmount;
        emit Booked(stock, launchToken, creatorAmount, protocolRecipient, protocolAmount);
    }

    function _credit(address stock, Book storage b, address account, uint256 amount) private {
        if (amount == 0) return;
        Account storage a = accounts[stock][account];
        _sync(stock, b, a);
        uint256 scaled = amount * RAY / b.index;
        a.scaled += scaled;
        b.totalScaled += scaled;
    }

    /// @dev Brings an account up to date: earnings since its last touch, and out of any epoch that has ended.
    function _sync(address stock, Book storage b, Account storage a) private {
        uint256 upTo = a.epoch == b.epoch ? b.ethPerUnit : _epochEnd[stock][a.epoch];
        a.unpaid += a.scaled * (upTo - a.debt) / RAY;
        if (a.epoch != b.epoch) {
            a.scaled = 0; // everything it was owed of the stock has been sold
            a.epoch = b.epoch;
        }
        a.debt = b.ethPerUnit;
    }

    // ---------------------------------------------------------------- the order

    function tillOf(address stock) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(stock))), _TILL_INIT_HASH)))));
    }

    /// @notice The least WETH the desk accepts for `sellAmount` of `stock` right now: the oracle price less the tolerance.
    function minEthFor(address stock, uint256 sellAmount) public view returns (uint256) {
        uint256 stockPerEth = pricer.priceEthAmountInQuote(stock, 1 ether);
        return sellAmount * 1 ether / stockPerEth * (10_000 - TOLERANCE_BPS) / 10_000;
    }

    function orderDigest(Order memory o) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                o.sellToken,
                o.buyToken,
                o.receiver,
                o.sellAmount,
                o.buyAmount,
                o.validTo,
                o.appData,
                o.feeAmount,
                o.kind,
                o.partiallyFillable,
                o.sellTokenBalance,
                o.buyTokenBalance
            )
        );
        return keccak256(abi.encodePacked(hex"1901", settlement.domainSeparator(), structHash));
    }

    /// @notice ERC-1271. `signature` is the ABI-encoded order; the desk stands behind it only under the rules in the contract notice.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        Order memory o = abi.decode(signature, (Order));
        if (
            orderDigest(o) != hash || books[o.sellToken].index == 0 || o.buyToken != address(weth) || o.receiver != tillOf(o.sellToken)
                || o.sellAmount == 0 || o.sellAmount > IERC20(o.sellToken).balanceOf(address(this)) || o.feeAmount != 0 || o.kind != KIND_SELL
                || o.sellTokenBalance != BALANCE_ERC20 || o.buyTokenBalance != BALANCE_ERC20 || o.validTo > block.timestamp + MAX_VALIDITY
                || o.buyAmount < minEthFor(o.sellToken, o.sellAmount)
        ) return 0xffffffff;
        return MAGIC;
    }

    // ------------------------------------------------------------------ payouts

    /// @notice After a fill: takes the stock's WETH out of its till and shares it across that stock's accounts. Anyone may call it.
    function settle(address stock) external nonReentrant returns (uint256 eth) {
        Book storage b = books[stock];
        address till = tillOf(stock);
        if (till.code.length == 0) {
            bytes memory init = _tillInitCode();
            bytes32 salt = bytes32(uint256(uint160(stock)));
            address made;
            assembly {
                made := create2(0, add(init, 32), mload(init), salt)
            }
            require(made == till, "desk: till");
        }
        eth = FuseStockTill(till).sweep(weth);
        uint256 have = IERC20(stock).balanceOf(address(this));
        uint256 sold = b.held > have ? b.held - have : 0;
        if (eth == 0 || sold == 0 || b.totalScaled == 0) revert NothingToSettle();
        weth.withdraw(eth);
        b.ethPerUnit += eth * RAY / b.totalScaled;
        // Every account's claim on the remaining stock shrinks by the fraction sold.
        b.index = b.index * (b.held - sold) / b.held;
        b.held = have;
        if (b.index == 0) {
            // Sold out: the book starts over, and anything booked later scales from one again.
            _epochEnd[stock][b.epoch] = b.ethPerUnit;
            b.epoch += 1;
            b.index = RAY;
            b.totalScaled = 0;
        }
        emit Sold(stock, sold, eth);
    }

    /// @notice Sends an account what it has earned from `stock`: a launch's creator side into the Vault, a protocol recipient directly.
    function pay(address stock, address account) external nonReentrant returns (uint256 eth) {
        Book storage b = books[stock];
        Account storage a = accounts[stock][account];
        _sync(stock, b, a);
        eth = a.unpaid;
        a.unpaid = 0;
        if (eth == 0) return 0;
        if (isLaunch[account]) {
            vault.deposit{value: eth}(account, address(0), eth);
        } else {
            (bool ok,) = account.call{value: eth, gas: 50_000}("");
            if (!ok) {
                a.unpaid = eth;
                return 0;
            }
        }
        emit Paid(stock, account, eth, isLaunch[account]);
    }

    function _tillInitCode() private view returns (bytes memory) {
        return abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", tillImplementation, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
