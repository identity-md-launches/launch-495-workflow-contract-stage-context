// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {V4ViewQuoter, ILaunchpadQuote} from "src/libraries/V4ViewQuoter.sol";
import {JackpotTestToken, JackpotLiquidityFixture} from "./mocks/JackpotFixtures.sol";

/// @dev Only models the hook's read ABI. Core swaps below execute on the actual PoolManager.
contract QuoterCurveFixture is ILaunchpadQuote {
    CurveState private curve;
    PoolKey private canonical;
    uint16 public creatorFeeBps;
    uint16 public burnFeeBps;

    function configure(CurveState memory state, PoolKey memory key, uint16 creatorFee, uint16 burnFee) external {
        curve = state;
        canonical = key;
        creatorFeeBps = creatorFee;
        burnFeeBps = burnFee;
    }

    function getCurve(PoolId) external view returns (CurveState memory) {
        return curve;
    }

    function imdEthKey() external view returns (PoolKey memory) {
        return canonical;
    }
}

/// @notice Offline coverage for the hook-aware routes, which the hookless quote suite does not call.
/// @dev The curve is a local model of the documented constant-product dependency. This does not replace
/// the optional fork rehearsal against the deployed hook. The oracle for tick traversal, price impact,
/// directional fees and sequential pool state is actual PoolManager execution, not V4ViewQuoter.
contract V4ViewQuoterPropertiesTest is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    JackpotTestToken internal imd;
    JackpotTestToken internal ice;
    QuoterCurveFixture internal hook;
    PoolKey internal outer;
    PoolKey internal alternate;
    PoolKey internal iceKey;
    ILaunchpadQuote.CurveState internal curve;

    function setUp() public {
        manager = new PoolManager(address(this));
        imd = new JackpotTestToken("IdentityMD", "IMD");
        ice = new JackpotTestToken("Ice", "ICE");
        hook = new QuoterCurveFixture();
        outer = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 200, IHooks(address(0)));
        alternate = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 3_000, 60, IHooks(address(0)));
        iceKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(ice)), 0, 60, IHooks(address(hook)));
        curve = ILaunchpadQuote.CurveState(
            address(ice), 1_000_000 ether, 1_000_000_000 ether, 1_000_000 ether, 1_000_000 ether
        );
        hook.configure(curve, outer, 50, 50);

        manager.initialize(outer, uint160(1 << 96));
        // A different price and fee distinguish a migrated hook pool from the jackpot's fixed pool.
        manager.initialize(alternate, TickMath.getSqrtPriceAtTick(300));
        JackpotLiquidityFixture lp = new JackpotLiquidityFixture(IPoolManager(address(manager)));
        imd.mint(address(this), 1_000_000 ether);
        imd.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);
        lp.add{value: 2_000 ether}(outer, -60_000, 60_000, 1_000 ether);
        lp.add{value: 2_000 ether}(outer, -200, 200, 1_000 ether);
        lp.add{value: 2_000 ether}(alternate, -60_000, 60_000, 1_000 ether);
        lp.add{value: 2_000 ether}(alternate, 120, 480, 1_000 ether);
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(outer, uint24(700) | uint24(300 << 12));
        manager.setProtocolFee(alternate, uint24(999) | uint24(1 << 12));
    }

    receive() external payable {}

    function quoteFridge(bool sell, uint256 amount) external view returns (uint256, uint256) {
        return V4ViewQuoter.quoteFridge(IPoolManager(address(manager)), iceKey, outer, sell, amount);
    }

    function quoteThrone(uint256 amount) external view returns (uint256, uint256) {
        return V4ViewQuoter.quoteThrone(IPoolManager(address(manager)), iceKey, outer, amount);
    }

    function quoteCore(PoolKey memory key, bool direction, uint256 amount) external view returns (uint256, uint256) {
        return V4ViewQuoter.quoteExactInput(IPoolManager(address(manager)), key, direction, amount);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzFridgeBuyMatchesExecutedLegs(uint96 raw, uint16 creator, uint16 burn, bool migrated) public {
        uint256 amount = bound(raw, 1e6, 100 ether);
        _configureFees(creator, burn, migrated);
        bytes32 beforeState = _poolStateHash();
        (uint256 quotedOut, uint256 quotedFee) = this.quoteFridge(false, amount);
        assertEq(_poolStateHash(), beforeState, "route quote changed pool state");
        uint256 ethOut = _execute(outer, false, amount);
        uint256 grossIce = _buyIce(ethOut);
        assertEq(quotedFee, grossIce / 100, "ICE fee must use gross route output");
        assertEq(quotedOut + quotedFee, grossIce, "sequential buy quote differs from execution");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzFridgeSellMatchesExecutedLegs(uint96 raw, uint16 creator, uint16 burn, bool migrated) public {
        uint256 amount = bound(raw, 1e6, 100_000 ether);
        _configureFees(creator, burn, migrated);
        bytes32 beforeState = _poolStateHash();
        (uint256 quotedOut, uint256 quotedFee) = this.quoteFridge(true, amount);
        assertEq(_poolStateHash(), beforeState, "route quote changed pool state");
        assertEq(quotedFee, amount / 100, "ICE fee must use original input");
        uint256 coinIn = amount - amount / 100;
        uint256 imdGross = coinIn * uint256(curve.virtualImd) / (uint256(curve.virtualCoin) + coinIn);
        uint256 imdNet = imdGross - imdGross * hook.burnFeeBps() / 10_000;
        uint256 ethGross = _execute(hook.imdEthKey(), false, imdNet);
        uint256 ethNet = ethGross - ethGross * hook.creatorFeeBps() / 10_000;
        assertEq(quotedOut, _execute(outer, true, ethNet), "sequential sell quote differs from execution");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzThroneExecutesIcePurchaseBeforePlayerSwap(uint96 raw, uint16 creator, uint16 burn, bool migrated)
        public
    {
        uint256 amount = bound(raw, 1e6, 100 ether);
        _configureFees(creator, burn, migrated);
        bytes32 beforeState = _poolStateHash();
        (uint256 quotedOut, uint256 quotedFee) = this.quoteThrone(amount);
        assertEq(_poolStateHash(), beforeState, "route quote changed pool state");
        assertEq(quotedFee, _buyIce(amount / 100), "ICE purchase must be simulated first");
        assertEq(quotedOut, _execute(outer, true, amount - amount / 100), "player swap must use updated pool");
    }

    function testQuoteRejectsInsufficientBackingAtExactBoundary() public {
        uint256 input = 10_000 ether;
        uint256 netIce = input - input / 100;
        uint256 needed = netIce * uint256(curve.virtualImd) / (uint256(curve.virtualCoin) + netIce);
        curve.realImd = uint128(needed - 1);
        hook.configure(curve, outer, 50, 50);
        vm.expectRevert(V4ViewQuoter.QuoteInsufficientReserve.selector);
        this.quoteFridge(true, input);
        curve.realImd = uint128(needed);
        hook.configure(curve, outer, 50, 50);
        (uint256 output,) = this.quoteFridge(true, input);
        assertGt(output, 0, "exact backing must permit the sale");
    }

    function testBuyRejectsVirtualImdOverflow() public {
        curve.virtualImd = type(uint128).max;
        hook.configure(curve, outer, 0, 0);
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteThrone(1 ether);
    }

    function testBuyRejectsRealImdOverflow() public {
        curve.realImd = type(uint128).max;
        hook.configure(curve, outer, 0, 0);
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteThrone(1 ether);
    }

    function testSellRejectsVirtualCoinOverflow() public {
        curve.virtualCoin = type(uint128).max;
        hook.configure(curve, outer, 0, 0);
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteFridge(true, 100);
    }

    function testQuotesRejectDustAtEachRoute() public {
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteThrone(99);
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteThrone(100); // One wei allocated to the fee cannot buy any IMD.
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteFridge(false, 1);
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteFridge(true, 1);
    }

    function testBuyRejectsCurveOutputRoundedToZero() public {
        curve.virtualCoin = 1;
        hook.configure(curve, outer, 0, 0);
        vm.expectRevert(V4ViewQuoter.QuoteAmountInvalid.selector);
        this.quoteThrone(1 ether);
    }

    function testMigratedPoolMustExistAndFullyFill() public {
        PoolKey memory empty = alternate;
        empty.fee = 500;
        hook.configure(curve, empty, 50, 50);
        vm.expectRevert(V4ViewQuoter.QuotePoolNotInitialized.selector);
        this.quoteThrone(1 ether);
        manager.initialize(empty, uint160(1 << 96));
        vm.expectRevert(V4ViewQuoter.QuotePartialFill.selector);
        this.quoteThrone(1 ether);
    }

    function testRouteRejectsExhaustedOuterLiquidity() public {
        hook.configure(curve, alternate, 50, 50);
        vm.expectRevert(V4ViewQuoter.QuotePartialFill.selector);
        this.quoteFridge(false, 100_000 ether);
    }

    function testFuzzRejectsUnsupportedHookConfiguration(uint8 rawCase) public {
        uint256 which = bound(rawCase, 0, 7);
        PoolKey memory canonical = outer;
        uint16 creator = 50;
        uint16 burn = 50;
        if (which == 0) curve.coin = address(imd);
        else if (which == 1) curve.virtualCoin = 0;
        else if (which == 2) curve.virtualImd = 0;
        else if (which == 3) creator = 501;
        else if (which == 4) burn = 501;
        else if (which == 5) canonical.currency0 = Currency.wrap(address(ice));
        else if (which == 6) canonical.currency1 = Currency.wrap(address(ice));
        else canonical.hooks = IHooks(address(hook));
        hook.configure(curve, canonical, creator, burn);
        vm.expectRevert(V4ViewQuoter.UnsupportedQuotePool.selector);
        this.quoteThrone(1 ether);
    }

    function testRejectsInvalidTickSpacingBeforeReadingPool() public {
        PoolKey memory key = outer;
        key.tickSpacing = 0;
        vm.expectRevert(V4ViewQuoter.UnsupportedQuotePool.selector);
        this.quoteCore(key, true, 1 ether);
        key.tickSpacing = -1;
        vm.expectRevert(V4ViewQuoter.UnsupportedQuotePool.selector);
        this.quoteCore(key, true, 1 ether);
        key.tickSpacing = int24(type(int16).max) + 1;
        vm.expectRevert(V4ViewQuoter.UnsupportedQuotePool.selector);
        this.quoteCore(key, true, 1 ether);
    }

    function testFuzzQuoteCrossesEmptyLiquidityGapFromNegativeUnalignedTick(bool zeroForOne, uint96 raw) public {
        PoolKey memory gapKey = alternate;
        gapKey.fee = 500;
        manager.initialize(gapKey, TickMath.getSqrtPriceAtTick(-301));
        JackpotLiquidityFixture lp = new JackpotLiquidityFixture(IPoolManager(address(manager)));
        imd.approve(address(lp), type(uint256).max);
        lp.add{value: 1_000 ether}(gapKey, -600, -360, 1_000 ether);
        lp.add{value: 1_000 ether}(gapKey, -240, 0, 1_000 ether);
        assertEq(IPoolManager(address(manager)).getLiquidity(gapKey.toId()), 0);
        uint256 amount = bound(raw, 1e6, 1 ether);
        (uint256 quotedOut, uint256 consumed) = this.quoteCore(gapKey, zeroForOne, amount);
        assertEq(consumed, amount, "empty current range is not an exhausted pool");
        assertEq(quotedOut, _execute(gapKey, zeroForOne, amount), "negative compressed tick traversal differs");
    }

    function _configureFees(uint16 creator, uint16 burn, bool migrated) private {
        hook.configure(curve, migrated ? alternate : outer, uint16(bound(creator, 0, 500)), uint16(bound(burn, 0, 500)));
    }

    function _buyIce(uint256 ethIn) private returns (uint256) {
        uint256 ethNet = ethIn - ethIn * hook.creatorFeeBps() / 10_000;
        uint256 imdGross = _execute(hook.imdEthKey(), true, ethNet);
        uint256 imdNet = imdGross - imdGross * hook.burnFeeBps() / 10_000;
        return imdNet * uint256(curve.virtualCoin) / (uint256(curve.virtualImd) + imdNet);
    }

    function _poolStateHash() private view returns (bytes32) {
        (uint160 price0, int24 tick0, uint24 protocol0, uint24 fee0) =
            IPoolManager(address(manager)).getSlot0(outer.toId());
        (uint160 price1, int24 tick1, uint24 protocol1, uint24 fee1) =
            IPoolManager(address(manager)).getSlot0(alternate.toId());
        return keccak256(
            abi.encode(
                price0,
                tick0,
                protocol0,
                fee0,
                price1,
                tick1,
                protocol1,
                fee1,
                IPoolManager(address(manager)).getLiquidity(outer.toId()),
                IPoolManager(address(manager)).getLiquidity(alternate.toId())
            )
        );
    }

    function _execute(PoolKey memory key, bool zeroForOne, uint256 amount) private returns (uint256) {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amount)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, bool zeroForOne, uint256 amount) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        require(int256(input) == -int256(amount) && output > 0, "oracle requires full fill");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(uint256(uint128(output)));
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 owed = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: owed}();
            } else {
                imd.transfer(address(manager), owed);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}
