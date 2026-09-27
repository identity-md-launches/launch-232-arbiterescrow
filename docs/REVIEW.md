# Builder review handoff

This is a source author's analysis and test map. No independent reviewer has approved
this deliverable, no launch manifest is included, and no deployment is claimed.

| Attack / requirement | Reproducible evidence | Residual assumption |
| --- | --- | --- |
| Buyer/seller/arbiter role confusion | `test_everyTransitionByEveryRoleInEveryState`, `test_openRejectsEveryInvalidPartyCombination` | Distinct addresses may share a controller |
| Buyer names its own arbiter | `test_buyerControlledArbiterCannotActUntilSellerAcceptsAndDisputeOccurs` | Seller must vet the arbiter before marking delivery; biased resolution after acceptance is an agreed power |
| Cancel vs delivery | `test_cancelBoundaryAndCancelWinsDeliveryRace`, `test_deliveryWinsCancelRaceAtDay14` | Ordering at/after 14 days determines the surviving path |
| Dispute vs seller claim | `test_claimBoundaryAndClaimWinsDisputeRace`, `test_disputeWinsClaimRaceAfterDay30` | Disputes have no upper time cutoff while Delivered |
| Resolve vs absent-arbiter timeout | `test_timeoutBoundaryOddUnitAndNoFee`, `test_resolveCanWinTimeoutRaceAtDay60` | First successful transaction wins even after 60 days |
| Floor rounding, fee, tiny deposits | `testFuzz_resolveSplitsConserveEveryUnit`, `test_resolveExplicitRoundingEdges`, `testFuzz_timeoutSplitsWithOddUnitToBuyer` | Buyer/seller outcomes can differ by one minor unit as specified |
| Settling or withdrawing twice | Closed-state matrix entries, `test_releaseRefundAndWithdrawEventsAndIsolation` | Closed is terminal; collection requires a positive credit |
| Locked escrow or credit | `ArbiterEscrowInvariantTest.afterInvariant`, explicit boundary tests | At least the appropriate buyer/seller must be able to call; recipients need their keys or a callable contract |
| Insufficient funding, failed payment | `test_failedFundingIsAtomicAndDoesNotConsumeId`, `ArbiterEscrowSafetyTest` | Canonical LaunchToken is immutable and transfers exact amounts |
| Reentrancy during either token call | `test_everyMutationRejectsReentryDuringDeposit`, `test_withdrawClearsCreditBeforeCallAndRejectsReentrantCollection` | Mock callback proves guard behavior; canonical ARBT has no callbacks |
| Funds conserved across IDs and overlapping roles | Independent stateful credit/cash-flow model and per-action invariant | Direct donations create surplus outside deposit accounting |
| Factory constructor caller, token ownership, supply | `DeploymentTest`, `LaunchTokenTest` | Services bind the exact accepted token via `$token`, on Sepolia |

The constructor accepts an existing contract address and cannot prove it is canonical
ARBT. Using an arbitrary malicious, rebasing or fee-on-transfer currency is unsupported.
There is deliberately no administrative remedy for a bad deployment binding, bad party
address, direct token donation, lost key or forced ETH.

The independent source/manifest review should verify the actual token artifact,
`ArbiterEscrow` identifier, sole address constructor argument `["$token"]`, nonpayable
deployment and absence of privileged arguments. Policy signatures and artifact linkage
are handled by services; concrete artifact, constructor, authorization or policy
conflicts are review findings. The supplied protected baseline tests check deployment,
token supply and runtime restrictions and are not a substitute for application review.
