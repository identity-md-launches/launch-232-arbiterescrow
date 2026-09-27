# ABI integration

The checked-in files are plain compiler-generated JSON ABI arrays:

- [`abi/LaunchToken.json`](abi/LaunchToken.json): ERC-20 metadata, total supply, balances,
  allowance, approval, transfer and transferFrom, standard events and errors.
- [`abi/ArbiterEscrow.json`](abi/ArbiterEscrow.json): escrow reads, actions, events and errors.

Run `sh scripts/export-abi.sh` from the repository root after source changes. The pinned
compiler, remappings and vendored sources are the same as for `forge build`.

## Reads

| Function | Return |
| --- | --- |
| `token()` | immutable ARBT address |
| `escrowCount()` | last allocated ID; zero before the first successful deposit |
| `withdrawable(address)` | total uncollected ARBT minor units for that address |
| `escrow(uint256 id)` | tuple described below; missing IDs revert |

Escrow tuple order is `(buyer address, seller address, arbiter address, amount uint256,
openedAt uint256, deliveredAt uint256, disputedAt uint256, state uint8)`.
State values are `0 = Funded`, `1 = Delivered`, `2 = Disputed`, `3 = Closed`.
Timestamps are seconds since the Unix epoch; delivery/dispute timestamps remain zero
until those transitions occur. Closed escrows retain their original amount, parties
and timestamps as history. Their amount is no longer an active liability.

## Transactions

All functions and both constructors are nonpayable. No permit or initialization step is
needed. `open(address seller, address arbiter, uint256 amount)` returns the new ID;
the receipt's `Opened` event is the normal transaction-side way to learn it. First call
`LaunchToken.approve(escrowAddress, amount)` from the buyer. All remaining escrow
actions take a single `uint256 id`, except `resolve(uint256 id, uint256 buyerBps)` and
argument-free `withdraw()`. They return no values. Refer to the README transition table
for required roles, states and timing.

## Events and discovery

| Event | Indexed arguments | Non-indexed arguments |
| --- | --- | --- |
| `Opened` | `buyer`, `seller`, `arbiter` | `id`, `amount` |
| `Delivered`, `Released`, `Refunded`, `Cancelled`, `Disputed`, `Claimed` | `id` | none |
| `Resolved` | `id` | `buyerBps`, `buyerAmount`, `sellerAmount`, `arbiterFee` |
| `TimedOut` | `id` | `buyerAmount`, `sellerAmount` |
| `Withdrawn` | `recipient` | `amount` |

`Opened` uses all three indexed slots for the parties, so its ID is in the log data.
Query it separately for a wallet in each role, combine results by ID, and fetch
`escrow(id)` for current state. Persist the deployment block supplied by services and
use bounded block ranges for RPC log limits. Handle reorgs and refresh from views;
a displayed pending action can lose a race and revert. Enumeration from 1 through
`escrowCount()` is also available. No on-chain list scan or third-party indexer is required.

## Failures

Escrow errors are `InvalidToken`, `InvalidParties`, `InvalidAmount`, `UnknownEscrow(id)`,
`Unauthorized`, `InvalidState`, `TooEarly(availableAt)`, `InvalidBuyerBps`,
`NothingToWithdraw`, and inherited `ReentrancyGuardReentrantCall`.
Missing IDs are checked before role/state checks; role checks precede state, deadline
and split validation. Token errors can bubble up from `safeTransferFrom` or `safeTransfer`;
false return values cause `SafeERC20FailedOperation(token)`. A failed transaction rolls
back all effects and emits no committed events. The complete ABI is authoritative for
error parameter types, including inherited library errors.
