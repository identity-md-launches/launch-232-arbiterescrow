# Arbiter (ARBT)

Foundry contract deliverable for the Arbiter escrow project on **Sepolia (11155111)**.
`LaunchToken` is the working currency; `ArbiterEscrow` holds approved deposits and records
off-chain delivery and arbitration decisions. There is no owner, admin, pause, upgrade,
fee setter, or privileged recovery function.

## Build and verify

Use Foundry with Solidity **0.8.26**, pinned by version in `foundry.toml`. Dependencies
are ordinary vendored source files with licenses; no network dependency installation is
needed. The verifier supplies the compiler. FFI and filesystem cheatcode permissions
are not enabled. `bytecode_hash = "none"` is configured for deployment checks.

```sh
forge build
forge test
forge fmt --check
```

Tests use no environment variables, external RPC, wallets, fork, or shared external state.
See [dependency versions and archive hashes](docs/dependencies.md). Regenerate ABI arrays
with `sh scripts/export-abi.sh`; see [ABI documentation](docs/ABI.md).

## Deployment handoff

| Item | Value |
| --- | --- |
| Network | Sepolia, chain ID 11155111 |
| Project kind | `evm_project` |
| Launch token artifact | `src/LaunchToken.sol:LaunchToken` |
| Token constructor arguments / ETH | none / zero |
| Name / symbol / decimals | Arbiter / ARBT / 18 |
| Supply | 1,000,000,000 ARBT = `1000000000000000000000000000` minor units |
| Initial supply recipient | `msg.sender`, the deploying project factory |
| Application artifact | `src/ArbiterEscrow.sol:ArbiterEscrow` |
| Application identifier | `ArbiterEscrow` |
| Constructor | `constructor(address token_)`, nonpayable |
| Manifest constructor arguments | `["$token"]` |
| Application constructor ETH / token allocation | zero / zero |
| Initialization, privileged wallet, later configuration | none |
| Site label for the later frontend stage | `lab-arbiter-escrow` |

The factory creates the token before the escrow. The escrow constructor rejects zero
and addresses without code, stores the token address immutably, and makes no calls or
token transfers. It cannot authenticate an arbitrary ERC-20 as canonical ARBT; the
manifest and deployment services must bind `$token` to this accepted `LaunchToken`.
The application does not impose a chain-ID check: Sepolia-only admission is a service
responsibility. Constructor callers acquire no application powers.

The separate manifest assignment writes `launch.json`; an independent contributor
reviews the accepted contracts and concrete manifest together. Services own policy,
signed artifact linkage, publication, attestation, admission, factory deployment and
the live addresses. These contracts do not need launch-token funds at deploy. The
factory distributes supply to liquidity and rewards under its policy. Users obtain
ARBT by swapping Sepolia ETH in the launch pool and approve the escrow before opening.
No deployment transaction or funded wallet is part of this source contribution.

## Escrow behavior

All amounts are **ARBT minor units**. An ID starts at 1, increments only on successful
funding, and is never reused. `escrow(id)` rejects missing IDs and returns all parties,
the deposited amount, the state and timestamps. Buyer, seller and arbiter must be
nonzero, distinct addresses; the buyer is the caller of `open`.

| Call | Caller | Required state / time | Effect |
| --- | --- | --- | --- |
| `open(seller, arbiter, amount)` | buyer | amount > 0, sufficient balance and prior approval | `safeTransferFrom` funds a new Funded escrow; records `openedAt` |
| `markDelivered(id)` | seller | Funded | Delivered; records `deliveredAt` and accepts all terms |
| `release(id)` | buyer | Funded or Delivered | Closed; full credit to seller |
| `refund(id)` | seller | Funded or Delivered | Closed; full credit to buyer |
| `cancel(id)` | buyer | Funded, at least 14 days after opening | Closed; full credit to buyer |
| `dispute(id)` | buyer or seller | Delivered | Disputed; records `disputedAt` |
| `resolve(id, buyerBps)` | arbiter | Disputed, `buyerBps` in 0…10,000 | Closed; applies the split below |
| `claimAfterDelivery(id)` | seller | Delivered, at least 30 days after delivery | Closed; full credit to seller |
| `timeout(id)` | anyone | Disputed, at least 60 days after dispute | Closed; equal split without fee; buyer receives odd unit |
| `withdraw()` | credited recipient | positive credit | clears all caller credit and transfers ARBT to that caller |

All other roles, states, invalid IDs, premature timeout calls and repeat settlements
revert. No transfer occurs on settlement; credits accumulate across escrows. Withdrawal
uses checks-effects-interactions, `SafeERC20.safeTransfer`, and a reentrancy guard. All
mutating escrow functions share that guard. Failed deposits roll back the ID and state;
failed withdrawals restore the caller's credit and do not block anyone else.

Arbitration charges `floor(amount * 100 / 10000)` to the arbiter (1%, implemented as
`amount / 100`). Let `rest = amount - fee`: the buyer receives
`floor(rest * buyerBps / 10000)` and the seller receives the remainder. A full-precision
multiply/divide avoids intermediate overflow. The three credits sum exactly to the
deposit. Fees below one minor unit round to zero; there is no separate minimum fee.
Timeout uses `seller = floor(amount / 2)` and `buyer = amount - seller`, with no arbiter fee.

## Consent, races and operational responsibilities

Delivery and dispute evidence are handled off-chain. `markDelivered` records the
seller's assertion; it neither proves delivery nor verifies arbiter independence. The
buyer can name a different address it controls as arbiter. **The seller must assess
the buyer, terms and arbiter before marking delivery**, and call `refund` if it does
not accept them. Once disputed, the arbiter may award the entire post-fee amount to
either party. Separate addresses do not establish separate people or impartiality.

Races are first-transaction-wins, including within the same block:

- At and after day 14, `cancel` closes a still-Funded escrow if it lands first.
  If `markDelivered` lands first, cancellation becomes unavailable. Delivery can occur
  after day 14; the buyer can then release or dispute, and the seller can refund or
  eventually claim.
- At and after day 30 from delivery, `dispute` can still beat `claimAfterDelivery`.
  A dispute starts a new 60-day clock and disables the claim. A claim closes the escrow
  and disables dispute. A seller may dispute its own delivery.
- At and after day 60 from dispute, either `resolve` or `timeout` may close the escrow.
  The first successful transaction determines whether the fee and arbitral split apply.

Time checks include the exact deadline second (`>=`). Clocks use block timestamps;
there are no background tasks or automatic transitions. Buyers and sellers must monitor
escrows, submit actions, and pay gas. Anyone may submit a dispute timeout. Recipients
must retain the ability to call `withdraw`; contract parties need callable methods for
their roles and for collection. Choosing an inaccessible address (including this
escrow as a party) can strand that party's credits. No operator can recover lost keys
or redirect a credit. There is no oracle, keeper or randomness dependency.

Accounting for supported escrow calls is:

`ARBT balance = sum(amount of every non-Closed escrow) + sum(withdrawable credits)`.

Ordinary ERC-20 transfers cannot be rejected by their recipient: unsolicited direct
ARBT transfers create an **unassigned surplus**. They are not deposits and are not
recoverable through an admin or sweep path. With such donations, balance is greater
than liabilities by the surplus. Use `approve` followed by `open`, never a direct token
transfer. Fee-on-transfer and rebasing currencies are outside the supported deployment.

The contract has no payable function or receive/fallback handler and rejects ordinary
ETH sends. EVM-level forced ETH can nevertheless bypass those handlers; any forced ETH
is inert and unrecoverable. Escrow accounting and payouts are exclusively ARBT.

## Validation and review handoff

The suite includes the complete four-state/eight-action/four-role transition matrix,
missing IDs, invalid parties, failed approvals and funding, exact 14/30/60-day boundaries,
both orderings of settlement races, all named events, no double settlement or withdrawal,
explicit tiny-amount rounding, 512-run split fuzz tests, withdrawal failure isolation,
token callback attacks, factory-style constructor execution, supply preservation,
runtime size/opcode checks and rejection of ETH and admin calls.

The stateful invariant uses six wallets and randomized interleaved actions, independently
tracks deposits, withdrawals and credits, and checks conservation after every action.
It runs 256 sequences of 128 calls. After every sequence it advances time, exits every
remaining escrow, withdraws all credits and checks that no deposited ARBT remains.
This exercises recovery when the necessary parties can call; it cannot recover a lost key.

These are builder checks, **not an independent security review**. The later independent
review must inspect source plus actual constructor bindings and attack role confusion,
buyer-controlled arbiters, each race ordering, rounding, double settlement, and every
state's exit. [Review notes](docs/REVIEW.md) map these to reproducible tests and trust
assumptions. Independent review and deployment remain subsequent stage responsibilities.

The later one-page frontend reads the currency address from `token()`, shows wallet
balance, allowance and credits, and provides approval/open, role-appropriate actions
and withdrawal. It discovers wallet escrows using the indexed `Opened` parties and
confirms their current state using views (or enumerates IDs through `escrowCount()`).
No backend or indexer is needed. The services build it against reviewed live Sepolia
addresses and export `dist/index.html`; the page explains pool swaps without embedding
a swap. No live addresses are assumed in this contract handoff.
