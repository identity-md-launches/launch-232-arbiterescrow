// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ArbiterEscrow} from "../src/ArbiterEscrow.sol";

/// @dev Drives valid, interleaved actions with independently tracked liabilities and cash flows.
contract EscrowHandler is Test {
    LaunchToken public immutable currency;
    ArbiterEscrow public immutable app;
    address[6] public actors;
    mapping(address => uint256) public creditModel;
    uint256 public lockedModel;
    uint256 public deposits;
    uint256 public withdrawals;

    constructor(LaunchToken currency_, ArbiterEscrow app_) {
        currency = currency_;
        app = app_;
        for (uint256 i; i < 6; ++i) {
            actors[i] = address(uint160(0x10000 + i));
            vm.prank(actors[i]);
            currency.approve(address(app), type(uint256).max);
        }
    }

    function open(uint256 seed, uint256 rawAmount) external {
        uint256 buyerIndex = seed % 6;
        uint256 sellerIndex = (buyerIndex + 1 + (seed / 6) % 5) % 6;
        uint256 arbiterIndex = (sellerIndex + 1) % 6;
        if (arbiterIndex == buyerIndex) arbiterIndex = (arbiterIndex + 1) % 6;
        address buyer = actors[buyerIndex];
        uint256 balance = currency.balanceOf(buyer);
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance < 10 ** 23 ? balance : 10 ** 23);
        vm.prank(buyer);
        app.open(actors[sellerIndex], actors[arbiterIndex], amount);
        deposits += amount;
        lockedModel += amount;
    }

    function deliver(uint256 seed) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || e.state != ArbiterEscrow.State.Funded) return;
        vm.prank(e.seller);
        app.markDelivered(id);
    }

    function release(uint256 seed) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || uint256(e.state) > 1) return;
        vm.prank(e.buyer);
        app.release(id);
        _closeTo(e, e.seller);
    }

    function refund(uint256 seed) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || uint256(e.state) > 1) return;
        vm.prank(e.seller);
        app.refund(id);
        _closeTo(e, e.buyer);
    }

    function cancel(uint256 seed) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || e.state != ArbiterEscrow.State.Funded || vm.getBlockTimestamp() < e.openedAt + 14 days) {
            return;
        }
        vm.prank(e.buyer);
        app.cancel(id);
        _closeTo(e, e.buyer);
    }

    function dispute(uint256 seed, bool buyerCalls) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || e.state != ArbiterEscrow.State.Delivered) return;
        vm.prank(buyerCalls ? e.buyer : e.seller);
        app.dispute(id);
    }

    function resolve(uint256 seed, uint256 rawBps) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || e.state != ArbiterEscrow.State.Disputed) return;
        uint256 bps = bound(rawBps, 0, 10_000);
        vm.prank(e.arbiter);
        app.resolve(id, bps);
        uint256 fee = e.amount * 100 / 10_000;
        uint256 buyerPart = (e.amount - fee) * bps / 10_000;
        lockedModel -= e.amount;
        creditModel[e.buyer] += buyerPart;
        creditModel[e.seller] += e.amount - fee - buyerPart;
        creditModel[e.arbiter] += fee;
    }

    function claim(uint256 seed) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || e.state != ArbiterEscrow.State.Delivered || vm.getBlockTimestamp() < e.deliveredAt + 30 days) {
            return;
        }
        vm.prank(e.seller);
        app.claimAfterDelivery(id);
        _closeTo(e, e.seller);
    }

    function timeout(uint256 seed) external {
        (uint256 id, ArbiterEscrow.Escrow memory e) = _pick(seed);
        if (id == 0 || e.state != ArbiterEscrow.State.Disputed || vm.getBlockTimestamp() < e.disputedAt + 60 days) {
            return;
        }
        app.timeout(id);
        _recordTimeout(e);
    }

    function withdraw(uint256 seed) external {
        _withdraw(actors[seed % 6]);
    }

    function elapse(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 65 days));
    }

    /// @dev Used by afterInvariant to prove every reachable state has an exit with available parties.
    function finish() external {
        vm.warp(vm.getBlockTimestamp() + 61 days);
        for (uint256 id = 1; id <= app.escrowCount(); ++id) {
            ArbiterEscrow.Escrow memory e = app.escrow(id);
            if (e.state == ArbiterEscrow.State.Funded) {
                vm.prank(e.buyer);
                app.cancel(id);
                _closeTo(e, e.buyer);
            } else if (e.state == ArbiterEscrow.State.Delivered) {
                vm.prank(e.seller);
                app.claimAfterDelivery(id);
                _closeTo(e, e.seller);
            } else if (e.state == ArbiterEscrow.State.Disputed) {
                app.timeout(id);
                _recordTimeout(e);
            }
        }
        for (uint256 i; i < 6; ++i) {
            _withdraw(actors[i]);
        }
    }

    function _pick(uint256 seed) private view returns (uint256 id, ArbiterEscrow.Escrow memory e) {
        uint256 count = app.escrowCount();
        if (count == 0) return (0, e);
        id = seed % count + 1;
        e = app.escrow(id);
    }

    function _closeTo(ArbiterEscrow.Escrow memory e, address recipient) private {
        lockedModel -= e.amount;
        creditModel[recipient] += e.amount;
    }

    function _recordTimeout(ArbiterEscrow.Escrow memory e) private {
        lockedModel -= e.amount;
        creditModel[e.buyer] += e.amount / 2 + e.amount % 2;
        creditModel[e.seller] += e.amount / 2;
    }

    function _withdraw(address actor) private {
        uint256 amount = creditModel[actor];
        if (amount == 0) return;
        uint256 beforeBalance = currency.balanceOf(actor);
        vm.prank(actor);
        app.withdraw();
        assertEq(currency.balanceOf(actor) - beforeBalance, amount);
        creditModel[actor] = 0;
        withdrawals += amount;
    }
}

contract ArbiterEscrowInvariantTest is Test {
    LaunchToken internal currency;
    ArbiterEscrow internal app;
    EscrowHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        currency = new LaunchToken();
        app = new ArbiterEscrow(address(currency));
        handler = new EscrowHandler(currency, app);
        for (uint256 i; i < 6; ++i) {
            currency.transfer(handler.actors(i), 10 ** 26);
        }
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.deliver.selector;
        selectors[2] = handler.release.selector;
        selectors[3] = handler.refund.selector;
        selectors[4] = handler.cancel.selector;
        selectors[5] = handler.dispute.selector;
        selectors[6] = handler.resolve.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.timeout.selector;
        selectors[9] = handler.withdraw.selector;
        selectors[10] = handler.elapse.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balanceEqualsActiveEscrowsPlusCreditsAndIndependentModel() public view {
        uint256 locked;
        uint256 credits;
        for (uint256 id = 1; id <= app.escrowCount(); ++id) {
            ArbiterEscrow.Escrow memory e = app.escrow(id);
            if (e.state != ArbiterEscrow.State.Closed) locked += e.amount;
        }
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            assertEq(app.withdrawable(actor), handler.creditModel(actor));
            credits += app.withdrawable(actor);
        }
        assertEq(locked, handler.lockedModel());
        assertEq(currency.balanceOf(address(app)), locked + credits);
        assertEq(currency.balanceOf(address(app)), handler.deposits() - handler.withdrawals());
        assertEq(currency.totalSupply(), 10 ** 27);
    }

    function afterInvariant() public {
        handler.finish();
        assertEq(currency.balanceOf(address(app)), 0, "all deposited funds remain recoverable");
        assertEq(handler.deposits(), handler.withdrawals());
        assertEq(handler.lockedModel(), 0);
        for (uint256 id = 1; id <= app.escrowCount(); ++id) {
            assertEq(uint256(app.escrow(id).state), uint256(ArbiterEscrow.State.Closed));
        }
        invariant_balanceEqualsActiveEscrowsPlusCreditsAndIndependentModel();
    }
}
