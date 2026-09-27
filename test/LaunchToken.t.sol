// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal constant RECIPIENT = address(0x1001);
    address internal constant SPENDER = address(0x2001);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_supplyAndMetadata() public view {
        assertEq(token.name(), "Arbiter");
        assertEq(token.symbol(), "ARBT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(this)), 10 ** 27);
    }

    function testFuzz_transferMovesExactAmount(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, token.totalSupply());
        assertTrue(token.transfer(RECIPIENT, amount));
        assertEq(token.balanceOf(RECIPIENT), amount);
        assertEq(token.balanceOf(address(this)), 10 ** 27 - amount);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_approveTransferFromAndAllowanceExhaustion() public {
        assertTrue(token.approve(SPENDER, 100));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), RECIPIENT, 100));
        assertEq(token.balanceOf(RECIPIENT), 100);
        assertEq(token.allowance(address(this), SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), RECIPIENT, 1);
    }

    function test_rejectsInsufficientBalanceAndZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, RECIPIENT, 0, 1));
        vm.prank(RECIPIENT);
        token.transfer(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_noAdminOrSupplyChangingSelectorsEvenForDeployer() public {
        string[13] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "burn(uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "setFee(uint256)"
        ];
        address[2] memory callers = [address(this), RECIPIENT];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < selectors.length; ++i) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(abi.encodeWithSignature(selectors[i], RECIPIENT, 10 ** 27));
                assertFalse(ok);
                assertEq(token.totalSupply(), 10 ** 27);
                assertEq(token.balanceOf(address(this)), 10 ** 27);
            }
        }
    }
}
