# Additional launch tests

Run with the repository's vendored dependencies and Foundry 1.8:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x05a0c124b572151c4ce8448d3602123495fd36e709c29e82bbf7912691dfb949 forge test
```

`HookAtomicity.t.sol` adds integration checks using the real local v4 PoolManager, in both TEST/IMD sort orders:

- Failed initialization leaves the hook available for a valid factory initialization.
- Unknown pool keys cannot invoke swap callbacks against the bound pool's state.
- Empty and duplicate allowlist batches preserve the expected membership.
- Insufficient router funds fail during input settlement, after the hook callbacks. The failure must reverse fee transfers or claim minting, pool price movement, and the first-swap clock. Funding the router then permits the same trade to succeed.
- Full LP withdrawal while paused preserves outstanding IMD fee claims, which a stranger can redeem to the fixed recipient.
- Attempting redemption inside an existing manager unlock fails without stranding authorization or preventing a later ordinary redemption.

Both fuzz properties run 1,000 cases per token order. Amounts are bounded to keep the seeded position liquid; the pre-existing suite separately exercises dust, integer overflow, and partial fills.

`HookInvariant.t.sol` extends the existing conservation and fee-accounting campaign with two wallet origins, independent models of pause and allowlist state, unauthorized administrative calls with the owner as `tx.origin`, and LP deposit/withdrawal round trips. Each token order runs 128 sequences of 64 calls. Successful operations must settle all manager deltas; LP operations must remain possible while paused and must not pay hook fees.

`TokenStateful.t.sol` runs 128 sequences of 64 calls over four holders. Its separate ledger tracks balances and allowances across transfers, self-transfers, approvals, infinite approvals, and delegated transfers. Failed overdraws, approved overdraws, and invalid recipients must leave that ledger intact. Supply remains exactly one billion TEST.

All tests are offline. The IMD contract is the existing test stand-in at the implementation's IMD address. These checks do not verify deployed Robinhood Chain bytecode, live IMD transfer behavior, or production launch-factory allocation; a live-chain rehearsal remains separate. No production contracts or configuration are changed.
