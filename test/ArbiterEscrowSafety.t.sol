// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ArbiterEscrow} from "../src/ArbiterEscrow.sol";

/// @dev An adversarial dependency fixture, never a deployment currency.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        False,
        Revert,
        NoReturn
    }

    Mode public pullMode;
    Mode public pushMode;
    address public blockedRecipient;
    ArbiterEscrow public app;
    bytes public callback;
    bool public hookPull;
    bool public hookPush;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public observedCredit;

    error TokenRefused();

    constructor() ERC20("Adversarial test fixture", "TEST") {
        _mint(msg.sender, 10 ** 27);
    }

    function configureModes(Mode pull, Mode push) external {
        pullMode = pull;
        pushMode = push;
    }

    function blockRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function configureCallback(ArbiterEscrow app_, bytes memory data, bool onPull, bool onPush) external {
        app = app_;
        callback = data;
        hookPull = onPull;
        hookPush = onPush;
    }

    function collect(ArbiterEscrow app_) external {
        app_.withdraw();
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (pullMode == Mode.False) return false;
        if (pullMode == Mode.Revert) revert TokenRefused();
        super.transferFrom(from, to, amount);
        if (hookPull) _callback();
        if (pullMode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (pushMode == Mode.False || to == blockedRecipient) return false;
        if (pushMode == Mode.Revert) revert TokenRefused();
        super.transfer(to, amount);
        if (hookPush) _callback();
        if (pushMode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _callback() private {
        observedCredit = app.withdrawable(address(this));
        (callbackSucceeded, callbackResult) = address(app).call(callback);
    }
}

/// @dev ARBT transfers do not invoke recipient hooks, so rejecting ETH cannot block withdrawal.
contract RejectingEtherRecipient {
    receive() external payable {
        revert("reject ETH");
    }

    function collect(ArbiterEscrow app) external {
        app.withdraw();
    }
}

contract ArbiterEscrowSafetyTest is Test {
    AdversarialToken internal currency;
    ArbiterEscrow internal app;
    address internal constant SELLER = address(0x5001);
    address internal constant ARBITER = address(0xA001);
    uint256 internal constant AMOUNT = 10_001;

    function setUp() public {
        currency = new AdversarialToken();
        app = new ArbiterEscrow(address(currency));
        currency.approve(address(app), type(uint256).max);
    }

    function test_falseReturningPullRollsBackIdStateAndBalances() public {
        currency.configureModes(AdversarialToken.Mode.False, AdversarialToken.Mode.Normal);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(currency)));
        app.open(SELLER, ARBITER, AMOUNT);
        assertEq(app.escrowCount(), 0);
        assertEq(currency.balanceOf(address(app)), 0);
        currency.configureModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal);
        assertEq(app.open(SELLER, ARBITER, AMOUNT), 1);
    }

    function test_revertingPullRollsBackIdAndBubblesFailure() public {
        currency.configureModes(AdversarialToken.Mode.Revert, AdversarialToken.Mode.Normal);
        vm.expectRevert(AdversarialToken.TokenRefused.selector);
        app.open(SELLER, ARBITER, AMOUNT);
        assertEq(app.escrowCount(), 0);
        assertEq(currency.balanceOf(address(app)), 0);
    }

    function test_noReturnTokenSupportedOnDepositAndWithdrawal() public {
        currency.configureModes(AdversarialToken.Mode.NoReturn, AdversarialToken.Mode.NoReturn);
        uint256 id = app.open(SELLER, ARBITER, AMOUNT);
        app.release(id);
        vm.prank(SELLER);
        app.withdraw();
        assertEq(currency.balanceOf(SELLER), AMOUNT);
        assertEq(app.withdrawable(SELLER), 0);
        assertEq(currency.balanceOf(address(app)), 0);
    }

    function test_failedWithdrawRestoresCreditAndDoesNotBlockOtherRecipients() public {
        uint256 one = app.open(SELLER, ARBITER, AMOUNT);
        uint256 two = app.open(SELLER, ARBITER, 2 * AMOUNT);
        app.release(one);
        vm.prank(SELLER);
        app.refund(two);
        currency.blockRecipient(SELLER);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(currency)));
        vm.prank(SELLER);
        app.withdraw();
        assertEq(app.withdrawable(SELLER), AMOUNT);
        assertEq(currency.balanceOf(SELLER), 0);
        assertEq(uint256(app.escrow(one).state), uint256(ArbiterEscrow.State.Closed));
        app.withdraw();
        assertEq(currency.balanceOf(address(app)), AMOUNT);
        currency.blockRecipient(address(0));
        currency.configureModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Revert);
        vm.expectRevert(AdversarialToken.TokenRefused.selector);
        vm.prank(SELLER);
        app.withdraw();
        assertEq(app.withdrawable(SELLER), AMOUNT);
        currency.configureModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal);
        vm.prank(SELLER);
        app.withdraw();
        assertEq(currency.balanceOf(SELLER), AMOUNT);
        assertEq(currency.balanceOf(address(app)), 0);
    }

    function test_everyMutationRejectsReentryDuringDeposit() public {
        bytes[10] memory payloads = [
            abi.encodeCall(app.open, (SELLER, ARBITER, 1)),
            abi.encodeCall(app.markDelivered, (1)),
            abi.encodeCall(app.release, (1)),
            abi.encodeCall(app.refund, (1)),
            abi.encodeCall(app.cancel, (1)),
            abi.encodeCall(app.dispute, (1)),
            abi.encodeCall(app.resolve, (1, 5000)),
            abi.encodeCall(app.claimAfterDelivery, (1)),
            abi.encodeCall(app.timeout, (1)),
            abi.encodeCall(app.withdraw, ())
        ];
        for (uint256 i; i < payloads.length; ++i) {
            currency.configureCallback(app, payloads[i], true, false);
            uint256 id = app.open(SELLER, ARBITER, AMOUNT);
            assertEq(id, i + 1);
            assertFalse(currency.callbackSucceeded());
            assertEq(
                currency.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(uint256(app.escrow(id).state), uint256(ArbiterEscrow.State.Funded));
            assertEq(currency.balanceOf(address(app)), (i + 1) * AMOUNT);
        }
    }

    function test_withdrawClearsCreditBeforeCallAndRejectsReentrantCollection() public {
        uint256 id = app.open(address(currency), ARBITER, AMOUNT);
        app.release(id);
        assertEq(app.withdrawable(address(currency)), AMOUNT);
        currency.configureCallback(app, abi.encodeCall(app.withdraw, ()), false, true);
        currency.collect(app);
        assertFalse(currency.callbackSucceeded());
        assertEq(
            currency.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(currency.observedCredit(), 0);
        assertEq(app.withdrawable(address(currency)), 0);
        assertEq(currency.balanceOf(address(currency)), AMOUNT);
        assertEq(currency.balanceOf(address(app)), 0);
    }

    function test_recipientRejectingEtherCanCollectTokens() public {
        RejectingEtherRecipient seller = new RejectingEtherRecipient();
        uint256 id = app.open(address(seller), ARBITER, AMOUNT);
        app.release(id);
        seller.collect(app);
        assertEq(currency.balanceOf(address(seller)), AMOUNT);
        assertEq(app.withdrawable(address(seller)), 0);
    }
}
