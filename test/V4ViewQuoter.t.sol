// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {V4ViewQuoter} from "../src/libraries/V4ViewQuoter.sol";

/// @notice Differential tests against the actual vendored Uniswap v4 PoolManager.
contract V4ViewQuoterTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    LaunchToken internal token;
    PoolKey internal key;

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new LaunchToken();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 10_000, 200, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        vm.deal(address(this), 1_000_000 ether);
        _add(-60_000, 60_000, 1_000 ether);
        _add(-1_000, 1_000, 1_000 ether);
        _add(-200, 200, 1_000 ether);
        manager.setProtocolFeeController(address(this));
        // Different protocol fees per direction exercise both halves of the packed fee field.
        manager.setProtocolFee(key, uint24(700) | uint24(300 << 12));
    }

    receive() external payable {}

    function quote(bool zeroForOne, uint256 amount) external view returns (uint256, uint256) {
        return V4ViewQuoter.quoteExactInput(IPoolManager(address(manager)), key, zeroForOne, amount);
    }

    function quoteRoundTrip(bool zeroForOne, uint256 amount) external view returns (uint256 first, uint256 second) {
        V4ViewQuoter.PoolState memory state = V4ViewQuoter.loadPool(IPoolManager(address(manager)), key);
        (first,) = V4ViewQuoter.simulate(IPoolManager(address(manager)), state, zeroForOne, amount);
        (second,) = V4ViewQuoter.simulate(IPoolManager(address(manager)), state, !zeroForOne, first);
    }

    function testFuzzMatchesCoreAcrossTicksBothDirections(uint128 rawAmount, bool zeroForOne) public {
        uint256 amount = bound(rawAmount, 1e6, 1_000 ether);
        (uint256 expectedOut, uint256 expectedIn) = this.quote(zeroForOne, amount);
        (uint256 actualOut, uint256 actualIn) = _swap(zeroForOne, amount);
        assertEq(actualOut, expectedOut, "quote output differs from actual v4 swap");
        assertEq(actualIn, expectedIn, "quote input differs from actual v4 swap");
    }

    function testFuzzSequentialSimulationPreservesFirstSwapState(uint128 rawAmount, bool zeroForOne) public {
        uint256 amount = bound(rawAmount, 1e6, 1_000 ether);
        (uint256 firstQuote, uint256 secondQuote) = this.quoteRoundTrip(zeroForOne, amount);
        (uint256 firstActual,) = _swap(zeroForOne, amount);
        (uint256 secondActual,) = _swap(!zeroForOne, firstActual);
        assertEq(firstQuote, firstActual);
        assertEq(secondQuote, secondActual, "second leg must use first leg's changed price and liquidity");
    }

    function testQuoteDoesNotMutatePool() public view {
        (uint160 beforePrice, int24 beforeTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        this.quoteRoundTrip(true, 800 ether);
        (uint160 afterPrice, int24 afterTick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(beforePrice, afterPrice);
        assertEq(beforeTick, afterTick);
    }

    function testExhaustedLiquidityReportsPartialFillInBothDirections() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            bool zeroForOne = i == 0;
            (uint256 expectedOut, uint256 expectedIn) = this.quote(zeroForOne, 100_000 ether);
            (uint256 actualOut, uint256 actualIn) = _swap(zeroForOne, 100_000 ether);
            assertEq(actualOut, expectedOut);
            assertEq(actualIn, expectedIn);
            assertLt(actualIn, 100_000 ether);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testRejectsZeroAndOversizedAmounts() public {
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quote(true, 0);
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quote(true, uint256(1) << 127);
    }

    function testRejectsUnknownPoolInsteadOfQuotingZero() public {
        key.fee = 3_000;
        vm.expectRevert(V4ViewQuoter.QuotePoolNotInitialized.selector);
        this.quote(true, 1 ether);
    }

    function testRejectsHookedPoolFromCoreOnlyQuote() public {
        key.hooks = IHooks(address(0x8088));
        vm.expectRevert(V4ViewQuoter.UnsupportedQuotePool.selector);
        this.quote(true, 1 ether);
    }

    function _add(int24 lower, int24 upper, int256 liquidity) private {
        manager.unlock(abi.encode(uint8(0), false, uint256(0), lower, upper, liquidity));
    }

    function _swap(bool zeroForOne, uint256 amount) private returns (uint256 amountOut, uint256 amountIn) {
        return abi.decode(
            manager.unlock(abi.encode(uint8(1), zeroForOne, amount, int24(0), int24(0), int256(0))), (uint256, uint256)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 operation, bool zeroForOne, uint256 amount, int24 lower, int24 upper, int256 liquidity) =
            abi.decode(data, (uint8, bool, uint256, int24, int24, int256));
        BalanceDelta delta;
        if (operation == 0) {
            (delta,) = manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lower, upper, liquidity, 0), "");
        } else {
            delta = manager.swap(
                key,
                IPoolManager.SwapParams(
                    zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        if (operation == 0) return "";
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        return abi.encode(uint256(int256(output)), uint256(-int256(input)));
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 debt = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: debt}();
            } else {
                token.transfer(address(manager), debt);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}
