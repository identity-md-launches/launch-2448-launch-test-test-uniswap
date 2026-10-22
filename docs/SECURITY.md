# Security review and validation

This records the implementation's own review, not an independent audit. The supplied protected checks were read as acceptance definitions. They run in the network's separate harness; this project's tests do not read their environment variables or alter those checks.

## Reviewed properties

| Area | Implementation and evidence |
|---|---|
| Initialization | Only the immutable PoolManager can invoke the callback; its `sender` must be the immutable factory. Pair, fee, spacing, hook identity, currency ordering, and single-pool binding are checked. Tests reject unauthorized initialization and invalid keys. |
| Ownership | Only `pause`, `unpause`, and `setAllowed` use owner authority. Constructor ownership is independent of deployer and origin. There is no ownership transfer, upgrade, withdrawal, fee change, or signer. Real CREATE2 factory deployment is tested. |
| Permission consistency | Required bits are 0x20cc. Constructor calls the internal v4 permission validator. Every implemented hook callback checks PoolManager. Disabled callbacks have no exposed implementations. |
| Before-swap delta / no-op risk | Only the IMD fee is returned, at a fixed 1%. It cannot consume the entire positive exact-input amount. The actual core specified fill must match the adjusted request. Empty pools, partial fills, integer extremes, and rounding boundaries are tested. |
| Delta settlement | Positive hook fee deltas are offset by `take` or `mint`. Specified fees are returned only once. Redemption's `burn` credit is canceled by `take`. Tests assert zero outstanding deltas and a locked manager after each operation. |
| Fee currency | TEST's core and user deltas must be identical. Only IMD is taken or minted. No approvals, ETH handling, secondary pool, or conversion path exists. |
| Fee claim backing | Claims are held by the hook, attributed by PoolId, and redeemable only to the fixed recipient. A dedicated authorization gates `unlockCallback`. State is debited before burning/taking and reverts atomically on failure. |
| Reentrancy | Fee-bearing callbacks and claim entry have a shared guard. Callback authorization is consumed before redemption interactions. Tests inject recursive claims during direct payout and redemption, and verify claims cannot be paid twice. Owner setters make no external calls. |
| Insufficient manager funds | Fresh managers seeded only with TEST mint claims before input settlement. Tests cover both buy modes, both currency orders, rejected direct transfers, partial redemption, failed redemption, and multiple swaps in one unlock. |
| Window | PoolId-keyed timestamp plus a separate started boolean. Only actual nonzero core deltas start it; all failed transactions roll back. Tests cover a sell as first swap, timestamp zero, rejected buys, spoofed hook data, shared routers, exact expiry, and pause duration. |
| Isolation | Only the bound PoolId is accepted by pool-dependent functions. Tests try unknown IDs and exercise two independent launches with isolated pause, allowlist, start time, and fee claims. |
| Liquidity liveness | All liquidity hook flags are disabled. Tests add, collect with zero change, and remove both factory and ordinary LP positions while swaps are paused. |
| Arithmetic | Percentage calculations use internal `FullMath.mulDiv`; fee-to-int128 casts are checked. Absolute signed amounts are promoted or computed without negating int256.min. Tests include tiny amounts, rounding discontinuities, and representability limits. |
| Token | OpenZeppelin ERC20, one constructor mint to the factory, no extra methods. Tests cover metadata, full supply, allocation, contract transfers, allowances, transfer failures, and absent admin selectors. |
| Immutability | Runtime opcode checks cover reachable SELFDESTRUCT, DELEGATECALL, and CALLCODE; runtime size is below EIP-170. Both artifacts have empty link references. |

The Foundry linter reports expected uses of `tx.origin` and `block.timestamp`: both are explicitly required for this policy. Its general cast and reentrancy heuristics are also reviewed against the checked casts, signed branches, trusted manager, and explicit entry guard. Timestamp use is only a trading window, never randomness or price calculation.

## Automated validation

Final local checks passed: `forge build`, `forge test` (**66 passed, 0 failed, 0 skipped**), and `forge fmt --check`, using the pinned Solidity 0.8.26 configuration. The optimized runtimes are 7,918 bytes for TestHook and 1,722 bytes for TestToken, with no library link placeholders.

The delivered suite includes unit/integration tests, deterministic fuzz tests, and three stateful invariants in each currency order:

- Total accrued hook fees equal recipient payments plus pending claims.
- Both currencies are conserved; TEST supply remains fixed.
- A pool's first-trade timestamp cannot be reset.

The invariant profile runs 64 sequences of 32 calls per currency order with `fail_on_revert = true`; expected refusals are checked inside the handler. Ordinary fuzz tests run 256 cases at the assignment's pinned seed. Both manager balances and ERC-6909 claim backing are checked after settlement. All standard tests are offline and independent of test ordering or environment variables.

## Chain observations and rehearsal limit

Read-only observations from Robinhood Chain at block **94,756,902** confirmed chain ID **4663**, **24,009 bytes** of code at the supplied PoolManager, **15,448 bytes** at the supplied IMD address, and IMD returning symbol `IMD` and decimals `18`. Public source endpoint: [Robinhood Chain RPC](https://rpc.mainnet.chain.robinhood.com). These observations confirm presence and the queried metadata, not a bytecode audit.

A full fork rehearsal was attempted, but this machine's Foundry HTTP transport could not reach the provided fork endpoint (`Connection refused`), including with proxy environment routing. The read-only RPC calls through the supplied proxy succeeded; the fork simulation did not run. The passing integration suite instead uses the actual vendored PoolManager and a controllable IMD stand-in. The launch system must repeat the factory/manager/real-IMD rehearsal before release with its resolved deployment parameters. No network transactions were sent.

Slither, Mythril, formal verification, and an independent adversarial review were not run in this assignment. These are not implied by the passing local checks.

## Dependency references

- [Uniswap v4 hooks](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks): callback lifecycle and address permission encoding.
- [Uniswap v4 custom accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting): specified/unspecified deltas and hook accounting.
- Exact upstream revisions and source directories are recorded in [dependencies.json](dependencies.json). Upstream license texts are included with the vendored sources. Uniswap's core implementation and full-precision arithmetic are unmodified.
