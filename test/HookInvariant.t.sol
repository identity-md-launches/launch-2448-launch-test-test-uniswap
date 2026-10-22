// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFixture} from "./TestHook.t.sol";
import {TestHook} from "../src/TestHook.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {PoolActor} from "./helpers/PoolActor.sol";

contract HookHandler is Test {
    TestHook public immutable hook;
    MockIMD public immutable imd;
    PoolActor public immutable router;
    PoolActor public immutable factory;
    PoolKey internal key;
    PoolId internal poolId;
    address public immutable trader;
    bool private immutable imd0;
    uint256 public accruedFees;
    uint256 public firstTradeTime;
    uint256 public successfulSwaps;
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    constructor(TestHook hook_, PoolActor router_, PoolActor factory_, PoolKey memory key_, address trader_) {
        hook = hook_;
        router = router_;
        factory = factory_;
        key = key_;
        poolId = key_.toId();
        trader = trader_;
        imd = MockIMD(hook_.IMD());
        imd0 = Currency.unwrap(key_.currency0) == hook_.IMD();
    }

    function trade(bool buying, bool exactInput, uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e12, 10 ether);
        bool zeroForOne = buying == imd0;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        bool shouldReject =
            hook.paused(poolId) || (buying && hook.allowlistActive(poolId) && !hook.isAllowed(poolId, trader));
        vm.recordLogs();
        vm.prank(address(this), trader);
        (bool success, bytes memory result) =
            address(router).call(abi.encodeCall(PoolActor.swap, (key, params, bytes(""))));
        assertEq(success, !shouldReject, "unexpected swap outcome");
        if (!success) return;
        BalanceDelta userDelta = abi.decode(result, (BalanceDelta));
        uint256 gross;
        if (buying) {
            int128 pair = imd0 ? userDelta.amount0() : userDelta.amount1();
            gross = uint256(-int256(pair));
        } else {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == address(hook.poolManager()) && logs[i].topics[0] == SWAP_TOPIC) {
                    (int128 a0, int128 a1,,,,) =
                        abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                    gross = uint256(int256(imd0 ? a0 : a1));
                    break;
                }
            }
        }
        assertGt(gross, 0);
        accruedFees += FullMath.mulDiv(gross, 100, 10_000);
        if (successfulSwaps == 0) firstTradeTime = block.timestamp;
        ++successfulSwaps;
    }

    function setPause(bool pause_) external {
        vm.prank(hook.owner());
        if (pause_) hook.pause(poolId);
        else hook.unpause(poolId);
    }

    function setAllowed(bool allowed) external {
        address[] memory accounts = new address[](1);
        accounts[0] = trader;
        vm.prank(hook.owner());
        hook.setAllowed(poolId, accounts, allowed);
    }

    function advance(uint16 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 600));
    }

    function setTransferFailure(bool fails) external {
        imd.reject(fails ? hook.FEE_RECIPIENT() : address(0));
    }

    function redeem() external {
        bool shouldReject = imd.rejectedRecipient() != address(0) && hook.pendingFees(poolId) != 0;
        (bool success,) = address(hook).call(abi.encodeCall(TestHook.claimFees, (poolId)));
        assertEq(success, !shouldReject, "unexpected redemption outcome");
    }

    function collectLPFees() external {
        BalanceDelta delta = factory.modify(key, -120, 120, 0);
        assertGe(delta.amount0(), 0);
        assertGe(delta.amount1(), 0);
    }
}

abstract contract HookInvariants is HookFixture {
    HookHandler internal handler;

    function setUp() public override {
        super.setUp();
        _seed();
        handler = new HookHandler(hook, router, factory, key, alice);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = HookHandler.trade.selector;
        selectors[1] = HookHandler.setPause.selector;
        selectors[2] = HookHandler.setAllowed.selector;
        selectors[3] = HookHandler.advance.selector;
        selectors[4] = HookHandler.setTransferFailure.selector;
        selectors[5] = HookHandler.redeem.selector;
        selectors[6] = HookHandler.collectLPFees.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_allFeesArePaidOrBackedByPoolClaims() public view {
        assertEq(imd.balanceOf(OWNER) + hook.pendingFees(poolId), handler.accruedFees());
        _assertSettled();
    }

    function invariant_currencyConservationAndTokenSupply() public view {
        assertEq(
            imd.balanceOf(address(factory)) + imd.balanceOf(address(router)) + imd.balanceOf(address(manager))
                + imd.balanceOf(OWNER) + imd.balanceOf(address(hook)),
            2e27
        );
        assertEq(
            launchToken.balanceOf(address(factory)) + launchToken.balanceOf(address(router))
                + launchToken.balanceOf(address(manager)) + launchToken.balanceOf(address(this))
                + launchToken.balanceOf(OWNER) + launchToken.balanceOf(address(hook)),
            launchToken.totalSupply()
        );
        assertEq(launchToken.totalSupply(), 1e27);
    }

    function invariant_firstSwapWindowCannotBeReset() public view {
        assertEq(hook.hasStarted(poolId), handler.successfulSwaps() != 0);
        if (handler.successfulSwaps() != 0) assertEq(hook.firstSwapTimestamp(poolId), handler.firstTradeTime());
    }
}

contract HookIMD0InvariantTest is HookInvariants {
    function imdIs0() internal pure override returns (bool) {
        return true;
    }
}

contract HookIMD1InvariantTest is HookInvariants {
    function imdIs0() internal pure override returns (bool) {
        return false;
    }
}
