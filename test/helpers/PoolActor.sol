// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TestToken} from "../../src/TestToken.sol";

/// @dev Test-only actor pays from its own prefunded balance. No user allowances are read.
contract PoolActor is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deployToken() external returns (TestToken) {
        return new TestToken();
    }

    function deployHook(bytes memory code, bytes32 salt) external returns (address at) {
        assembly ("memory-safe") {
            at := create2(0, add(code, 32), mload(code), salt)
        }
        require(at != address(0), "test deployment failed");
    }

    function initialize(PoolKey memory key, uint160 price) external {
        manager.initialize(key, price);
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 change) external returns (BalanceDelta delta) {
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), key, abi.encode(ModifyLiquidityParams(lower, upper, change, 0)))),
            (BalanceDelta)
        );
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta delta)
    {
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params, hookData))), (BalanceDelta));
    }

    function swapTwice(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta delta) {
        return abi.decode(manager.unlock(abi.encode(uint8(2), key, abi.encode(params, bytes("")))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (uint8 operation, PoolKey memory key, bytes memory payload) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (operation == 0) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
        } else {
            (SwapParams memory params, bytes memory hookData) = abi.decode(payload, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
            if (operation == 2) delta = delta + manager.swap(key, params, hookData);
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            currency.transfer(address(manager), uint256(-int256(amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(int256(amount)));
        }
    }
}
