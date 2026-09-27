// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice ARBT escrow with an agreed arbiter, bounded timeouts, and caller-only pull payments.
/// @dev Intended exclusively for the project's fixed-supply, non-rebasing LaunchToken.
contract ArbiterEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        Funded,
        Delivered,
        Disputed,
        Closed
    }

    struct Escrow {
        address buyer;
        address seller;
        address arbiter;
        uint256 amount;
        uint256 openedAt;
        uint256 deliveredAt;
        uint256 disputedAt;
        State state;
    }

    IERC20 public immutable token;
    uint256 public escrowCount;
    mapping(uint256 => Escrow) private _escrows;
    mapping(address => uint256) public withdrawable;

    error InvalidToken();
    error InvalidParties();
    error InvalidAmount();
    error UnknownEscrow(uint256 id);
    error Unauthorized();
    error InvalidState();
    error TooEarly(uint256 availableAt);
    error InvalidBuyerBps();
    error NothingToWithdraw();

    // The three indexed parties allow a client to discover every role without an indexer.
    event Opened(uint256 id, address indexed buyer, address indexed seller, address indexed arbiter, uint256 amount);
    event Delivered(uint256 indexed id);
    event Released(uint256 indexed id);
    event Refunded(uint256 indexed id);
    event Cancelled(uint256 indexed id);
    event Disputed(uint256 indexed id);
    event Resolved(uint256 indexed id, uint256 buyerBps, uint256 buyerAmount, uint256 sellerAmount, uint256 arbiterFee);
    event Claimed(uint256 indexed id);
    event TimedOut(uint256 indexed id, uint256 buyerAmount, uint256 sellerAmount);
    event Withdrawn(address indexed recipient, uint256 amount);

    /// @param token_ The deployed ARBT LaunchToken address; no approval or funds needed at deployment.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    function escrow(uint256 id) external view returns (Escrow memory) {
        return _get(id);
    }

    /// @notice Open using a prior ARBT approval. The seller accepts all terms by marking delivery.
    function open(address seller, address arbiter, uint256 amount) external nonReentrant returns (uint256 id) {
        if (
            msg.sender == address(0) || seller == address(0) || arbiter == address(0) || msg.sender == seller
                || msg.sender == arbiter || seller == arbiter
        ) revert InvalidParties();
        if (amount == 0) revert InvalidAmount();

        id = ++escrowCount;
        _escrows[id] = Escrow(msg.sender, seller, arbiter, amount, block.timestamp, 0, 0, State.Funded);
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Opened(id, msg.sender, seller, arbiter, amount);
    }

    function markDelivered(uint256 id) external nonReentrant {
        Escrow storage e = _get(id);
        if (msg.sender != e.seller) revert Unauthorized();
        if (e.state != State.Funded) revert InvalidState();
        e.state = State.Delivered;
        e.deliveredAt = block.timestamp;
        emit Delivered(id);
    }

    function release(uint256 id) external nonReentrant {
        Escrow storage e = _get(id);
        if (msg.sender != e.buyer) revert Unauthorized();
        _requireUndisputed(e);
        _closeTo(e, e.seller);
        emit Released(id);
    }

    function refund(uint256 id) external nonReentrant {
        Escrow storage e = _get(id);
        if (msg.sender != e.seller) revert Unauthorized();
        _requireUndisputed(e);
        _closeTo(e, e.buyer);
        emit Refunded(id);
    }

    function cancel(uint256 id) external nonReentrant {
        Escrow storage e = _get(id);
        if (msg.sender != e.buyer) revert Unauthorized();
        if (e.state != State.Funded) revert InvalidState();
        _requireElapsed(e.openedAt + 14 days);
        _closeTo(e, e.buyer);
        emit Cancelled(id);
    }

    function dispute(uint256 id) external nonReentrant {
        Escrow storage e = _get(id);
        if (msg.sender != e.buyer && msg.sender != e.seller) revert Unauthorized();
        if (e.state != State.Delivered) revert InvalidState();
        e.state = State.Disputed;
        e.disputedAt = block.timestamp;
        emit Disputed(id);
    }

    /// @param buyerBps Buyer's share of the amount remaining after the floor-rounded 1% fee.
    function resolve(uint256 id, uint256 buyerBps) external nonReentrant {
        Escrow storage e = _get(id);
        if (msg.sender != e.arbiter) revert Unauthorized();
        if (e.state != State.Disputed) revert InvalidState();
        if (buyerBps > 10_000) revert InvalidBuyerBps();

        uint256 fee = e.amount / 100;
        uint256 rest = e.amount - fee;
        uint256 buyerAmount = Math.mulDiv(rest, buyerBps, 10_000);
        uint256 sellerAmount = rest - buyerAmount;
        e.state = State.Closed;
        withdrawable[e.buyer] += buyerAmount;
        withdrawable[e.seller] += sellerAmount;
        withdrawable[e.arbiter] += fee;
        emit Resolved(id, buyerBps, buyerAmount, sellerAmount, fee);
    }

    function claimAfterDelivery(uint256 id) external nonReentrant {
        Escrow storage e = _get(id);
        if (msg.sender != e.seller) revert Unauthorized();
        if (e.state != State.Delivered) revert InvalidState();
        _requireElapsed(e.deliveredAt + 30 days);
        _closeTo(e, e.seller);
        emit Claimed(id);
    }

    function timeout(uint256 id) external nonReentrant {
        Escrow storage e = _get(id);
        if (e.state != State.Disputed) revert InvalidState();
        _requireElapsed(e.disputedAt + 60 days);
        uint256 sellerAmount = e.amount / 2;
        uint256 buyerAmount = e.amount - sellerAmount;
        e.state = State.Closed;
        withdrawable[e.buyer] += buyerAmount;
        withdrawable[e.seller] += sellerAmount;
        emit TimedOut(id, buyerAmount, sellerAmount);
    }

    /// @notice Collect all credits for the caller; a failed token transfer preserves the credits.
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _get(uint256 id) private view returns (Escrow storage e) {
        if (id == 0 || id > escrowCount) revert UnknownEscrow(id);
        e = _escrows[id];
    }

    function _requireUndisputed(Escrow storage e) private view {
        if (e.state != State.Funded && e.state != State.Delivered) revert InvalidState();
    }

    function _requireElapsed(uint256 availableAt) private view {
        if (block.timestamp < availableAt) revert TooEarly(availableAt);
    }

    function _closeTo(Escrow storage e, address recipient) private {
        e.state = State.Closed;
        withdrawable[recipient] += e.amount;
    }
}
