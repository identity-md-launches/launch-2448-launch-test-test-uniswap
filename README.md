# test (TEST) / IMD launch

This Foundry project delivers the fixed-supply `TestToken` and immutable `TestHook` for Robinhood Chain (4663). It implements a 1% IMD hook fee, owner-controlled swap pausing, and a 15-minute buyer allowlist. The hook binds once to the pool initialized by its constructor-supplied launch factory.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

The root configuration pins Solidity **0.8.26**, Cancun, optimization at 200 runs, and `bytecode_hash = "none"`. Dependencies are ordinary source files under `lib/`; no installation, submodule, network, FFI, or filesystem permissions are needed to build or test when the pinned compiler is installed. The fuzz seed is pinned to `0x05a0c124b572151c4ce8448d3602123495fd36e709c29e82bbf7912691dfb949`. Tests use no environment configuration.

`test/TestHook.t.sol` exercises the real vendored Uniswap PoolManager with TEST in both currency orders. `test/HookInvariant.t.sol` checks stateful sequences of trades, allowlist changes, pausing, time advancement, transfer failures, fee redemption, and factory fee collection. `test/Deployment.t.sol` performs a real CREATE2 deployment with matching permission bits. Test actors and mock tokens live only under `test/` and are not launch contracts.

## Deployment parameters

Deploy exactly these two artifacts:

| Artifact | Constructor arguments, in order |
|---|---|
| `src/TestToken.sol:TestToken` | None |
| `src/TestHook.sol:TestHook` | `IPoolManager manager_`, `address owner_`, `address factory_` |

The hook's launch arguments are `[$poolManager, $owner, $factory]`. For this assignment `$poolManager` resolves to **0x8366a39CC670B4001A1121B8F6A443A643e40951** and `$owner` resolves to **0x5Bff2a2FEcD1d6152676813b21346238733bEAB1**. `$factory` is resolved by the launch system to its actual factory. It must be the contract that calls `PoolManager.initialize`, not a router or transaction origin. No guessed factory address is embedded in this project. The manager is an immutable constructor argument, not hardcoded in the hook.

The constructor rejects zero manager, owner, and factory addresses and validates its own permission bits. It makes no external calls or code-presence checks, so admission can construct it on an empty chain. The owner and factory cannot be changed afterward.

The fixed pair is **IMD at 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127**, with 18 decimals. Initialization requires this pair, a nonzero distinct launch token, sorted currencies, the hook itself, **LP fee 12500 (1.25%)**, and **tick spacing 60**. It accepts initialization only through the supplied PoolManager, with `sender == factory`. The first successful initialization binds the hook permanently; even the factory cannot attach it to a second pool. A reverted initialization rolls the binding back.

The factory deploys the token first, receives its supply, then deploys and initializes the hook/pool atomically. The hook discovers TEST as the currency that is not IMD. `token(poolId)` identifies it and `totalSupply(poolId)` reads that token's actual `totalSupply()`.

The deployer must mine a CREATE2 salt for the exact creation bytecode and encoded arguments using the actual factory as CREATE2 deployer. Required low 14 address bits: **0x20cc (8396)**. Changing compilation settings or arguments requires mining again. The enabled permissions are:

| Permission | Purpose |
|---|---|
| `beforeInitialize` | Authenticate the factory and bind the launch pool |
| `beforeSwap` | Enforce pause/allowlist and reserve a specified-IMD fee |
| `afterSwap` | Verify fills, start the window, calculate unspecified-IMD fees, and settle fees |
| `beforeSwapReturnDelta` | Charge the specified IMD side |
| `afterSwapReturnDelta` | Charge the unspecified IMD side |

All other permissions are disabled. There are no liquidity callbacks, so adding liquidity, removing liquidity, and a zero-change factory fee collection remain available while paused. No LP fee override is returned. The design uses the general BaseHook callback model implemented directly, internal `FullMath` and `SafeCast` libraries, no shares, and no hook-owned transient storage. PoolManager itself requires Cancun support.

The launch policy determines the actual opening price from a **2,500 IMD opening market capitalization** and the deployed token's sort order. The brief's `pool.initialPrice` field is `79228162514264337593543950336`; it is not an instruction for this code to open a 1:1 pool. This project does not calculate or enforce a different opening price. The factory supplies `sqrtPriceX96` at initialization. No external pool, feed, oracle, or price service is used.

The separate manifest step supplies `launch.json`; this repository intentionally does not create one. This assignment builds the deployment artifacts and does not broadcast transactions.

## Token and launch allocation

`TestToken` has name **test**, symbol **TEST**, 18 decimals, and exactly **1,000,000,000 TEST** (`10^27` base units). Its constructor mints everything to `msg.sender`, which is the launch factory. Standard OpenZeppelin ERC-20 transfers and allowances have no tax. There are no external mint, burn, owner, pause, blocklist, rescue, or upgrade functions.

The launch factory, not the token or hook, distributes the supply:

| Destination | Basis points | TEST |
|---|---:|---:|
| Seed liquidity | 1000 | 100,000,000 |
| Swarm's launch MerkleDistributor | 1000 | 100,000,000 |
| 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1 | 8000 | 800,000,000 |

The manifest must set **`economics.poolBps = 1000`**. There is no swarm wallet to configure and neither launch contract reserves an allocation for itself.

## Fee accounting and rounding

The hook fee is **100 basis points of the gross IMD leg**, rounded down to base units. On a buy this is total IMD paid by the trader, including the hook fee. On a sell this is IMD produced by the pool before the hook fee is deducted. The pool's 1.25% LP fee remains separate and is included in the PoolManager's core swap accounting.

Let `A` be the absolute requested amount, `B` the actual absolute IMD core delta, and `F` the hook fee. All percentage calculations use full-precision `FullMath.mulDiv`.

| Swap | Fee calculation | Effect |
|---|---|---|
| Exact-input buy, IMD specified | `F = floor(A × 100 / 10000)` | Pool consumes `A - F` IMD; trader pays `A` |
| Exact-output buy, TEST specified | `F = floor(B × 100 / 9900)` | Trader pays `B + F` IMD; requested TEST output is unchanged |
| Exact-input sell, TEST specified | `F = floor(B × 100 / 10000)` | Trader receives `B - F` IMD |
| Exact-output sell, IMD specified | `F = floor(A × 100 / 9900)` | Pool produces `A + F` IMD; trader receives `A` |

The divisions by 9900 account for a requested or core amount that is net of the 1% fee: `F` equals `floor(gross IMD × 100 / 10000)`. This convention keeps the fee at 1% of the gross IMD leg in all four modes. Sub-base-unit fees round to zero; there is no minimum fee.

When IMD is specified, `beforeSwap` returns a positive specified delta `F`. `afterSwap` requires the actual signed core IMD delta to equal `amountSpecified + F`, including when `F` is zero. A partial fill reverts the entire trade, price movement, fee, and first-swap timestamp. When TEST is specified, the fee is calculated from the actual core IMD delta after execution; a partial fill is allowed and charges only that fill. The original price limit is always passed through unchanged. Routers must account for these deltas and enforce users' output/input limits.

Every fee is sent **in IMD** to **0x5Bff2a2FEcD1d6152676813b21346238733bEAB1** inside the swap. If the PoolManager lacks enough IMD before the router settles, or its attempted transfer reverts/returns failure, the hook mints an IMD ERC-6909 claim to itself instead. Holding the claims in the hook makes permissionless redemption possible for a wallet recipient. `pendingFees(poolId)` attributes only this pool's claims; there is no ETH conversion, token approval, or outside swap.

Anyone can call **`claimFees(PoolId poolId)`**, including while swaps are paused. Call it outside an active PoolManager unlock. It unlocks the manager, burns up to the smaller of the pool's pending claims and the manager's available IMD, and sends that IMD to the same fixed recipient. The return value is the amount redeemed. No claims or no available IMD returns zero; a failed redemption transfer reverts atomically and preserves the claims. Remaining claims can be retried later. Newly paid fees do not automatically redeem earlier claims. Claims donated to the hook by outsiders are not attributed to a pool and are not withdrawable.

## Storefront and owner operations

Every pool-dependent function takes a `PoolId`, computed as the v4 hash of the complete `PoolKey`. Unknown PoolIds revert with `UnknownPool`; they cannot access or mutate the registered pool's state. Although each hook instance permits only one pool, its pause, allowlist, clock, token identity, and claims are all stored in a PoolId-keyed mapping.

The **only privileged functions** are:

```solidity
pause(PoolId poolId)
unpause(PoolId poolId)
setAllowed(PoolId poolId, address[] accounts, bool allowed)
```

Authorization uses the caller (`msg.sender`) and the immutable owner. An owner's transaction origin grants no admin rights to a relayer. `setAllowed` adds or removes accounts and emits an event per account; use reasonably sized batches to fit transaction gas limits. Repeated pause, unpause, and identical allowlist updates are idempotent.

Read functions for the storefront:

```solidity
paused(PoolId poolId) returns (bool)
isAllowed(PoolId poolId, address wallet) returns (bool)
hasStarted(PoolId poolId) returns (bool)
firstSwapTimestamp(PoolId poolId) returns (uint256)
allowlistActive(PoolId poolId) returns (bool)
pendingFees(PoolId poolId) returns (uint256)
token(PoolId poolId) returns (address)
totalSupply(PoolId poolId) returns (uint256)
```

Before trading starts, buys require an allowlisted **`tx.origin`**. The first successful swap with a nonzero core delta, buy or sell, records `block.timestamp`. Reverted and entirely unfilled swaps do not start the clock. For timestamps strictly less than `firstSwapTimestamp + 900`, only listed origins may buy. At exactly 900 seconds, buying opens to everyone. Sells do not require allowlisting. Pausing, unpausing, liquidity changes, and allowlist edits never restart or extend the clock. A separate started flag handles a first swap at timestamp zero correctly.

The requested `tx.origin` policy measures the transaction-origin wallet, not a token recipient or decoded `hookData`. Several wallets, shared allowed relayers, and account-abstraction bundlers can defeat person-level gating or cause several users to share one identity. The hook deliberately implements no signer, router allowlist, backend service, purchase cap, or identity verification. This is not Sybil protection.

## After launch

The owner should populate the pool's buyer allowlist before permitting the first buy, and may pause/unpause swaps as required. An empty list does not block sells, and a sell can begin the 15-minute window. Losing the immutable owner's key permanently loses these controls; it does not grant anyone another admin role or block LP withdrawals.

The recipient or any keeper can monitor `FeeClaimMinted`, `pendingFees(poolId)`, and `FeeClaimRedeemed`, and call `claimFees` when reserves permit. Redemption callers receive no reward and cannot redirect fees. There are no post-deployment fee, recipient, owner, factory, pool, or service settings.

The launch system is responsible for resolving `$factory`, applying the specified allocation and price policy, mining the hook address, atomic factory deployment/initialization, verification of deployed bytecode, and the separate independent security review before release. Owner pause authority and the chain's sequencing/timestamp behavior are operational trust assumptions. The hook assumes the supplied manager is the canonical v4 manager and that TEST/IMD have ordinary non-rebasing, non-taxed ERC-20 accounting; it cannot make a transfer-restricted or insolvent external token liquid.

See [security review and validation](docs/SECURITY.md) and [dependency provenance](docs/dependencies.json).
