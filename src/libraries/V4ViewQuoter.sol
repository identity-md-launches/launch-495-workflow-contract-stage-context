// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @dev View ABI from the source verified for the workflow's existing LaunchpadHook.
interface ILaunchpadQuote {
    struct CurveState {
        address coin;
        uint128 virtualImd;
        uint128 virtualCoin;
        uint128 realImd;
        uint128 initialVirtualImd;
    }

    function getCurve(PoolId poolId) external view returns (CurveState memory);
    function creatorFeeBps() external view returns (uint16);
    function burnFeeBps() external view returns (uint16);
    function imdEthKey() external view returns (PoolKey memory);
}

/// @notice Read-only simulation of the existing launchpad routes, including their nested IMD swaps.
/// @dev Tick traversal follows Uniswap v4-core Pool.swap/TickBitmap. These are execution estimates,
/// not oracle prices: pool state and the external hook's owner-controlled fees can change before inclusion.
library V4ViewQuoter {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    error UnsupportedQuotePool();
    error QuotePoolNotInitialized();
    error QuoteAmountInvalid();
    error QuotePartialFill();
    error QuoteInsufficientReserve();

    struct PoolState {
        PoolId id;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint24 protocolFee;
        uint24 lpFee;
    }

    struct HookState {
        ILaunchpadQuote.CurveState curve;
        uint16 creatorFeeBps;
        uint16 burnFeeBps;
        PoolState pool;
    }

    struct Step {
        uint160 startPrice;
        int24 tickNext;
        bool initialized;
        uint160 nextPrice;
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
    }

    /// @notice Simulates a full fridge route and the jackpot's one-percent ICE cut.
    function quoteFridge(
        IPoolManager manager,
        PoolKey memory iceKey,
        PoolKey memory imdKey,
        bool sellIce,
        uint256 amountIn
    ) internal view returns (uint256 amountOut, uint256 ticketFeeIce) {
        _validateAmount(amountIn);
        PoolState memory pool = loadPool(manager, imdKey);
        HookState memory hook = _loadHook(manager, iceKey, imdKey, pool);
        if (sellIce) {
            ticketFeeIce = amountIn / 100;
            uint256 ethOut = _sellIce(manager, hook, amountIn - ticketFeeIce);
            amountOut = _fullSwap(manager, pool, true, ethOut);
        } else {
            uint256 ethOut = _fullSwap(manager, pool, false, amountIn);
            uint256 iceGross = _buyIce(manager, hook, ethOut);
            ticketFeeIce = iceGross / 100;
            amountOut = iceGross - ticketFeeIce;
        }
    }

    /// @notice Simulates the ICE ticket purchase first, followed by the player's IMD purchase.
    function quoteThrone(IPoolManager manager, PoolKey memory iceKey, PoolKey memory imdKey, uint256 ethIn)
        internal
        view
        returns (uint256 imdOut, uint256 ticketFeeIce)
    {
        _validateAmount(ethIn);
        PoolState memory pool = loadPool(manager, imdKey);
        HookState memory hook = _loadHook(manager, iceKey, imdKey, pool);
        uint256 feeEth = ethIn / 100;
        if (feeEth == 0) revert QuoteAmountInvalid();
        ticketFeeIce = _buyIce(manager, hook, feeEth);
        imdOut = _fullSwap(manager, pool, true, ethIn - feeEth);
    }

    /// @notice Quote a hookless pool using its current LP and protocol fees.
    function quoteExactInput(IPoolManager manager, PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 consumedIn)
    {
        return simulate(manager, loadPool(manager, key), zeroForOne, amountIn);
    }

    function loadPool(IPoolManager manager, PoolKey memory key) internal view returns (PoolState memory pool) {
        if (address(key.hooks) != address(0) || key.tickSpacing <= 0 || key.tickSpacing > type(int16).max) {
            revert UnsupportedQuotePool();
        }
        pool.id = key.toId();
        pool.tickSpacing = key.tickSpacing;
        (pool.sqrtPriceX96, pool.tick, pool.protocolFee, pool.lpFee) = manager.getSlot0(pool.id);
        if (pool.sqrtPriceX96 == 0) revert QuotePoolNotInitialized();
        pool.liquidity = manager.getLiquidity(pool.id);
    }

    /// @dev Mutates only the in-memory simulation. Reuse the same struct for sequential swaps.
    function simulate(IPoolManager manager, PoolState memory pool, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 consumedIn)
    {
        _validateAmount(amountIn);
        uint256 remaining = amountIn;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (zeroForOne ? pool.sqrtPriceX96 <= limit : pool.sqrtPriceX96 >= limit) revert QuotePartialFill();
        uint16 protocolFee = zeroForOne ? pool.protocolFee.getZeroForOneFee() : pool.protocolFee.getOneForZeroFee();
        uint24 swapFee = protocolFee == 0 ? pool.lpFee : protocolFee.calculateSwapFee(pool.lpFee);
        Step memory step;
        while (remaining != 0 && pool.sqrtPriceX96 != limit) {
            step.startPrice = pool.sqrtPriceX96;
            (step.tickNext, step.initialized) = _nextTick(manager, pool, zeroForOne);
            if (step.tickNext < TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
            if (step.tickNext > TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;
            step.nextPrice = TickMath.getSqrtPriceAtTick(step.tickNext);
            (pool.sqrtPriceX96, step.amountIn, step.amountOut, step.fee) = SwapMath.computeSwapStep(
                pool.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.nextPrice, limit),
                pool.liquidity,
                -int256(remaining),
                swapFee
            );
            remaining -= step.amountIn + step.fee;
            amountOut += step.amountOut;
            if (pool.sqrtPriceX96 == step.nextPrice) {
                if (step.initialized) {
                    (, int128 liquidityNet) = manager.getTickLiquidity(pool.id, step.tickNext);
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    pool.liquidity = LiquidityMath.addDelta(pool.liquidity, liquidityNet);
                }
                pool.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (pool.sqrtPriceX96 != step.startPrice) {
                pool.tick = TickMath.getTickAtSqrtPrice(pool.sqrtPriceX96);
            }
        }
        consumedIn = amountIn - remaining;
        // Core returns an int128 BalanceDelta for the output, even when the math used wider values.
        if (amountOut > uint256(uint128(type(int128).max))) revert QuoteAmountInvalid();
    }

    function _loadHook(IPoolManager manager, PoolKey memory iceKey, PoolKey memory imdKey, PoolState memory pool)
        private
        view
        returns (HookState memory hook)
    {
        ILaunchpadQuote source = ILaunchpadQuote(address(iceKey.hooks));
        hook.curve = source.getCurve(iceKey.toId());
        hook.creatorFeeBps = source.creatorFeeBps();
        hook.burnFeeBps = source.burnFeeBps();
        PoolKey memory canonical = source.imdEthKey();
        if (
            hook.curve.coin != Currency.unwrap(iceKey.currency1) || hook.curve.virtualCoin == 0
                || hook.curve.virtualImd == 0 || hook.creatorFeeBps > 500 || hook.burnFeeBps > 500
                || Currency.unwrap(canonical.currency0) != address(0)
                || Currency.unwrap(canonical.currency1) != Currency.unwrap(imdKey.currency1)
                || address(canonical.hooks) != address(0)
        ) revert UnsupportedQuotePool();
        // Memory assignment aliases `pool`: the hook's nested swap and outer swap often use
        // the SAME pool, so both legs must see the simulated price/liquidity changes.
        hook.pool = PoolId.unwrap(canonical.toId()) == PoolId.unwrap(pool.id) ? pool : loadPool(manager, canonical);
    }

    function _buyIce(IPoolManager manager, HookState memory hook, uint256 ethIn) private view returns (uint256) {
        uint256 creatorFee = FullMath.mulDiv(ethIn, hook.creatorFeeBps, 10_000);
        uint256 imdGross = _fullSwap(manager, hook.pool, true, ethIn - creatorFee);
        uint256 imdNet = imdGross - FullMath.mulDiv(imdGross, hook.burnFeeBps, 10_000);
        if (
            uint256(hook.curve.virtualImd) + imdNet > type(uint128).max
                || uint256(hook.curve.realImd) + imdNet > type(uint128).max
        ) revert QuoteAmountInvalid();
        uint256 coinOut = FullMath.mulDiv(imdNet, hook.curve.virtualCoin, uint256(hook.curve.virtualImd) + imdNet);
        _validateAmount(coinOut);
        return coinOut;
    }

    function _sellIce(IPoolManager manager, HookState memory hook, uint256 coinIn) private view returns (uint256) {
        if (uint256(hook.curve.virtualCoin) + coinIn > type(uint128).max) revert QuoteAmountInvalid();
        uint256 imdGross = FullMath.mulDiv(coinIn, hook.curve.virtualImd, uint256(hook.curve.virtualCoin) + coinIn);
        if (imdGross > hook.curve.realImd) revert QuoteInsufficientReserve();
        uint256 imdNet = imdGross - FullMath.mulDiv(imdGross, hook.burnFeeBps, 10_000);
        uint256 ethGross = _fullSwap(manager, hook.pool, false, imdNet);
        uint256 ethOut = ethGross - FullMath.mulDiv(ethGross, hook.creatorFeeBps, 10_000);
        if (ethOut == 0) revert QuoteAmountInvalid();
        return ethOut;
    }

    function _fullSwap(IPoolManager manager, PoolState memory pool, bool zeroForOne, uint256 amountIn)
        private
        view
        returns (uint256 amountOut)
    {
        uint256 consumed;
        (amountOut, consumed) = simulate(manager, pool, zeroForOne, amountIn);
        if (consumed != amountIn) revert QuotePartialFill();
        if (amountOut == 0) revert QuoteAmountInvalid();
    }

    function _validateAmount(uint256 amount) private pure {
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert QuoteAmountInvalid();
    }

    /// @dev Read-only counterpart of TickBitmap.nextInitializedTickWithinOneWord.
    function _nextTick(IPoolManager manager, PoolState memory pool, bool zeroForOne)
        private
        view
        returns (int24 next, bool initialized)
    {
        unchecked {
            int24 compressed = TickBitmap.compress(pool.tick, pool.tickSpacing);
            if (zeroForOne) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked = manager.getTickBitmap(pool.id, wordPos) & (type(uint256).max >> (255 - bitPos));
                initialized = masked != 0;
                next = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * pool.tickSpacing
                    : (compressed - int24(uint24(bitPos))) * pool.tickSpacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 masked = manager.getTickBitmap(pool.id, wordPos) & ~((uint256(1) << bitPos) - 1);
                initialized = masked != 0;
                next = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * pool.tickSpacing
                    : (compressed + int24(uint24(255 - bitPos))) * pool.tickSpacing;
            }
        }
    }
}
