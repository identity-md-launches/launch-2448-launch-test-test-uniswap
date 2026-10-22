// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TestToken} from "../src/TestToken.sol";
import {TestHook} from "../src/TestHook.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolActor} from "./helpers/PoolActor.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant OWNER = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;
    uint160 internal constant FLAGS = 0x20cc;
    uint160 internal constant Q96 = 79228162514264337593543950336;
    int256 internal constant LIQUIDITY = 1e24;
    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager internal manager;
    PoolActor internal factory;
    PoolActor internal router;
    TestHook internal hook;
    TestToken internal launchToken;
    MockIMD internal imd;
    PoolKey internal key;
    PoolId internal poolId;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");

    function imdIs0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.warp(1_000_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new PoolActor(manager);
        router = new PoolActor(manager);
        deployCodeTo("MockIMD.sol:MockIMD", IMD);
        imd = MockIMD(IMD);
        // Exercise the actual immutable launch token in either sort order.
        address tokenAddress = imdIs0() ? address(uint160(IMD) + 1) : address(uint160(IMD) - 1);
        deployCodeTo("TestToken.sol:TestToken", tokenAddress);
        launchToken = TestToken(tokenAddress);
        assertTrue(launchToken.transfer(address(factory), 100_000_000 ether));
        assertTrue(launchToken.transfer(address(router), 100_000_000 ether));
        imd.mint(address(factory), 1e27);
        imd.mint(address(router), 1e27);
        hook = _deployHook("hook");
        key = PoolKey({
            currency0: Currency.wrap(imdIs0() ? IMD : tokenAddress),
            currency1: Currency.wrap(imdIs0() ? tokenAddress : IMD),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        factory.initialize(key, Q96);
        _allow(alice, true);
    }

    function _deployHook(string memory label) internal returns (TestHook deployed) {
        address at = address((uint160(makeAddr(label)) & ~uint160(Hooks.ALL_HOOK_MASK)) | FLAGS);
        deployCodeTo("TestHook.sol:TestHook", abi.encode(manager, OWNER, address(factory)), at);
        deployed = TestHook(at);
    }

    function _allow(address wallet, bool allowed) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = wallet;
        vm.prank(OWNER);
        hook.setAllowed(poolId, accounts, allowed);
    }

    function _seed() internal {
        factory.modify(key, -120, 120, LIQUIDITY);
    }

    function _seedTokenOnly() internal {
        if (imdIs0()) factory.modify(key, -120, -60, LIQUIDITY);
        else factory.modify(key, 60, 120, LIQUIDITY);
        assertEq(imd.balanceOf(address(manager)), 0);
        assertGt(launchToken.balanceOf(address(manager)), 0);
    }

    function _params(bool buying, bool exactInput, uint256 amount) internal pure returns (SwapParams memory) {
        bool zeroForOne = buying == imdIs0();
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _swap(bool buying, bool exactInput, uint256 amount, address origin) internal returns (BalanceDelta) {
        SwapParams memory params = _params(buying, exactInput, amount);
        vm.prank(relayer, origin);
        return router.swap(key, params, "");
    }

    function _pair(BalanceDelta delta) internal pure returns (int128) {
        return imdIs0() ? delta.amount0() : delta.amount1();
    }

    function _token(BalanceDelta delta) internal pure returns (int128) {
        return imdIs0() ? delta.amount1() : delta.amount0();
    }

    function _abs(int128 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-int256(value)) : uint256(int256(value));
    }

    function _coreDelta(Vm.Log[] memory logs) internal view returns (BalanceDelta) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return toBalanceDelta(a0, a1);
            }
        }
        revert("missing core Swap event");
    }

    function _assertSettled() internal view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(launchToken.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), hook.pendingFees(poolId));
    }
}

abstract contract HookBehavior is HookFixture {
    using StateLibrary for IPoolManager;

    function test_initializationPermissionsAndSupply() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterAddLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(hook.owner(), OWNER);
        assertEq(hook.factory(), address(factory));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(poolId), address(launchToken));
        assertEq(hook.totalSupply(poolId), launchToken.totalSupply());
        assertEq(hook.totalSupply(poolId), 1e27);
        assertFalse(hook.hasStarted(poolId));
        assertTrue(hook.allowlistActive(poolId));
    }

    function test_onlyFactoryCanInitializeAndOnlyOnePool() public {
        TestHook fresh = _deployHook("fresh hook");
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        vm.expectRevert();
        manager.initialize(freshKey, Q96);
        factory.initialize(freshKey, Q96);
        assertEq(fresh.token(freshKey.toId()), address(launchToken));
        PoolKey memory otherKey = freshKey;
        otherKey.tickSpacing = 120;
        vm.expectRevert();
        factory.initialize(otherKey, Q96);
    }

    function test_rejectsWrongPairFeeAndSpacing() public {
        TestHook fresh = _deployHook("fresh hook");
        PoolKey memory wrong = key;
        wrong.hooks = IHooks(address(fresh));
        wrong.fee = 0;
        vm.expectRevert();
        factory.initialize(wrong, Q96);
        wrong.fee = 0x800000;
        vm.expectRevert();
        factory.initialize(wrong, Q96);
        wrong.fee = 12_500;
        wrong.tickSpacing = 120;
        vm.expectRevert();
        factory.initialize(wrong, Q96);
        wrong.tickSpacing = 60;
        wrong.currency0 = Currency.wrap(address(uint160(IMD) - 2));
        wrong.currency1 = Currency.wrap(address(uint160(IMD) + 2));
        vm.expectRevert();
        factory.initialize(wrong, Q96);
        wrong.currency0 = Currency.wrap(address(0));
        wrong.currency1 = Currency.wrap(IMD);
        vm.expectRevert();
        factory.initialize(wrong, Q96);
    }

    function test_callbacksRejectNonManagerAndForgedUnlock() public {
        SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(factory), key, Q96);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(router), key, params, "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(poolId));
        vm.prank(address(manager));
        vm.expectRevert(TestHook.UnexpectedUnlock.selector);
        hook.unlockCallback(abi.encode(poolId));
    }

    function test_onlyOwnerMayChangePauseAndAllowlist() public {
        address[] memory accounts = new address[](1);
        accounts[0] = bob;
        vm.prank(bob, OWNER);
        vm.expectRevert(TestHook.OnlyOwner.selector);
        hook.pause(poolId);
        vm.prank(address(factory));
        vm.expectRevert(TestHook.OnlyOwner.selector);
        hook.unpause(poolId);
        vm.expectRevert(TestHook.OnlyOwner.selector);
        hook.setAllowed(poolId, accounts, true);
        _allow(bob, true);
        assertTrue(hook.isAllowed(poolId, bob));
        _allow(bob, false);
        assertFalse(hook.isAllowed(poolId, bob));
    }

    function test_pauseBlocksBothDirectionsButFactoryAndLPsCanExit() public {
        _seed();
        _swap(true, true, 1 ether, alice);
        vm.prank(OWNER);
        hook.pause(poolId);
        assertTrue(hook.paused(poolId));
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = _params(i < 2, i % 2 == 0, 1 ether);
            vm.expectRevert();
            router.swap(key, params, "");
        }
        BalanceDelta collected = factory.modify(key, -120, 120, 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertGt(_pair(collected), 0);
        factory.modify(key, -120, 120, 1e18);
        BalanceDelta removed = factory.modify(key, -120, 120, -(LIQUIDITY + 1e18));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        // An ordinary LP has the same unconditional access to its position.
        router.modify(key, -120, 120, 1e18);
        router.modify(key, -120, 120, -1e18);
        _seed();
        vm.prank(OWNER);
        hook.unpause(poolId);
        assertFalse(hook.paused(poolId));
        _swap(false, true, 1 ether, bob);
        _assertSettled();
    }

    function test_allowlistStartsOnFirstSwapAndExpiresAtExactly900Seconds() public {
        _seed();
        vm.warp(block.timestamp + 30 days);
        SwapParams memory params = _params(true, true, 1 ether);
        vm.prank(relayer, bob);
        vm.expectRevert();
        router.swap(key, params, abi.encode(alice));
        assertFalse(hook.hasStarted(poolId));
        assertEq(hook.firstSwapTimestamp(poolId), 0);
        _swap(true, true, 1 ether, alice);
        uint256 start = hook.firstSwapTimestamp(poolId);
        assertEq(start, block.timestamp);
        assertTrue(hook.hasStarted(poolId));
        vm.warp(start + 899);
        vm.prank(relayer, bob);
        vm.expectRevert();
        router.swap(key, params, "");
        vm.warp(start + 900);
        assertFalse(hook.allowlistActive(poolId));
        _swap(true, true, 1 ether, bob);
        assertEq(hook.firstSwapTimestamp(poolId), start);
    }

    function test_sellStartsWindowAndDoesNotNeedAllowlist() public {
        _seed();
        _swap(false, true, 1 ether, bob);
        assertEq(hook.firstSwapTimestamp(poolId), block.timestamp);
        assertTrue(hook.allowlistActive(poolId));
        _swap(false, false, 1 ether, bob);
        _allow(alice, false);
        SwapParams memory params = _params(true, false, 1 ether);
        vm.prank(relayer, alice);
        vm.expectRevert();
        router.swap(key, params, "");
        _allow(bob, true);
        _swap(true, false, 1 ether, bob);
    }

    function test_sharedRelayerUsesOriginAndIgnoresHookData() public {
        _seed();
        _allow(relayer, true);
        _allow(address(router), true);
        SwapParams memory params = _params(true, true, 1 ether);
        vm.prank(relayer, bob);
        vm.expectRevert();
        router.swap(key, params, abi.encode(alice));
        vm.prank(relayer, alice);
        router.swap(key, params, abi.encode(bob));
        _allow(bob, true);
        _swap(true, true, 1 ether, bob);
    }

    function test_zeroTimestampIsNotAnUnstartedSentinel() public {
        _seed();
        vm.warp(0);
        _swap(false, true, 1 ether, bob);
        assertTrue(hook.hasStarted(poolId));
        assertEq(hook.firstSwapTimestamp(poolId), 0);
        vm.warp(900);
        _swap(true, true, 1 ether, bob);
        assertEq(hook.firstSwapTimestamp(poolId), 0);
    }

    function test_pauseDoesNotRestartOrExtendWindow() public {
        _seed();
        _swap(false, true, 1 ether, bob);
        uint256 start = block.timestamp;
        vm.prank(OWNER);
        hook.pause(poolId);
        vm.warp(start + 900);
        vm.prank(OWNER);
        hook.unpause(poolId);
        _swap(true, true, 1 ether, bob);
        assertEq(hook.firstSwapTimestamp(poolId), start);
    }

    function test_allFourSwapModesPayExactlyOnePercentOfGrossIMD() public {
        _seed();
        for (uint256 i; i < 4; ++i) {
            _checkTrade(i < 2, i % 2 == 0, 1 ether + i, false);
        }
    }

    function testFuzz_feeConservation(bool buying, bool exactInput, uint256 amount) public {
        _seed();
        amount = bound(amount, 100, 100 ether);
        _checkTrade(buying, exactInput, amount, false);
    }

    function test_dustAndFeeRoundingBoundariesInAllModes() public {
        _seed();
        uint256[7] memory amounts = [uint256(1), 98, 99, 100, 101, 9999, 10_000];
        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 j; j < 4; ++j) {
                _checkTrade(j < 2, j % 2 == 0, amounts[i], false);
            }
        }
    }

    function test_unrepresentableFeeRevertsWithSafeCastInsteadOfArithmeticOverflow() public {
        SwapParams memory params = _params(true, true, 1);
        params.amountSpecified = type(int256).min;
        vm.prank(address(manager), alice);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.beforeSwap(address(router), key, params, "");
        params = _params(false, false, 1);
        params.amountSpecified = type(int256).max;
        vm.prank(address(manager), alice);
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.beforeSwap(address(router), key, params, "");
        assertFalse(hook.hasStarted(poolId));
        assertEq(hook.pendingFees(poolId), 0);
    }

    function _checkTrade(bool buying, bool exactInput, uint256 amount, bool claims) internal {
        uint256 recipientBefore = imd.balanceOf(OWNER);
        uint256 pendingBefore = hook.pendingFees(poolId);
        uint256 traderPairBefore = imd.balanceOf(address(router));
        uint256 traderTokenBefore = launchToken.balanceOf(address(router));
        uint256 managerPairBefore = imd.balanceOf(address(manager));
        uint256 managerTokenBefore = launchToken.balanceOf(address(manager));
        vm.recordLogs();
        BalanceDelta userDelta = _swap(buying, exactInput, amount, alice);
        BalanceDelta coreDelta = _coreDelta(vm.getRecordedLogs());
        uint256 fee = claims ? hook.pendingFees(poolId) - pendingBefore : imd.balanceOf(OWNER) - recipientBefore;
        uint256 gross = buying ? _abs(_pair(userDelta)) : _abs(_pair(coreDelta));
        assertEq(fee, FullMath.mulDiv(gross, 100, 10_000));
        assertEq(int256(_pair(userDelta)), int256(_pair(coreDelta)) - int256(fee));
        assertEq(_token(userDelta), _token(coreDelta));
        assertEq(int256(imd.balanceOf(address(router))) - int256(traderPairBefore), int256(_pair(userDelta)));
        assertEq(int256(launchToken.balanceOf(address(router))) - int256(traderTokenBefore), int256(_token(userDelta)));
        assertEq(
            imd.balanceOf(address(manager)) + imd.balanceOf(address(router)) + imd.balanceOf(OWNER),
            managerPairBefore + traderPairBefore + recipientBefore
        );
        assertEq(
            launchToken.balanceOf(address(manager)) + launchToken.balanceOf(address(router)),
            managerTokenBefore + traderTokenBefore
        );
        assertEq(launchToken.balanceOf(OWNER), 0);
        if (exactInput) assertEq(_abs(buying ? _pair(userDelta) : _token(userDelta)), amount);
        else assertEq(_abs(buying ? _token(userDelta) : _pair(userDelta)), amount);
        if (claims) assertEq(imd.balanceOf(OWNER), recipientBefore);
        else assertEq(hook.pendingFees(poolId), pendingBefore);
        _assertSettled();
    }

    function test_partialSpecifiedIMDBuyRevertsWithoutFeeOrWindow() public {
        _partialSpecified(true);
    }

    function test_partialSpecifiedIMDSellRevertsWithoutFeeOrWindow() public {
        _partialSpecified(false);
    }

    function _partialSpecified(bool buying) internal {
        _seed();
        SwapParams memory params = _params(buying, buying, 100 ether);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(params.zeroForOne ? int24(-1) : int24(1));
        uint256 funds = imd.balanceOf(address(router));
        vm.prank(relayer, alice);
        (bool success, bytes memory reason) =
            address(router).call(abi.encodeCall(PoolActor.swap, (key, params, bytes(""))));
        assertFalse(success);
        assertEq(bytes4(reason), CustomRevert.WrappedError.selector);
        // Decode ERC-7751 to prove the rejection is the partial-fill check, not another swap error.
        bytes memory arguments = new bytes(reason.length - 4);
        for (uint256 i; i < arguments.length; ++i) {
            arguments[i] = reason[i + 4];
        }
        (address target, bytes4 callback, bytes memory inner,) = abi.decode(arguments, (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(callback, IHooks.afterSwap.selector);
        assertEq(bytes4(inner), TestHook.PartialIMDFill.selector);
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(imd.balanceOf(address(router)), funds);
        assertEq(hook.pendingFees(poolId), 0);
        assertFalse(hook.hasStarted(poolId));
        (uint160 price,,,) = manager.getSlot0(poolId);
        assertEq(price, Q96);
        _assertSettled();
    }

    function test_partialUnspecifiedIMDUsesOnlyActualTrade() public {
        _seed();
        _checkPartialUnspecified(true);
        _checkPartialUnspecified(false);
    }

    function _checkPartialUnspecified(bool buying) internal {
        SwapParams memory params = _params(buying, !buying, 100 ether);
        (, int24 tick,,) = manager.getSlot0(poolId);
        params.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(tick + (params.zeroForOne ? int24(-1) : int24(1)));
        uint256 beforeFees = imd.balanceOf(OWNER);
        vm.recordLogs();
        vm.prank(relayer, alice);
        BalanceDelta delta = router.swap(key, params, "");
        BalanceDelta core = _coreDelta(vm.getRecordedLogs());
        uint256 fee = imd.balanceOf(OWNER) - beforeFees;
        uint256 gross = buying ? _abs(_pair(delta)) : _abs(_pair(core));
        assertEq(fee, FullMath.mulDiv(gross, 100, 10_000));
        assertLt(_abs(_token(delta)), 100 ether);
        assertGt(_abs(_token(delta)), 0);
        _assertSettled();
    }

    function test_freshTokenOnlyPoolMintsClaimsOnExactInputBuy() public {
        _seedTokenOnly();
        _checkTrade(true, true, 1 ether, true);
        _redeemAndCheck();
    }

    function test_freshTokenOnlyPoolMintsClaimsOnExactOutputBuy() public {
        _seedTokenOnly();
        _checkTrade(true, false, 1 ether, true);
        _redeemAndCheck();
    }

    function _redeemAndCheck() internal {
        uint256 claims = hook.pendingFees(poolId);
        assertGt(claims, 0);
        uint256 before = imd.balanceOf(OWNER);
        vm.prank(OWNER);
        hook.pause(poolId);
        vm.prank(bob);
        assertEq(hook.claimFees(poolId), claims);
        assertEq(imd.balanceOf(OWNER) - before, claims);
        assertEq(hook.pendingFees(poolId), 0);
        assertEq(hook.claimFees(poolId), 0);
        _assertSettled();
    }

    function test_failedDirectTransferFallsBackForAllSwapModes() public {
        _seed();
        imd.reject(OWNER);
        for (uint256 i; i < 4; ++i) {
            _checkTrade(i < 2, i % 2 == 0, 1 ether, true);
        }
        uint256 claims = hook.pendingFees(poolId);
        vm.expectRevert();
        hook.claimFees(poolId);
        assertEq(hook.pendingFees(poolId), claims);
        _assertSettled();
        imd.reject(address(0));
        _redeemAndCheck();
    }

    function test_partialClaimRedemptionPreservesRemainder() public {
        _seedTokenOnly();
        _swap(true, true, 1 ether, alice);
        uint256 pending = hook.pendingFees(poolId);
        uint256 balance = imd.balanceOf(address(manager));
        // Simulate temporarily unavailable reserves; do not erase the claim liability.
        deal(IMD, address(manager), 0);
        assertEq(hook.claimFees(poolId), 0);
        assertEq(hook.pendingFees(poolId), pending);
        deal(IMD, address(manager), pending / 2);
        assertEq(hook.claimFees(poolId), pending / 2);
        assertEq(hook.pendingFees(poolId), pending - pending / 2);
        deal(IMD, address(manager), balance - pending / 2);
        assertEq(hook.claimFees(poolId), pending - pending / 2);
        assertEq(imd.balanceOf(OWNER), pending);
        _assertSettled();
    }

    function test_multipleSwapsWithinOneUnlockAccumulateClaimsExactly() public {
        _seedTokenOnly();
        SwapParams memory params = _params(true, true, 1 ether);
        vm.prank(relayer, alice);
        router.swapTwice(key, params);
        assertEq(hook.pendingFees(poolId), 0.02 ether);
        assertEq(imd.balanceOf(OWNER), 0);
        _redeemAndCheck();
    }

    function test_reentrantFeeAndRedemptionCallsCannotSpendClaimsTwice() public {
        _seed();
        imd.setReentry(address(hook), abi.encodeCall(TestHook.claimFees, (poolId)));
        _swap(true, true, 1 ether, alice);
        assertFalse(imd.reentrySucceeded());
        assertEq(bytes4(imd.reentryResult()), TestHook.Reentrancy.selector);
        imd.reject(OWNER);
        _swap(false, true, 1 ether, bob);
        imd.reject(address(0));
        imd.setReentry(address(hook), abi.encodeCall(TestHook.claimFees, (poolId)));
        uint256 claims = hook.pendingFees(poolId);
        assertEq(hook.claimFees(poolId), claims);
        assertFalse(imd.reentrySucceeded());
        assertEq(bytes4(imd.reentryResult()), TestHook.Reentrancy.selector);
        _assertSettled();
    }

    function test_unknownPoolCannotReadOrMutateAnotherPool() public {
        PoolId unknown = PoolId.wrap(keccak256("other pool"));
        bytes memory errorData = abi.encodeWithSelector(TestHook.UnknownPool.selector, unknown);
        vm.expectRevert(errorData);
        hook.paused(unknown);
        vm.expectRevert(errorData);
        hook.isAllowed(unknown, alice);
        vm.expectRevert(errorData);
        hook.firstSwapTimestamp(unknown);
        vm.expectRevert(errorData);
        hook.hasStarted(unknown);
        vm.expectRevert(errorData);
        hook.allowlistActive(unknown);
        vm.expectRevert(errorData);
        hook.pendingFees(unknown);
        vm.expectRevert(errorData);
        hook.token(unknown);
        vm.expectRevert(errorData);
        hook.totalSupply(unknown);
        vm.expectRevert(errorData);
        hook.claimFees(unknown);
        vm.prank(OWNER);
        vm.expectRevert(errorData);
        hook.pause(unknown);
        vm.prank(OWNER);
        vm.expectRevert(errorData);
        hook.unpause(unknown);
        address[] memory accounts = new address[](1);
        accounts[0] = bob;
        vm.prank(OWNER);
        vm.expectRevert(errorData);
        hook.setAllowed(unknown, accounts, true);
        assertTrue(hook.isAllowed(poolId, alice));
        assertFalse(hook.isAllowed(poolId, bob));
        assertFalse(hook.paused(poolId));
    }

    function test_separateLaunchesHaveIsolatedWindowsPauseAllowlistAndClaims() public {
        TestHook second = _deployHook("second hook");
        PoolKey memory secondKey = key;
        secondKey.hooks = IHooks(address(second));
        factory.initialize(secondKey, Q96);
        PoolId secondId = secondKey.toId();
        factory.modify(secondKey, -120, 120, LIQUIDITY);
        _seed();
        imd.reject(OWNER);
        _swap(true, true, 1 ether, alice);
        vm.prank(OWNER);
        hook.pause(poolId);
        assertFalse(second.paused(secondId));
        assertFalse(second.hasStarted(secondId));
        assertFalse(second.isAllowed(secondId, alice));
        assertEq(second.pendingFees(secondId), 0);
        vm.expectRevert();
        second.claimFees(poolId);
        assertGt(hook.pendingFees(poolId), 0);
        vm.warp(block.timestamp + 900);
        SwapParams memory buy = _params(true, true, 1 ether);
        vm.prank(relayer, alice);
        vm.expectRevert();
        router.swap(secondKey, buy, "");
        assertTrue(second.allowlistActive(secondId));
        imd.reject(address(0));
        _redeemAndCheck();
    }

    function test_noLiquidityCannotConsumeFeeOrStartWindow() public {
        SwapParams memory params = _params(true, true, 1 ether);
        vm.prank(relayer, alice);
        vm.expectRevert();
        router.swap(key, params, "");
        // Unspecified IMD with no fill returns zero fee and leaves the clock unstarted.
        _swap(true, false, 1 ether, alice);
        assertFalse(hook.hasStarted(poolId));
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(hook.pendingFees(poolId), 0);
        _assertSettled();
    }

    function test_noOwnershipTransferOrOtherAdminSelectors() public {
        string[6] memory selectors = [
            "transferOwnership(address)",
            "renounceOwnership()",
            "setFee(uint256)",
            "setFeeRecipient(address)",
            "withdraw(address,uint256)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            vm.prank(OWNER);
            (bool success,) = address(hook).call(abi.encodeWithSignature(selectors[i], bob, 1));
            assertFalse(success, selectors[i]);
        }
    }
}

contract TestHookIMD0Test is HookBehavior {
    function imdIs0() internal pure override returns (bool) {
        return true;
    }
}

contract TestHookIMD1Test is HookBehavior {
    function imdIs0() internal pure override returns (bool) {
        return false;
    }
}
