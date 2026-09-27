// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ArbiterEscrow} from "../src/ArbiterEscrow.sol";

contract ArbiterEscrowTest is Test {
    LaunchToken internal currency;
    ArbiterEscrow internal app;
    address internal constant BUYER = address(0xB001);
    address internal constant SELLER = address(0x5001);
    address internal constant ARBITER = address(0xA001);
    address internal constant STRANGER = address(0x9001);
    uint256 internal constant AMOUNT = 10_001;

    function setUp() public {
        vm.warp(1_000_000);
        currency = new LaunchToken();
        app = new ArbiterEscrow(address(currency));
        currency.transfer(BUYER, currency.totalSupply());
        vm.prank(BUYER);
        currency.approve(address(app), type(uint256).max);
    }

    function test_openRecordsPartiesAmountTimeAndEvent() public {
        vm.expectEmit(true, true, true, true, address(app));
        emit ArbiterEscrow.Opened(1, BUYER, SELLER, ARBITER, AMOUNT);
        uint256 id = _open(AMOUNT);
        assertEq(id, 1);
        ArbiterEscrow.Escrow memory e = app.escrow(id);
        assertEq(e.buyer, BUYER);
        assertEq(e.seller, SELLER);
        assertEq(e.arbiter, ARBITER);
        assertEq(e.amount, AMOUNT);
        assertEq(e.openedAt, vm.getBlockTimestamp());
        assertEq(e.deliveredAt, 0);
        assertEq(e.disputedAt, 0);
        assertEq(uint256(e.state), 0);
        assertEq(address(app.token()), address(currency));
        assertEq(_open(2), 2);
        assertEq(app.escrowCount(), 2);
        _assertConservation();
    }

    function test_openRejectsEveryInvalidPartyCombination() public {
        _invalidParties(address(0), SELLER, ARBITER);
        _invalidParties(BUYER, address(0), ARBITER);
        _invalidParties(BUYER, SELLER, address(0));
        _invalidParties(BUYER, BUYER, ARBITER);
        _invalidParties(BUYER, SELLER, BUYER);
        _invalidParties(BUYER, SELLER, SELLER);
        assertEq(app.escrowCount(), 0);
        assertEq(currency.balanceOf(address(app)), 0);
    }

    function test_openRejectsZeroAmount() public {
        vm.expectRevert(ArbiterEscrow.InvalidAmount.selector);
        _open(0);
    }

    function test_failedFundingIsAtomicAndDoesNotConsumeId() public {
        vm.prank(BUYER);
        currency.approve(address(app), AMOUNT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(app), AMOUNT - 1, AMOUNT)
        );
        _open(AMOUNT);
        assertEq(app.escrowCount(), 0);
        assertEq(currency.balanceOf(address(app)), 0);
        vm.prank(BUYER);
        currency.approve(address(app), type(uint256).max);
        uint256 tooMuch = currency.totalSupply() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, BUYER, currency.totalSupply(), tooMuch
            )
        );
        _open(tooMuch);
        assertEq(app.escrowCount(), 0);
        assertEq(_open(AMOUNT), 1);
    }

    /// @dev Enumerates all 4 states x 8 actions x 4 roles with elapsed deadlines.
    function test_everyTransitionByEveryRoleInEveryState() public {
        address[4] memory callers = [BUYER, SELLER, ARBITER, STRANGER];
        for (uint256 state; state < 4; ++state) {
            for (uint256 action; action < 8; ++action) {
                for (uint256 role; role < 4; ++role) {
                    uint256 id = _prepareState(state);
                    vm.warp(vm.getBlockTimestamp() + 100 days);
                    bytes memory callData = _actionData(action, id);
                    bool allowedRole = _allowedRole(action, role);
                    bool allowedState = _allowedState(action, state);
                    uint256 buyerBefore = app.withdrawable(BUYER);
                    uint256 sellerBefore = app.withdrawable(SELLER);
                    uint256 arbiterBefore = app.withdrawable(ARBITER);
                    if (!allowedRole) vm.expectRevert(ArbiterEscrow.Unauthorized.selector);
                    else if (!allowedState) vm.expectRevert(ArbiterEscrow.InvalidState.selector);
                    vm.prank(callers[role]);
                    (bool success,) = address(app).call(callData);
                    // expectRevert handles negative low-level calls; assert positives explicitly.
                    if (allowedRole && allowedState) {
                        assertTrue(success);
                        uint256 expected = action == 0 ? 1 : (action == 4 ? 2 : 3);
                        assertEq(uint256(app.escrow(id).state), expected);
                        if (action == 0) assertEq(app.escrow(id).deliveredAt, vm.getBlockTimestamp());
                        if (action == 4) assertEq(app.escrow(id).disputedAt, vm.getBlockTimestamp());
                        if (action == 1 || action == 6) {
                            assertEq(app.withdrawable(SELLER) - sellerBefore, AMOUNT);
                        } else if (action == 2 || action == 3) {
                            assertEq(app.withdrawable(BUYER) - buyerBefore, AMOUNT);
                        } else if (action == 5) {
                            assertEq(app.withdrawable(BUYER) - buyerBefore, 4950);
                            assertEq(app.withdrawable(SELLER) - sellerBefore, 4951);
                            assertEq(app.withdrawable(ARBITER) - arbiterBefore, 100);
                        } else if (action == 7) {
                            assertEq(app.withdrawable(BUYER) - buyerBefore, 5001);
                            assertEq(app.withdrawable(SELLER) - sellerBefore, 5000);
                            assertEq(app.withdrawable(ARBITER), arbiterBefore);
                        }
                    } else {
                        assertEq(uint256(app.escrow(id).state), state);
                        assertEq(app.withdrawable(BUYER), buyerBefore);
                        assertEq(app.withdrawable(SELLER), sellerBefore);
                        assertEq(app.withdrawable(ARBITER), arbiterBefore);
                    }
                }
            }
        }
        _assertConservation();
    }

    function test_unknownIdsRevertOnViewsAndAllActions() public {
        _open(AMOUNT);
        uint256[3] memory ids = [uint256(0), uint256(2), type(uint256).max];
        for (uint256 i; i < ids.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ArbiterEscrow.UnknownEscrow.selector, ids[i]));
            app.escrow(ids[i]);
            for (uint256 action; action < 8; ++action) {
                vm.expectRevert(abi.encodeWithSelector(ArbiterEscrow.UnknownEscrow.selector, ids[i]));
                (bool success,) = address(app).call(_actionData(action, ids[i]));
                success;
            }
        }
    }

    function test_cancelBoundaryAndCancelWinsDeliveryRace() public {
        uint256 id = _open(AMOUNT);
        uint256 deadline = app.escrow(id).openedAt + 14 days;
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(ArbiterEscrow.TooEarly.selector, deadline));
        vm.prank(BUYER);
        app.cancel(id);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Cancelled(id);
        vm.prank(BUYER);
        app.cancel(id);
        assertEq(app.withdrawable(BUYER), AMOUNT);
        vm.expectRevert(ArbiterEscrow.InvalidState.selector);
        vm.prank(SELLER);
        app.markDelivered(id);
        _assertConservation();
    }

    function test_deliveryWinsCancelRaceAtDay14() public {
        uint256 id = _open(AMOUNT);
        vm.warp(app.escrow(id).openedAt + 14 days);
        _deliver(id);
        vm.expectRevert(ArbiterEscrow.InvalidState.selector);
        vm.prank(BUYER);
        app.cancel(id);
        _dispute(id);
        assertEq(uint256(app.escrow(id).state), uint256(ArbiterEscrow.State.Disputed));
        _assertConservation();
    }

    function test_claimBoundaryAndClaimWinsDisputeRace() public {
        uint256 id = _open(AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _deliver(id);
        uint256 deadline = app.escrow(id).deliveredAt + 30 days;
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(ArbiterEscrow.TooEarly.selector, deadline));
        vm.prank(SELLER);
        app.claimAfterDelivery(id);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Claimed(id);
        vm.prank(SELLER);
        app.claimAfterDelivery(id);
        assertEq(app.withdrawable(SELLER), AMOUNT);
        vm.expectRevert(ArbiterEscrow.InvalidState.selector);
        vm.prank(BUYER);
        app.dispute(id);
        _assertConservation();
    }

    function test_disputeWinsClaimRaceAfterDay30() public {
        uint256 id = _open(AMOUNT);
        _deliver(id);
        vm.warp(app.escrow(id).deliveredAt + 30 days + 1);
        _dispute(id);
        vm.expectRevert(ArbiterEscrow.InvalidState.selector);
        vm.prank(SELLER);
        app.claimAfterDelivery(id);
        assertEq(app.escrow(id).disputedAt, vm.getBlockTimestamp());
        _assertConservation();
    }

    function test_timeoutBoundaryOddUnitAndNoFee() public {
        uint256 id = _open(AMOUNT);
        _deliver(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _dispute(id);
        uint256 deadline = app.escrow(id).disputedAt + 60 days;
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(ArbiterEscrow.TooEarly.selector, deadline));
        app.timeout(id);
        vm.warp(deadline);
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.TimedOut(id, 5001, 5000);
        vm.prank(STRANGER);
        app.timeout(id);
        assertEq(app.withdrawable(BUYER), 5001);
        assertEq(app.withdrawable(SELLER), 5000);
        assertEq(app.withdrawable(ARBITER), 0);
        vm.expectRevert(ArbiterEscrow.InvalidState.selector);
        vm.prank(ARBITER);
        app.resolve(id, 0);
        _assertConservation();
    }

    function test_resolveCanWinTimeoutRaceAtDay60() public {
        uint256 id = _prepareState(2);
        vm.warp(app.escrow(id).disputedAt + 60 days);
        vm.prank(ARBITER);
        app.resolve(id, 0);
        vm.expectRevert(ArbiterEscrow.InvalidState.selector);
        app.timeout(id);
        _assertConservation();
    }

    function test_deliveryAndDisputeEventsAndTimestamps() public {
        uint256 id = _open(AMOUNT);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Delivered(id);
        _deliver(id);
        assertEq(app.escrow(id).deliveredAt, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Disputed(id);
        _dispute(id);
        assertEq(app.escrow(id).disputedAt, vm.getBlockTimestamp());
    }

    function test_releaseRefundAndWithdrawEventsAndIsolation() public {
        uint256 releaseId = _open(AMOUNT);
        uint256 refundId = _open(2 * AMOUNT);
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Released(releaseId);
        vm.prank(BUYER);
        app.release(releaseId);
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Refunded(refundId);
        vm.prank(SELLER);
        app.refund(refundId);
        assertEq(currency.balanceOf(SELLER), 0);
        assertEq(currency.balanceOf(address(app)), 3 * AMOUNT);
        vm.expectRevert(ArbiterEscrow.NothingToWithdraw.selector);
        vm.prank(STRANGER);
        app.withdraw();
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Withdrawn(SELLER, AMOUNT);
        vm.prank(SELLER);
        app.withdraw();
        assertEq(currency.balanceOf(SELLER), AMOUNT);
        assertEq(app.withdrawable(SELLER), 0);
        assertEq(app.withdrawable(BUYER), 2 * AMOUNT);
        vm.expectRevert(ArbiterEscrow.NothingToWithdraw.selector);
        vm.prank(SELLER);
        app.withdraw();
        vm.prank(BUYER);
        app.withdraw();
        assertEq(currency.balanceOf(address(app)), 0);
        _assertConservation();
    }

    function test_multipleEscrowsAccumulateCreditsWithoutPushing() public {
        uint256 id1 = _open(AMOUNT);
        uint256 id2 = _open(AMOUNT * 2);
        vm.startPrank(BUYER);
        app.release(id1);
        app.release(id2);
        vm.stopPrank();
        assertEq(app.withdrawable(SELLER), AMOUNT * 3);
        assertEq(currency.balanceOf(SELLER), 0);
        vm.prank(SELLER);
        app.withdraw();
        assertEq(currency.balanceOf(SELLER), AMOUNT * 3);
        _assertConservation();
    }

    function test_buyerControlledArbiterCannotActUntilSellerAcceptsAndDisputeOccurs() public {
        // ARBITER can be another wallet controlled by BUYER; address separation cannot prove independence.
        uint256 rejected = _open(AMOUNT);
        vm.expectRevert(ArbiterEscrow.InvalidState.selector);
        vm.prank(ARBITER);
        app.resolve(rejected, 10_000);
        vm.prank(SELLER);
        app.refund(rejected);
        uint256 accepted = _open(AMOUNT);
        _deliver(accepted);
        _dispute(accepted);
        vm.prank(ARBITER);
        app.resolve(accepted, 10_000);
        assertEq(app.withdrawable(BUYER), AMOUNT + 9901);
        assertEq(app.withdrawable(ARBITER), 100);
        assertEq(app.withdrawable(SELLER), 0);
        _assertConservation();
    }

    function testFuzz_resolveSplitsConserveEveryUnit(uint256 rawAmount, uint256 rawBps) public {
        uint256 amount = bound(rawAmount, 1, currency.totalSupply());
        uint256 bps = bound(rawBps, 0, 10_000);
        uint256 id = _open(amount);
        _deliver(id);
        _dispute(id);
        uint256 fee = amount * 100 / 10_000;
        uint256 buyerShare = (amount - fee) * bps / 10_000;
        uint256 sellerShare = amount - fee - buyerShare;
        vm.expectEmit(true, false, false, true, address(app));
        emit ArbiterEscrow.Resolved(id, bps, buyerShare, sellerShare, fee);
        vm.prank(ARBITER);
        app.resolve(id, bps);
        assertEq(app.withdrawable(BUYER), buyerShare);
        assertEq(app.withdrawable(SELLER), sellerShare);
        assertEq(app.withdrawable(ARBITER), fee);
        assertEq(buyerShare + sellerShare + fee, amount);
        _assertConservation();
        _withdrawIfAny(BUYER);
        _withdrawIfAny(SELLER);
        _withdrawIfAny(ARBITER);
        assertEq(currency.balanceOf(address(app)), 0);
    }

    function testFuzz_resolveRejectsBpsOver10000(uint256 rawBps) public {
        uint256 id = _prepareState(2);
        vm.expectRevert(ArbiterEscrow.InvalidBuyerBps.selector);
        vm.prank(ARBITER);
        app.resolve(id, bound(rawBps, 10_001, type(uint256).max));
        assertEq(uint256(app.escrow(id).state), 2);
        _assertConservation();
    }

    function test_resolveExplicitRoundingEdges() public {
        uint256[5] memory amounts = [uint256(1), 99, 100, 101, 10_001];
        uint256[3] memory splits = [uint256(0), 1, 10_000];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 j; j < splits.length; ++j) {
                uint256 id = _open(amounts[i]);
                _deliver(id);
                _dispute(id);
                uint256 beforeBuyer = app.withdrawable(BUYER);
                uint256 beforeSeller = app.withdrawable(SELLER);
                uint256 beforeArbiter = app.withdrawable(ARBITER);
                vm.prank(ARBITER);
                app.resolve(id, splits[j]);
                uint256 fee = amounts[i] / 100;
                uint256 buyerPart = (amounts[i] - fee) * splits[j] / 10_000;
                assertEq(app.withdrawable(BUYER) - beforeBuyer, buyerPart);
                assertEq(app.withdrawable(SELLER) - beforeSeller, amounts[i] - fee - buyerPart);
                assertEq(app.withdrawable(ARBITER) - beforeArbiter, fee);
            }
        }
        _assertConservation();
    }

    function testFuzz_timeoutSplitsWithOddUnitToBuyer(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, currency.totalSupply());
        uint256 id = _open(amount);
        _deliver(id);
        _dispute(id);
        vm.warp(app.escrow(id).disputedAt + 60 days);
        app.timeout(id);
        assertEq(app.withdrawable(BUYER), amount / 2 + amount % 2);
        assertEq(app.withdrawable(SELLER), amount / 2);
        assertEq(app.withdrawable(ARBITER), 0);
        _assertConservation();
    }

    function test_directTokenDonationIsUnassignedAndDoesNotAffectLiabilities() public {
        uint256 id = _open(AMOUNT);
        vm.prank(BUYER);
        currency.transfer(address(app), 17);
        vm.prank(BUYER);
        app.release(id);
        vm.prank(SELLER);
        app.withdraw();
        assertEq(currency.balanceOf(address(app)), 17);
        assertEq(app.withdrawable(BUYER), 0);
        assertEq(app.withdrawable(SELLER), 0);
    }

    function _open(uint256 amount) internal returns (uint256 id) {
        vm.prank(BUYER);
        return app.open(SELLER, ARBITER, amount);
    }

    function _deliver(uint256 id) internal {
        vm.prank(SELLER);
        app.markDelivered(id);
    }

    function _dispute(uint256 id) internal {
        vm.prank(BUYER);
        app.dispute(id);
    }

    function _prepareState(uint256 state) internal returns (uint256 id) {
        id = _open(AMOUNT);
        if (state == 1 || state == 2) _deliver(id);
        if (state == 2) _dispute(id);
        if (state == 3) {
            vm.prank(BUYER);
            app.release(id);
        }
    }

    function _invalidParties(address buyer, address seller, address arbiter) internal {
        vm.expectRevert(ArbiterEscrow.InvalidParties.selector);
        vm.prank(buyer);
        app.open(seller, arbiter, AMOUNT);
    }

    function _actionData(uint256 action, uint256 id) internal pure returns (bytes memory) {
        if (action == 0) return abi.encodeCall(ArbiterEscrow.markDelivered, (id));
        if (action == 1) return abi.encodeCall(ArbiterEscrow.release, (id));
        if (action == 2) return abi.encodeCall(ArbiterEscrow.refund, (id));
        if (action == 3) return abi.encodeCall(ArbiterEscrow.cancel, (id));
        if (action == 4) return abi.encodeCall(ArbiterEscrow.dispute, (id));
        if (action == 5) return abi.encodeCall(ArbiterEscrow.resolve, (id, 5000));
        if (action == 6) return abi.encodeCall(ArbiterEscrow.claimAfterDelivery, (id));
        return abi.encodeCall(ArbiterEscrow.timeout, (id));
    }

    function _allowedRole(uint256 action, uint256 role) internal pure returns (bool) {
        if (action == 0 || action == 2 || action == 6) return role == 1;
        if (action == 1 || action == 3) return role == 0;
        if (action == 4) return role < 2;
        if (action == 5) return role == 2;
        return true;
    }

    function _allowedState(uint256 action, uint256 state) internal pure returns (bool) {
        if (action == 0 || action == 3) return state == 0;
        if (action == 1 || action == 2) return state < 2;
        if (action == 4 || action == 6) return state == 1;
        return state == 2;
    }

    function _withdrawIfAny(address account) internal {
        if (app.withdrawable(account) == 0) return;
        vm.prank(account);
        app.withdraw();
    }

    function _assertConservation() internal view {
        uint256 owed = app.withdrawable(BUYER) + app.withdrawable(SELLER) + app.withdrawable(ARBITER);
        for (uint256 id = 1; id <= app.escrowCount(); ++id) {
            ArbiterEscrow.Escrow memory e = app.escrow(id);
            if (e.state != ArbiterEscrow.State.Closed) owed += e.amount;
        }
        assertEq(currency.balanceOf(address(app)), owed);
    }
}
