// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ArbiterEscrow} from "../src/ArbiterEscrow.sol";

contract DeploymentProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

contract DeploymentTest is Test {
    function test_factoryStyleConstructorsRequireNoInitializationOrAllocation() public {
        vm.chainId(11155111);
        DeploymentProbe factory = new DeploymentProbe();
        LaunchToken token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        bytes memory appCode = abi.encodePacked(type(ArbiterEscrow).creationCode, abi.encode(address(token)));
        ArbiterEscrow app = ArbiterEscrow(factory.deploy(appCode, bytes32(uint256(2))));
        assertEq(address(app.token()), address(token));
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(address(factory)), token.totalSupply());
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(app.escrowCount(), 0);
        _checkRuntime(address(token));
        _checkRuntime(address(app));
    }

    function test_constructorRejectsZeroAndNonContractToken() public {
        vm.expectRevert(ArbiterEscrow.InvalidToken.selector);
        new ArbiterEscrow(address(0));
        vm.expectRevert(ArbiterEscrow.InvalidToken.selector);
        new ArbiterEscrow(address(0x1234));
    }

    function test_noPayableConstructorsFunctionsReceiveOrFallback() public {
        LaunchToken token = new LaunchToken();
        ArbiterEscrow app = new ArbiterEscrow(address(token));
        vm.deal(address(this), 100 ether);
        (bool ok,) = address(app).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(app).call("");
        assertFalse(ok);
        (ok,) = address(app).call(hex"deadbeef");
        assertFalse(ok);
        (ok,) = address(app).call{value: 1}(abi.encodeCall(app.open, (address(1), address(2), 100)));
        assertFalse(ok);
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
        bytes memory code = abi.encodePacked(type(ArbiterEscrow).creationCode, abi.encode(address(token)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(code, 32), mload(code))
        }
        assertEq(deployed, address(0));
        code = type(LaunchToken).creationCode;
        assembly ("memory-safe") {
            deployed := create(1, add(code, 32), mload(code))
        }
        assertEq(deployed, address(0));
        assertEq(address(app).balance, 0);
    }

    function test_applicationHasNoAdministrativeEntrypoints() public {
        LaunchToken token = new LaunchToken();
        ArbiterEscrow app = new ArbiterEscrow(address(token));
        string[7] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "pause()",
            "sweep(address)",
            "setToken(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(app).call(abi.encodeWithSignature(signatures[i], address(this)));
            assertFalse(ok);
        }
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
