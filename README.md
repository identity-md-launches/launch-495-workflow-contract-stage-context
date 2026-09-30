# PepeJackpot contracts

PepeJackpot is an immutable ICE jackpot and router for the existing “Pepe's armed with AI” game. It has no owner, proxy, upgrade, pause, fee setter, emergency withdrawal or token rescue. Every caller-initiated operation that moves value runs within exactly one authenticated Uniswap v4 `PoolManager.unlock`. Oracle fulfilment is the deliberate exception: it only moves pot ICE, so it takes no lock (see [Tickets, draws and custody](#tickets-draws-and-custody)). The contract creates no pool or liquidity and never approves spending of the pot.

This source contribution also includes the separately required `LaunchToken` (PepeJackpot / PJACK). PJACK has no constructor arguments, 18 decimals, and a fixed supply of exactly `1_000_000_000 * 10**18`, all minted to its deployer. It has plain ERC-20 transfers and no mint, burn, owner, fees, limits or upgrade functions. **PJACK is not ICE or IMD and is unused by the jackpot.** The mandatory launch token and launch-policy liquidity conflict with the brief's request for no new token, pool or liquidity; this is an explicit launch-review finding, not a substitution of PJACK for ICE. See [review notes](docs/REVIEW_NOTES.md).

## Build and tests

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200 runs, and `bytecode_hash = "none"`. Dependencies are ordinary vendored source files in `lib/`, with versions and licenses included. No package installation, network, environment variables, FFI or filesystem cheatcode permissions are needed for the ordinary test suite. The verifier supplies the pinned compiler. Tests run independently, including in parallel.

Mainnet tests skip explicitly on the ordinary local chain. Their separate command, fixed block and actual execution results are documented in [the fork rehearsal](docs/FORK_REHEARSAL.md). A fork request exercises deployed wrapper code; impersonating the wrapper in a callback test is not a production VRF proof or oracle-delivery test. Local success does not replace the required independent review. Slither and Mythril were not run.

ABI exports are [PepeJackpot.json](docs/abi/PepeJackpot.json) and [LaunchToken.json](docs/abi/LaunchToken.json). Regenerate after source changes with `forge inspect src/PepeJackpot.sol:PepeJackpot abi --json` and the corresponding LaunchToken command.

## Constructor and deployment

The application has one nonpayable constructor with five static address arguments, in this exact order:

| Argument | Ethereum mainnet value | Purpose |
| --- | --- | --- |
| `manager_` | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Uniswap v4 PoolManager |
| `ice_` | `0x64914921E03069dA66823F84fFcfB9931F05281A` | Existing ICE token |
| `iceHook_` | `0x51768f5da32ba2008304cc81674da51acb802888` | Existing LaunchpadHook |
| `imd_` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | Existing IMD token |
| `wrapper_` | `0x02aae1A04f9828517b3007f83f6181900CaD910c` | Chainlink VRF v2.5 native direct-funding wrapper |

The two pool keys specified in the brief are represented by these addresses and fixed fields, rather than ABI tuple constructor arguments: ETH/ICE is `(address(0), ice_, 0, 60, iceHook_)`; ETH/IMD is `(address(0), imd_, 10000, 200, address(0))`. Public key getters expose both complete tuples. This preserves the intended keys while using only constructor types supported by the launch factory. There are no initialization calls, `$owner`, privileged beneficiary, `$token` reference or dependence on constructor `msg.sender`.

The constructor validates nonzero dependencies and distinct ICE/IMD addresses without external calls, allowing deterministic offline construction. It does not certify the supplied addresses. Deployment services must verify Ethereum chain ID 1, dependency bytecode, token identities and **18 decimals**, initialized keys, hook curve inventory/backing, pool liquidity, wrapper support for a 500,000-gas callback and three confirmations, and the exact constructor encoding. Incorrect immutable addresses cannot be repaired. On other networks, use reviewed deployments with the same interfaces and economics rather than assuming these addresses exist.

**Codeless dependencies are not detected on chain.** The launch floor constructs the application offline on a chain that carries none of the mainnet dependencies, so the constructor cannot check `extcodesize`, `decimals()` or the chain ID without failing that floor. The same five arguments therefore deploy successfully on any chain, after which every entry point reverts forever and the token/pool half of the launch stands alone. The manifest and launch policy are the only enforcement of dependency identity. Before admission, the deployer must produce this evidence, none of which is a manifest field:

| Check | Expected |
| --- | --- |
| Launch policy `chainId` | `1` |
| `cast code` at each of the five constructor addresses on chain 1 | non-empty |
| `ICE.decimals()` and `IMD.decimals()` | `18` |
| `LaunchpadHook.poolManager()` | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Toolchain accepts `evm_version = "cancun"` artifacts | yes |

The fork rehearsal at block 26,087,742 asserted exactly these values; they must be re-checked at admission time, not assumed from that report.

Source publication, signed artifact linkage, policy admission, manifest creation and independent manifest review, deployment, explorer verification, IPFS hosting and frontend operation belong to the corresponding services. This contribution does not generate `launch.json`, broadcast transactions, access keys or claim those service outcomes are complete. The manifest should describe the separate launch token and the configured application, subject to resolution of the documented policy conflict.

## Actions and fees

All amounts use minor units (18 decimals); native values are wei. Use a finite transaction deadline and a meaningful, nonzero minimum output. Exact-input swaps must consume the entire requested input; partial fills and zero outputs revert atomically. Maximum input is `type(int128).max`, matching v4 signed currency deltas.

| Call | Accounting | Ticket threshold |
| --- | --- | --- |
| `fridgeSwap(true, amountIn, minOut, deadline)` | Retains `floor(amountIn/100)` ICE in the pot; sells the rest through ICE→ETH→IMD directly to the caller | `amountIn >= 10_000e18` ICE |
| `fridgeSwap(false, amountIn, minOut, deadline)` | Routes IMD→ETH→ICE; retains `floor(grossIce/100)` ICE and delivers the remainder | `amountIn >= 0.1e18` IMD |
| `goldenThrone(ethIn, minImdOut, minIceFee, deadline)` | First spends `floor(ethIn/100)` ETH buying ICE into the pot; spends the remainder buying IMD for the caller | `ethIn >= 0.001 ether` |
| `fillTank(pees, permit)` | Transfers exactly `pees * 1_000e18` ICE from caller to pot using ICE's EIP-2612 permit | None |
| `seed(amount)` | Transfers the specified ICE from caller to pot; approval required | None |

Below-threshold trades still contribute their fee but do not request randomness. Inputs must be positive; very small trades can fail pool or hook rounding checks. One eligible trade issues one ticket regardless of size. Seeding, filling a tank, and direct donations do not issue tickets or buy claims on the pot.

**Per-trade eligibility is a design property of the approved brief, not a defect.** The jackpot roll pays 90% of the pot regardless of ticket size, and the small prizes pay 20x the fee. A ticket with fee `f` on pot `P` (with `f <= P/200`) therefore has an expected payout of about `0.009 P + f`: the small-prize branch alone returns the fee in expectation, so fees do not grow the pot in expectation; only `seed`, `fillTank`, donations and losing variance do. Because eligibility is per trade, ten sells of 10,000 ICE buy ten draws for the same 1,000 ICE contribution as one sell of 100,000 ICE, and a 0.001 ETH throne gets the same 90% draw as a 10,000 ICE sell. A minimum ticket is positive-EV whenever `0.009 P` exceeds the trade's routing cost plus the VRF fee. No admin can change the formula or thresholds after deployment; scaling the jackpot prize or probability with the fee, or raising the ETH/IMD thresholds, is a requester scope decision that must be made before deployment. ICE held as pot leaves only as winnings; a sale's swap principal is transferred directly from the player to the manager, and a purchase's player allocation comes directly from the manager.

Fridge callers approve the input token. `fillTank` accepts `{deadline, v, r, s}` signed for `owner=caller`, `spender=PepeJackpot`, and exactly `pees * 1_000e18`. The token verifies the signature, nonce, chain/domain and deadline. If a third party has already submitted the permit, a sufficient existing allowance authorizes the transfer; a reverted permit alone cannot grief the action. Thus an invalid/expired permit is ignored only when the caller already granted sufficient spending authority. A reverted whole action restores the permit nonce and balances.

Eligible fridge trades supply ETH for the VRF request in `msg.value`. Throne supplies `ethIn + VRF fee`; the explicit `ethIn` separates trade principal from fee and refundable excess. `vrfFee()` calls the wrapper's `calculateRequestPriceNative(500000, 1)` at the transaction gas price. Obtain an estimate with the intended gas price and allow a buffer. The contract pays precisely the quoted fee, requests one native-funded word with three confirmations, then refunds excess to the caller in the same transaction. Insufficient fee, wrapper rejection or failed refund reverts **the entire trade and ticket**. A contract caller must accept an ETH refund or send the exact required amount. No accumulated native balance is used to subsidize another caller.

## Quotes and existing-hook behavior

`quoteFridgeSwap` and `quoteGoldenThrone` are true `view` functions returning player output and the ICE ticket contribution. They read the hook's curve and live fees and simulate v4 tick traversal with current liquidity, LP fees and directional protocol fees. The verified launchpad uses a virtual bonding curve and internally trades ETH/IMD, so quotes simulate sequential effects on the same pool, including tick crossings and reversals. The throne ICE leg executes first. If the hook's canonical IMD pool migrates to another supported hookless pool, the quoter simulates that separately.

Quotes do not reserve liquidity or establish a fair oracle price. Pool state and external hook fees may change before inclusion. Both throne outputs have independent slippage minima. See [dependency provenance](docs/DEPENDENCIES.md) for the verified launchpad source and external control assumptions.

## Tickets, draws and custody

Each ticket records player, issue time, ICE fee, status, roll and payout under its Chainlink request ID. There are no rounds, entry lists or caller-selected random seeds. Authenticated VRF fulfillment before 24 hours computes `roll = (word % 100) + 1`:

| Roll | Payout from the available pot at fulfillment |
| --- | --- |
| 77 | `floor(pot * 90 / 100)` |
| 20, 40, 60, 80, 100 | `min(ticketFee * 20, floor(pot / 10))` |
| Everything else | Zero |

The modulo mapping has the negligible bias inherent in mapping one 256-bit word to 100 outcomes. No timestamp, recent block value, user seed or on-chain pseudo-random fallback selects a winner. The timestamp only controls the deadline.

The pot is `ICE.balanceOf(jackpot) - totalClaimable`. Direct ICE transfers are irrevocable donations included in the pot. A winning ticket becomes terminal before any payout interaction. Payout transfers run in a bounded, isolated self-call: a revert, false/malformed return, wrong received amount or exhausted gas rolls back that transfer and reserves the full payout for `claim()`. Reserved winnings are excluded from every later draw. A player claims only their own balance, always to their own address; a failed claim preserves the credit. No admin can redirect a payout or withdraw donations. The self-only `deliverPayout` helper grants no public transfer authority.

At `issuedAt + 24 hours`, a pending ticket is expired and cannot win. Anyone can call `expire(id)`; a late callback also expires it. There is no cancellation, reroll, retry request, fee refund or rescue for missing/malformed/failed VRF fulfillment. Duplicate and unknown callbacks are ignored, unauthorized callbacks revert. A rejected or out-of-gas wrapper callback can leave a ticket pending until expiry. Chainlink fees pay for the request, not a delivery guarantee.

**Fulfilment holds no lock.** The VRF coordinator accepts a valid proof from any sender, and the wrapper delivers the word once, swallowing a consumer revert with no retry. Anyone who sees the oracle's fulfilment in the mempool can therefore relay it first from a context of their choosing, including from inside their own `PoolManager.unlock` or from the ETH refund of a sub-threshold trade while this contract's reentrancy guard is held. So `rawFulfillRandomWords` neither takes the reentrancy guard nor routes through the PoolManager: it authenticates the wrapper, marks the ticket terminal, and attempts the ICE payout directly. The self-only `deliverPayout` helper is gated on the sender alone for the same reason. A relayed delivery pays exactly as an oracle-delivered one; a replay of the same request during the payout is ignored because the ticket is no longer pending; value actions reached from inside a delivery stay behind the guard. The regression tests for both relay contexts are in `test/PepeJackpot.t.sol`.

As requested, payouts depend on the pot at **fulfillment**, not a reserved entry-time amount. Oracle delivery order therefore affects winnings. Outstanding tickets do not promise a minimum prize; multiple winners cannot spend reserved claims. The immutable wrapper/coordinator's correctness, availability and delivery ordering are trusted. Callback gas and confirmations are fixed deployment choices; services should verify these against the target wrapper and expected pot risk before release.

## Frontend and operations

The existing game can read `pot()`, `claimable(player)` and `tickets(requestId)`. Index `TicketIssued` by player to discover IDs; index `Drawn`, `TicketExpired` and `Claimed` for results and claims. `Drawn.deferred` means a claim is pending, not that a second prize is owed. A pending ticket past its deadline should display expired even if no one has submitted `expire`. Unbounded on-chain player arrays are intentionally avoided.

Operators monitor oracle delivery, pending ticket age, claim solvency, hook settings and real pool liquidity. Anyone may mark expired tickets, and players retry claims when the token becomes transferable. The app has no repair key: immutable dependency failures, accidental foreign-token transfers and forced ETH can be permanently stuck. Direct ETH transfers are rejected. The external LaunchpadHook has its own owner, which can change creator/burn fee rates and its canonical IMD pool; jackpot immutability does not remove that dependency's powers. Standard non-rebasing, non-taxed ICE/IMD behavior is assumed. Users approving any ERC-20 should account for the standard allowance-replacement race; PJACK supports infinite allowances in the usual ERC-20 manner.
