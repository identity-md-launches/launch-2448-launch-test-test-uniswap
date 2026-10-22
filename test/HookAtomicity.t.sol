// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./TestHook.t.sol";
import {TestHook} from "src/TestHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract NestedClaimProbe is IUnlockCallback {
    IPoolManager private immutable manager;
    TestHook private immutable hook;

    constructor(IPoolManager manager_, TestHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function claimDuringUnlock(PoolId id) external {
        manager.unlock(abi.encode(id));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.claimFees(abi.decode(data, (PoolId)));
        return "";
    }
}

abstract contract HookAtomicity is HookFixture {
    using StateLibrary for IPoolManager;

    function test_failedCoreInitializationDoesNotBindHook() public {
        TestHook fresh = _deployHook("atomic initialization");
        PoolKey memory candidate = key;
        candidate.hooks = IHooks(address(fresh));
        vm.expectRevert();
        factory.initialize(candidate, TickMath.MIN_SQRT_PRICE - 1);
        vm.expectRevert(abi.encodeWithSelector(TestHook.UnknownPool.selector, candidate.toId()));
        fresh.token(candidate.toId());
        factory.initialize(candidate, Q96);
        assertEq(fresh.token(candidate.toId()), address(launchToken));
    }

    function test_unknownKeyCallbacksCannotAffectBoundPool() public {
        PoolKey memory other = key;
        other.fee = 3000;
        SwapParams memory params = _params(false, true, 1 ether);
        bytes memory reason = abi.encodeWithSelector(TestHook.UnknownPool.selector, other.toId());
        vm.prank(address(manager), bob);
        vm.expectRevert(reason);
        hook.beforeSwap(address(router), other, params, "");
        vm.prank(address(manager), bob);
        vm.expectRevert(reason);
        hook.afterSwap(address(router), other, params, BalanceDelta.wrap(0), "");
        assertFalse(hook.hasStarted(poolId));
        assertEq(hook.pendingFees(poolId), 0);
        assertTrue(hook.isAllowed(poolId, alice));
        _assertSettled();
    }

    function test_emptyAndDuplicateAllowlistUpdatesAreIdempotent() public {
        address[] memory empty = new address[](0);
        vm.prank(OWNER);
        hook.setAllowed(poolId, empty, false);
        assertTrue(hook.isAllowed(poolId, alice));
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = alice;
        for (uint256 i; i < 2; ++i) {
            vm.prank(OWNER);
            hook.setAllowed(poolId, accounts, true);
            assertTrue(hook.isAllowed(poolId, alice));
            assertTrue(hook.isAllowed(poolId, bob));
        }
        vm.prank(OWNER);
        hook.setAllowed(poolId, accounts, false);
        assertFalse(hook.isAllowed(poolId, alice));
        assertFalse(hook.isAllowed(poolId, bob));
        assertFalse(hook.hasStarted(poolId));
        assertEq(hook.pendingFees(poolId), 0);
    }

    function testFuzz_failedInputSettlementRollsBackFeePriceAndWindow(uint96 rawAmount, bool mintClaim) public {
        _seed();
        uint256 amount = bound(rawAmount, 100, 10 ether);
        imd.reject(mintClaim ? OWNER : address(0));
        // PoolManager calls afterSwap before the router pays its debt. Make that payment fail.
        deal(IMD, address(router), 0);
        uint256 managerBefore = imd.balanceOf(address(manager));
        uint256 tokenBefore = launchToken.balanceOf(address(router));
        SwapParams memory params = _params(true, true, amount);
        vm.prank(relayer, alice);
        bytes memory inner =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(router), 0, amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                IMD,
                IERC20.transfer.selector,
                inner,
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        router.swap(key, params, "");
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(imd.balanceOf(address(manager)), managerBefore);
        assertEq(launchToken.balanceOf(address(router)), tokenBefore);
        assertEq(hook.pendingFees(poolId), 0);
        assertFalse(hook.hasStarted(poolId));
        assertEq(hook.firstSwapTimestamp(poolId), 0);
        (uint160 price,,,) = manager.getSlot0(poolId);
        assertEq(price, Q96);
        _assertSettled();
        // The failed call must release all locks, so exactly the same trade can be retried.
        imd.mint(address(router), amount);
        _swap(true, true, amount, alice);
        assertTrue(hook.hasStarted(poolId));
        assertEq(imd.balanceOf(OWNER) + hook.pendingFees(poolId), amount / 100);
        _assertSettled();
    }

    function testFuzz_claimSurvivesFullLiquidityExitWhilePaused(uint96 rawAmount, bool buying, bool exactInput) public {
        _seed();
        uint256 amount = bound(rawAmount, 1 ether, 10 ether);
        imd.reject(OWNER);
        _swap(buying, exactInput, amount, alice);
        uint256 pending = hook.pendingFees(poolId);
        assertGt(pending, 0);
        vm.prank(OWNER);
        hook.pause(poolId);
        factory.modify(key, -120, 120, -LIQUIDITY);
        assertEq(manager.getLiquidity(poolId), 0);
        assertEq(hook.pendingFees(poolId), pending);
        // With no LP principal left, the manager must still retain the accrued fee backing.
        assertGe(imd.balanceOf(address(manager)), pending);
        imd.reject(address(0));
        vm.prank(bob);
        assertEq(hook.claimFees(poolId), pending);
        assertEq(imd.balanceOf(OWNER), pending);
        assertEq(hook.pendingFees(poolId), 0);
        assertTrue(hook.paused(poolId));
        _assertSettled();
    }

    function test_nestedUnlockFailureCannotStrandClaimAuthorization() public {
        _seedTokenOnly();
        _swap(true, true, 1 ether, alice);
        uint256 pending = hook.pendingFees(poolId);
        NestedClaimProbe probe = new NestedClaimProbe(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        probe.claimDuringUnlock(poolId);
        assertEq(hook.pendingFees(poolId), pending);
        assertEq(imd.balanceOf(OWNER), 0);
        vm.prank(address(manager));
        vm.expectRevert(TestHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(poolId));
        assertEq(hook.claimFees(poolId), pending);
        assertEq(imd.balanceOf(OWNER), pending);
        _assertSettled();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookAtomicityIMD0Test is HookAtomicity {
    function imdIs0() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract HookAtomicityIMD1Test is HookAtomicity {
    function imdIs0() internal pure override returns (bool) {
        return false;
    }
}
