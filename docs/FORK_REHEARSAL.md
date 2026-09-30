# Mainnet fork rehearsal

The six tests in [`test/fork/PepeJackpotFork.t.sol`](../test/fork/PepeJackpotFork.t.sol)
passed against Ethereum mainnet state at block **26,087,742** using Foundry
1.8.3 and Solidity 0.8.26. The block hash is
`0xa43c2b468bbbeb3d8d02e1d84c86cce2560163cdf4a0190ea92bdca5f6e70b1b`;
its timestamp is 2026-09-30 03:55:35 UTC. These are local execution results,
not deployed transactions or independent review findings.

Reproduce with an archive-capable mainnet RPC:

```sh
forge test --match-contract PepeJackpotForkTest \
  --fork-url https://rpc.flashbots.net \
  --fork-block-number 26087742 -vv
```

The tests contain no RPC requests, environment-variable access, file permissions,
FFI, broadcast calls, or wallet configuration. Foundry obtains historical state
only when the operator supplies `--fork-url`. Without a mainnet fork, the suite's
setup reports **SKIP**, with zero tests passing; the default offline test run requires no network.
At chain ID 1, missing contracts or mismatched configuration fail the suite
instead of silently skipping it.

## Configured dependencies

| Parameter | Mainnet address |
| --- | --- |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| ICE | `0x64914921E03069dA66823F84fFcfB9931F05281A` |
| LaunchpadHook | `0x51768F5dA32BA2008304cC81674da51aCb802888` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Chainlink VRF v2.5 wrapper | `0x02aae1A04f9828517b3007f83f6181900CaD910c` |

Every setup asserts deployed code at all five addresses, confirms both tokens
use 18 decimals, and reads
`LaunchpadHook.poolManager()` from the fork to verify the configured manager.
The application derives the native-ETH/ICE pool key with fee 0, tick spacing 60
and the supplied hook, and the native-ETH/IMD key with fee 10,000, tick spacing
200 and no hook. The deployed IMD pool also charges a protocol fee; its observed
effective swap fee at this block is 10,990 pips, which is included by the quoter.

## Executed cases

1. Golden throne with 0.001 ETH: both real pool routes, exact quoted IMD output
   and ICE pot contribution, an accepted request through the real wrapper and
   coordinator, the exact native request price at a configured 2 gwei gas price,
   and refund of an additional 0.02 ETH.
2. Fridge buy with 0.1 IMD: real two-pool routing, exact output and fee quotes,
   1% of gross ICE reserved to the pot, and a real wrapper request.
3. Fridge sell with 10,000 ICE: real two-pool routing, exact output and fee
   quotes, exactly 100 ICE reserved to the pot, and a real wrapper request.
4. Seed plus tank fill: transfer 2,000 ICE to the pot and then 3,000 ICE through
   the real token's EIP-2612 permit; check signature acceptance, nonce advance,
   remaining user balance and final pot balance.
5. Impossible minimum output: reject the real throne route and preserve the
   user's ETH, IMD and the pot atomically.
6. Jackpot callback: issue a real request, impersonate the authenticated wrapper
   locally, provide a word producing roll 77 with a 500,000-gas callback budget,
   transfer 90% of the pot using the actual ICE contract and record the result.

The test account receives synthetic ETH using `vm.deal`; fridge/seed/tank cases
receive synthetic ERC-20 balances using Foundry's storage-aware `deal` helper.
Pool state, hook reserves, dependency code and the wrapper's configuration are
otherwise taken from the pinned fork. The permit uses a fixed, explicitly
synthetic test signing key. No funded wallet or external transaction is used.

## Limits and operating responsibilities

The callback test does **not** verify a generated Chainlink proof or demonstrate
oracle fulfillment latency: the wrapper address is impersonated for that step.
It verifies the application's authorized callback path and real token payout.
The wrapper and coordinator execute the request path from their actual deployed
code. Operators still need to monitor oracle fulfillment, make expired-ticket
state visible after 24 hours, and expose deferred payouts through `claim()`.

The suite checks one historical snapshot. Hook fees, hook routing configuration,
liquidity, protocol fees and wrapper availability may change later. Repeat this
rehearsal at a fresh pinned block before release and keep the block/hash and
results with the independent review. Quotes are state-specific: users must still
set deadline and minimum-output constraints.

The deterministic test deployment address already has a small native ETH balance
on this fork. The refund test therefore checks that a trade does not increase
that balance, rather than assuming all prefunded addresses start at zero.
The immutable application has no rescue path for unsolicited native ETH.

During this run the Flashbots RPC served block/code/storage reads needed by the
fork but returned HTTP 403 (`rpc method is not whitelisted`) for direct
`eth_call`. Foundry's local execution still completed the six tests. RPC
availability and historical-state retention are operator dependencies, not
dependencies of the default offline verification run.
