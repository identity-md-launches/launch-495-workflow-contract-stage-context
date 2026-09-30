// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeJackpot} from "src/PepeJackpot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {
    JackpotTestToken,
    JackpotTestVRF,
    JackpotTestLaunchpadHook,
    JackpotLiquidityFixture
} from "./mocks/JackpotFixtures.sol";

/// @dev Adversarial ERC-20 return data is confined to the selected recipient, so actual v4
/// settlements still execute. Rejected payout calls must roll back even token-side writes.
contract PayoutResponseToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public specialRecipient;
    uint256 public mode;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function configure(address recipient, uint256 responseMode) external {
        specialRecipient = recipient;
        mode = responseMode;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 behavior = to == specialRecipient ? mode : 0;
        // A token returning success without delivery must not discharge the player's credit.
        if (behavior == 4) return true;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += behavior == 5 ? amount - 1 : amount;
        if (behavior == 1) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (behavior == 2) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (behavior == 3) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        // Consume the bounded payout allowance; the enclosing VRF callback must still complete.
        if (behavior == 6) {
            assembly ("memory-safe") { invalid() }
        }
        return true;
    }
}

/// @dev Tests the commitment to exactly one manager callback, without simulating any swap.
contract CallbackProtocolProbe {
    uint256 public mode;

    function configure(uint256 nextMode) external {
        mode = nextMode;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (mode == 1) return "";
        if (mode == 2) return PepeJackpot(msg.sender).unlockCallback(abi.encodePacked(data, bytes1(0)));
        result = PepeJackpot(msg.sender).unlockCallback(data);
        if (mode == 3) PepeJackpot(msg.sender).unlockCallback(data);
    }
}

contract PepeJackpotAdversarialTest is Test {
    uint256 internal constant PRICE = 0.0001 ether;
    uint256 internal constant TRADE = 10_000 ether;
    uint256 internal constant INITIAL_POT = 1_000_000 ether;
    address internal constant PLAYER = address(0xA11CE);
    PayoutResponseToken internal ice;
    JackpotTestToken internal imd;
    JackpotTestVRF internal wrapper;
    PoolManager internal manager;
    PepeJackpot internal jackpot;

    function setUp() public {
        vm.warp(1_000_000);
        vm.deal(address(this), 1e31);
        vm.deal(PLAYER, 100 ether);
        manager = new PoolManager(address(this));
        ice = new PayoutResponseToken();
        imd = new JackpotTestToken("IdentityMD", "IMD");
        wrapper = new JackpotTestVRF();
        JackpotTestLaunchpadHook hook = new JackpotTestLaunchpadHook();
        address hookAddress = address(uint160(0x10080));
        vm.etch(hookAddress, address(hook).code);
        jackpot = new PepeJackpot(address(manager), address(ice), hookAddress, address(imd), address(wrapper));
        JackpotLiquidityFixture lp = new JackpotLiquidityFixture(IPoolManager(address(manager)));
        manager.initialize(jackpot.launchpadPoolKey(), uint160(1 << 96));
        manager.initialize(jackpot.imdPoolKey(), uint160(1 << 96));
        ice.mint(address(this), 1e30);
        imd.mint(address(this), 1e30);
        ice.approve(address(lp), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        lp.add{value: 1e28}(jackpot.launchpadPoolKey(), -887220, 887220, 1e27);
        lp.add{value: 1e28}(jackpot.imdPoolKey(), -887200, 887200, 1e27);
        ice.mint(PLAYER, 1e27);
        vm.startPrank(PLAYER);
        ice.approve(address(jackpot), type(uint256).max);
        jackpot.seed(INITIAL_POT);
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzJackpotRoundsDownWithoutOverflow(uint256 extra, bool deferred) public {
        uint256 id = _ticket();
        uint256 beforePot = jackpot.pot();
        // Synthetic balance extremes exercise the 256-bit payout arithmetic through its public API.
        extra = bound(extra, 0, type(uint256).max - beforePot);
        ice.mint(address(jackpot), extra);
        uint256 available = beforePot + extra;
        uint256 expected = FullMath.mulDiv(available, 9, 10);
        uint256 beforePlayer = ice.balanceOf(PLAYER);
        if (deferred) ice.configure(PLAYER, 4);
        wrapper.fulfill(id, 76);
        _assertDrawn(id, 77, expected);
        assertEq(jackpot.pot(), available - expected);
        assertEq(jackpot.totalClaimable(), deferred ? expected : 0);
        assertEq(ice.balanceOf(PLAYER), deferred ? beforePlayer : beforePlayer + expected);
        assertEq(ice.balanceOf(address(jackpot)), deferred ? available : available - expected);
    }

    function testMaximumUint256PotPaysWithoutMultiplicationOverflow() public {
        uint256 id = _ticket();
        ice.mint(address(jackpot), type(uint256).max - jackpot.pot());
        uint256 expected = FullMath.mulDiv(type(uint256).max, 9, 10);
        wrapper.fulfill(id, 76);
        _assertDrawn(id, 77, expected);
        assertEq(jackpot.pot(), type(uint256).max - expected);
        assertEq(jackpot.totalClaimable(), 0);
    }

    function testRepeatedWinnersReachDustWithoutUnderflowOrPhantomClaims() public {
        uint256[27] memory ids;
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _ticket();
        }
        for (uint256 i; i < ids.length - 1; ++i) {
            uint256 beforePot = jackpot.pot();
            uint256 expected = FullMath.mulDiv(beforePot, 9, 10);
            wrapper.fulfill(ids[i], 76);
            _assertDrawn(ids[i], 77, expected);
            assertEq(jackpot.pot(), beforePot - expected);
        }
        assertEq(jackpot.pot(), 1);
        // Even an untransferable token must not create a debt for a prize rounded to zero.
        ice.configure(PLAYER, 4);
        wrapper.fulfill(ids[26], 19);
        _assertDrawn(ids[26], 20, 0);
        assertEq(jackpot.pot(), 1);
        assertEq(jackpot.totalClaimable(), 0);
        vm.expectRevert(PepeJackpot.NothingToClaim.selector);
        vm.prank(PLAYER);
        jackpot.claim();
    }

    function testNoReturnDataPayoutAndClaimDeliverExactAmount() public {
        uint256 first = _ticket();
        ice.configure(PLAYER, 1);
        uint256 beforePlayer = ice.balanceOf(PLAYER);
        wrapper.fulfill(first, 19);
        assertEq(ice.balanceOf(PLAYER), beforePlayer + 2_000 ether);
        assertEq(jackpot.totalClaimable(), 0);
        uint256 second = _ticket();
        ice.configure(PLAYER, 4);
        wrapper.fulfill(second, 19);
        uint256 beforePot = jackpot.pot();
        uint256 beforeClaim = ice.balanceOf(PLAYER);
        ice.configure(PLAYER, 1);
        vm.prank(PLAYER);
        jackpot.claim();
        assertEq(ice.balanceOf(PLAYER), beforeClaim + 2_000 ether);
        assertEq(jackpot.totalClaimable(), 0);
        assertEq(jackpot.pot(), beforePot);
    }

    function testMalformedInexactAndGasExhaustingPayoutsPreserveCredit() public {
        for (uint256 mode = 2; mode <= 6; ++mode) {
            uint256 id = _ticket();
            uint256 beforePlayer = ice.balanceOf(PLAYER);
            uint256 beforeBalance = ice.balanceOf(address(jackpot));
            uint256 beforePot = jackpot.pot();
            ice.configure(PLAYER, mode);
            uint256[] memory words = new uint256[](1);
            words[0] = 19;
            vm.prank(address(wrapper));
            (bool success,) =
                address(jackpot).call{gas: 500_000}(abi.encodeCall(PepeJackpot.rawFulfillRandomWords, (id, words)));
            assertTrue(success, "failed token transfer consumed the VRF callback");
            _assertDrawn(id, 20, 2_000 ether);
            assertEq(ice.balanceOf(PLAYER), beforePlayer);
            assertEq(ice.balanceOf(address(jackpot)), beforeBalance);
            assertEq(jackpot.claimable(PLAYER), 2_000 ether);
            assertEq(jackpot.pot(), beforePot - 2_000 ether);
            vm.expectRevert(PepeJackpot.TokenTransferFailed.selector);
            vm.prank(PLAYER);
            jackpot.claim();
            assertEq(jackpot.claimable(PLAYER), 2_000 ether);
            assertEq(jackpot.totalClaimable(), 2_000 ether);
            assertEq(ice.balanceOf(PLAYER), beforePlayer);
            ice.configure(PLAYER, 0);
            vm.prank(PLAYER);
            jackpot.claim();
            assertEq(ice.balanceOf(PLAYER), beforePlayer + 2_000 ether);
            assertEq(jackpot.totalClaimable(), 0);
        }
    }

    function testDrawOneSecondBeforeExpiryPaysButAtExpiryDoesNot() public {
        uint256 first = _ticket();
        uint256 second = _ticket();
        uint256 issuedAt = vm.getBlockTimestamp();
        vm.warp(issuedAt + 24 hours - 1);
        wrapper.fulfill(first, 19);
        _assertDrawn(first, 20, 2_000 ether);
        uint256 beforePot = jackpot.pot();
        uint256 beforePlayer = ice.balanceOf(PLAYER);
        vm.warp(issuedAt + 24 hours);
        wrapper.fulfill(second, 76);
        (,, uint8 roll, PepeJackpot.TicketStatus status,, uint256 payout) = jackpot.tickets(second);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Expired));
        assertEq(roll, 0);
        assertEq(payout, 0);
        assertEq(jackpot.pot(), beforePot);
        assertEq(ice.balanceOf(PLAYER), beforePlayer);
    }

    function testTwoRandomWordsDoNotConsumePendingTicket() public {
        uint256 id = _ticket();
        uint256[] memory words = new uint256[](2);
        words[0] = 76;
        words[1] = 19;
        uint256 beforePot = jackpot.pot();
        wrapper.fulfillWords(address(jackpot), id, words);
        (,,, PepeJackpot.TicketStatus status,,) = jackpot.tickets(id);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Pending));
        assertEq(jackpot.pot(), beforePot);
        wrapper.fulfill(id, type(uint256).max);
        _assertDrawn(id, uint8(type(uint256).max % 100 + 1), 0);
    }

    function testZeroAndReusedRequestIdsRevertWithoutOverwritingTicket() public {
        uint256 id = _ticket();
        bytes32 original = _ticketHash(id);
        uint256 beforePot = jackpot.pot();
        uint256 beforePlayer = ice.balanceOf(PLAYER);
        uint256 beforeEth = PLAYER.balance;
        uint256 beforeWrapper = address(wrapper).balance;
        for (uint256 badId; badId <= id; ++badId) {
            vm.mockCall(
                address(wrapper), abi.encodeWithSelector(wrapper.requestRandomWordsInNative.selector), abi.encode(badId)
            );
            vm.expectRevert(PepeJackpot.InvalidConfiguration.selector);
            vm.prank(PLAYER);
            jackpot.fridgeSwap{value: PRICE}(true, TRADE, 1, block.timestamp);
            assertEq(_ticketHash(id), original);
            assertEq(jackpot.pot(), beforePot);
            assertEq(ice.balanceOf(PLAYER), beforePlayer);
            assertEq(PLAYER.balance, beforeEth);
            assertEq(address(wrapper).balance, beforeWrapper);
        }
        vm.clearMockedCalls();
        wrapper.fulfill(id, 19);
        _assertDrawn(id, 20, 2_000 ether);
    }

    function testManagerCannotSkipAlterOrReplayUnlockPayload() public {
        CallbackProtocolProbe probe = new CallbackProtocolProbe();
        PepeJackpot guarded =
            new PepeJackpot(address(probe), address(ice), address(0x10080), address(imd), address(wrapper));
        vm.prank(PLAYER);
        ice.approve(address(guarded), type(uint256).max);
        uint256 beforePlayer = ice.balanceOf(PLAYER);
        for (uint256 mode = 1; mode <= 3; ++mode) {
            probe.configure(mode);
            vm.expectRevert(PepeJackpot.UnauthorizedCallback.selector);
            vm.prank(PLAYER);
            guarded.seed(1);
            assertEq(ice.balanceOf(PLAYER), beforePlayer);
            assertEq(guarded.pot(), 0);
        }
        probe.configure(0);
        vm.prank(PLAYER);
        guarded.seed(1);
        assertEq(guarded.pot(), 1);
        assertEq(ice.balanceOf(PLAYER), beforePlayer - 1);
    }

    function testTrustedAddressesCannotInvokeCallbacksOutsideActiveAction() public {
        vm.expectRevert(PepeJackpot.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        jackpot.unlockCallback(abi.encode(PepeJackpot.Action.Seed, PLAYER, 0, abi.encode(uint256(1))));
        vm.expectRevert(PepeJackpot.UnauthorizedCallback.selector);
        vm.prank(address(jackpot));
        jackpot.deliverPayout(PLAYER, 1);
        assertEq(jackpot.pot(), INITIAL_POT);
    }

    function testSeedAndTankIntegerBoundaries() public {
        uint256 limit = uint256(uint128(type(int128).max));
        ice.mint(PLAYER, limit);
        vm.prank(PLAYER);
        jackpot.seed(limit);
        assertEq(jackpot.pot(), INITIAL_POT + limit);
        vm.expectRevert(PepeJackpot.InvalidAmount.selector);
        vm.prank(PLAYER);
        jackpot.seed(limit + 1);
        vm.expectRevert(PepeJackpot.InvalidAmount.selector);
        vm.prank(PLAYER);
        jackpot.fillTank(limit / 1_000 ether + 1, PepeJackpot.Permit(0, 0, 0, 0));
        uint256 pees = limit / 1_000 ether;
        uint256 amount = pees * 1_000 ether;
        ice.mint(PLAYER, amount);
        vm.prank(PLAYER);
        jackpot.fillTank(pees, PepeJackpot.Permit(0, 0, 0, 0));
        assertEq(jackpot.pot(), INITIAL_POT + limit + amount);
    }

    function _ticket() internal returns (uint256 id) {
        vm.prank(PLAYER);
        (, id) = jackpot.fridgeSwap{value: PRICE}(true, TRADE, 1, vm.getBlockTimestamp());
    }

    function _assertDrawn(uint256 id, uint8 expectedRoll, uint256 expectedPayout) internal view {
        (,, uint8 roll, PepeJackpot.TicketStatus status,, uint256 payout) = jackpot.tickets(id);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Drawn));
        assertEq(roll, expectedRoll);
        assertEq(payout, expectedPayout);
    }

    function _ticketHash(uint256 id) internal view returns (bytes32) {
        (address player, uint48 issued, uint8 roll, PepeJackpot.TicketStatus status, uint256 fee, uint256 payout) =
            jackpot.tickets(id);
        return keccak256(abi.encode(player, issued, roll, status, fee, payout));
    }
    receive() external payable {}
}
