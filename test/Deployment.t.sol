// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TestHook} from "../src/TestHook.sol";
import {TestToken} from "../src/TestToken.sol";
import {PoolActor} from "./helpers/PoolActor.sol";

contract DeploymentTest is Test {
    address constant OWNER = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;

    function test_realCreate2DeploymentFromFactoryHasCorrectOwnerAndFlags() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        PoolActor factory = new PoolActor(manager);
        bytes memory initCode =
            abi.encodePacked(type(TestHook).creationCode, abi.encode(manager, OWNER, address(factory)));
        bytes32 hash = keccak256(initCode);
        address predicted;
        uint256 salt;
        for (; salt < 200_000; ++salt) {
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(salt), hash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == 0x20cc) break;
        }
        assertLt(salt, 200_000);
        vm.prank(address(this), makeAddr("launch wallet"));
        address deployed = factory.deployHook(initCode, bytes32(salt));
        assertEq(deployed, predicted);
        assertEq(TestHook(deployed).owner(), OWNER);
        assertEq(TestHook(deployed).factory(), address(factory));
        assertEq(uint160(deployed) & Hooks.ALL_HOOK_MASK, 0x20cc);
        _checkImmutableRuntime(deployed.code);
        _checkImmutableRuntime(address(new TestToken()).code);
    }

    function test_constructorAcceptsNonzeroArgumentsWithoutCodeOnEmptyChain() public {
        address manager = makeAddr("not yet deployed manager");
        address factory = makeAddr("not yet deployed factory");
        address hookAddress = address((uint160(makeAddr("valid hook")) & ~uint160(Hooks.ALL_HOOK_MASK)) | 0x20cc);
        deployCodeTo("TestHook.sol:TestHook", abi.encode(IPoolManager(manager), OWNER, factory), hookAddress);
        assertEq(address(TestHook(hookAddress).poolManager()), manager);
    }

    function test_constructorRejectsZeroArgumentsAndWrongFlags() public {
        IPoolManager manager = IPoolManager(makeAddr("manager"));
        address factory = makeAddr("factory");
        vm.expectRevert(TestHook.InvalidAddress.selector);
        new TestHook(IPoolManager(address(0)), OWNER, factory);
        vm.expectRevert(TestHook.InvalidAddress.selector);
        new TestHook(manager, address(0), factory);
        vm.expectRevert(TestHook.InvalidAddress.selector);
        new TestHook(manager, OWNER, address(0));
        address bad = address(uint160(makeAddr("bad hook")) & ~uint160(Hooks.ALL_HOOK_MASK));
        vm.etch(bad, abi.encodePacked(type(TestHook).creationCode, abi.encode(manager, OWNER, factory)));
        (bool success, bytes memory reason) = bad.call("");
        assertFalse(success);
        assertEq(bytes4(reason), Hooks.HookAddressNotValid.selector);
    }

    function _checkImmutableRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
