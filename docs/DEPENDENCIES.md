# Offline dependencies and existing hook provenance

The repository includes ordinary source files and original licenses for all build dependencies.
No dependency install, git submodule, network access, FFI, or filesystem permission is needed for
the default build and unit tests.

| Directory | Upstream | Version / commit | Included files |
| --- | --- | --- | --- |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | v1.9.7 / `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`, MIT and Apache licenses |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | v4.0.0 / `e50237c43811bd9b526eff40f26772152a42daba` | Production `src/`, original licenses; upstream test helpers omitted |
| `lib/solmate` | https://github.com/transmissions11/solmate | `89365b880c4f3c786bdd453d4b8e8fe410344a69` | `src/auth/Owned.sol` and license, required by the test deployment of upstream PoolManager |

PepeJackpot does not inherit Uniswap's `NoDelegateCall` or Solmate's ownership contract. The
PoolManager and its administrative functions are dependencies used by tests, not project launch
artifacts. The production quote library uses Uniswap's MIT-licensed math, types, interfaces, and
storage-read helpers. The vendored v4.0.0 ABI declares operation structs within `IPoolManager`;
their external encoding matches the later top-level operation structs used by the existing hook.

## Existing LaunchpadHook

The workflow supplies mainnet hook `0x51768F5dA32BA2008304cC81674da51aCb802888`. Its verified source
was obtained from the [Sourcify contract API](https://sourcify.dev/server/v2/contract/1/0x51768f5da32ba2008304cc81674da51acb802888?fields=all),
which reports exact creation and runtime matches, compiler `0.8.26+commit.8a97fa7a`, and verification
time `2026-08-19T01:57:57Z`. The source file `src/LaunchpadHook.sol` has SHA-256
`8b5e1ce893c4dba7f916d81f01bae09e4436c4261bbc185770afb6bd91de4c51`.

At Ethereum block **26,087,742**, `eth_getCode` through `https://rpc.flashbots.net` returned the
same 14,430-byte runtime as Sourcify's `onchainBytecode`. A local Foundry fork at that block read:

- Hook canonical pool: native ETH / workflow IMD, fee `10000`, tick spacing `200`, no hook.
- `creatorFeeBps()`: `50` (0.5% of the ETH leg).
- `burnFeeBps()`: `50` (0.5% of the IMD leg).

This is a block-specific observation, not a guarantee of future configuration. The hook's owner
can change each fee up to 500 bps and migrate its canonical IMD pool fee/spacing. The immutable
PepeJackpot contract cannot control those external powers.

The launchpad pool has **no core AMM liquidity**. `beforeSwap` consumes the entire swap, prices
ICE against a virtual IMD constant-product curve, and internally trades on the canonical ETH/IMD
pool. Its slot0 is a displayed marginal price, not a sufficient source for execution quotes.

`V4ViewQuoter` reads `getCurve`, both current fee getters, and `imdEthKey`, then simulates the
actual curve and core pool operations in order. When the hook and jackpot use the same IMD pool,
the second simulated swap reuses the first swap's changed in-memory price, tick, and liquidity.
The throne quote assumes the fee's ICE purchase executes before the player's IMD purchase.
Quotes incorporate initialized tick crossings, LP/protocol fees, integer rounding, and partial
fill detection. They never execute the hook or mutate on-chain state and are estimates rather
than price oracles; transaction minimum outputs and deadlines remain necessary.

`test/V4ViewQuoter.t.sol` compares the quote engine against actual vendored PoolManager swaps,
including both directions, nonzero direction-specific protocol fees, multiple liquidity ranges,
repeated swaps, and exhausted liquidity. The separately selectable mainnet rehearsal compares
the complete application routes with the actual deployed hook. Default tests need no RPC.
