// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeJackpot} from "src/PepeJackpot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {
    JackpotTestToken,
    JackpotTestVRF,
    JackpotTestLaunchpadHook,
    JackpotLiquidityFixture,
    JackpotForeignUnlockRelay,
    JackpotRefundRelay
} from "./mocks/JackpotFixtures.sol";

/// @dev The manager and both pools are real v4 deployments. Only the external tokens,
/// launchpad hook and VRF delivery are local stand-ins; no RPC is required.
/// Oracle words arrive through three contexts the revised source must treat alike: the
/// wrapper directly, a relay inside a foreign PoolManager.unlock, and a relay from the ETH
/// refund of the relay's own sub-threshold trade while this contract's guard is held.
contract PepeJackpotSequenceHandler is Test {
    uint256 private constant RELAY_TRADE = 1 ether;

    JackpotForeignUnlockRelay public immutable unlockRelay;
    JackpotRefundRelay public immutable refundRelay;

    struct ExpectedTicket {
        address player;
        uint256 issuedAt;
        uint256 fee;
        uint256 payout;
        uint8 roll;
        PepeJackpot.TicketStatus status;
    }

    PepeJackpot public immutable jackpot;
    JackpotTestToken public immutable ice;
    JackpotTestToken public immutable imd;
    JackpotTestVRF public immutable wrapper;
    address public immutable manager;
    address[4] public actors;
    mapping(address => uint256) public reserved;
    mapping(uint256 => ExpectedTicket) public expectedTickets;
    uint256 public contributed;
    uint256 public paid;
    uint256 public ticketCount;

    constructor(PepeJackpot game, JackpotTestToken iceToken, JackpotTestToken imdToken, JackpotTestVRF vrf) {
        jackpot = game;
        ice = iceToken;
        imd = imdToken;
        wrapper = vrf;
        manager = address(game.poolManager());
        vm.deal(address(this), 1e30);
        unlockRelay = new JackpotForeignUnlockRelay(IPoolManager(manager), vrf);
        refundRelay = new JackpotRefundRelay(game, vrf);
        iceToken.mint(address(refundRelay), 1e24);
        refundRelay.approve(iceToken);
        for (uint256 i; i < actors.length; ++i) {
            address actor = vm.addr(0xCAFE + i);
            actors[i] = actor;
            ice.mint(actor, 1e30);
            imd.mint(actor, 1e30);
            vm.deal(actor, 1e30);
            vm.startPrank(actor);
            ice.approve(address(game), type(uint256).max);
            imd.approve(address(game), type(uint256).max);
            vm.stopPrank();
        }
    }

    function seed(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 1, 100_000 ether);
        uint256 beforePlayer = ice.balanceOf(actor);
        vm.prank(actor);
        jackpot.seed(amount);
        contributed += amount;
        assertEq(ice.balanceOf(actor), beforePlayer - amount, "seed debit");
    }

    function donate(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 1, 100_000 ether);
        vm.prank(actor);
        assertTrue(ice.transfer(address(jackpot), amount));
        contributed += amount;
    }

    function fillTank(uint256 actorSeed, uint256 peesSeed, bool signedPermit) public {
        uint256 index = actorSeed % 4;
        address actor = actors[index];
        uint256 pees = bound(peesSeed, 1, 100);
        uint256 amount = pees * 1_000 ether;
        PepeJackpot.Permit memory permit;
        if (signedPermit) {
            permit.deadline = block.timestamp;
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    ice.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            ice.PERMIT_TYPEHASH(), actor, address(jackpot), amount, ice.nonces(actor), permit.deadline
                        )
                    )
                )
            );
            (permit.v, permit.r, permit.s) = vm.sign(0xCAFE + index, digest);
        }
        uint256 beforePlayer = ice.balanceOf(actor);
        vm.startPrank(actor);
        jackpot.fillTank(pees, permit);
        ice.approve(address(jackpot), type(uint256).max);
        vm.stopPrank();
        contributed += amount;
        assertEq(ice.balanceOf(actor), beforePlayer - amount, "tank debit");
    }

    function sellIce(uint256 actorSeed, uint256 amountSeed, uint256 excessSeed) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = _tradeAmount(amountSeed, 100, 10_000 ether, 20_000 ether);
        uint256 fee = amount / 100;
        uint256 beforeIce = ice.balanceOf(actor);
        uint256 beforeImd = imd.balanceOf(actor);
        uint256 beforeNative = actor.balance;
        uint256 budget = wrapper.price() + bound(excessSeed, 0, 1 ether);
        vm.prank(actor);
        (uint256 output, uint256 id) = jackpot.fridgeSwap{value: budget}(true, amount, 1, block.timestamp);
        contributed += fee;
        assertEq(ice.balanceOf(actor), beforeIce - amount, "sell consumes input once");
        assertEq(imd.balanceOf(actor), beforeImd + output, "sell delivers output");
        assertEq(actor.balance, beforeNative - (amount >= 10_000 ether ? wrapper.price() : 0), "sell refunds payer");
        _recordTicket(id, actor, fee, amount >= 10_000 ether);
    }

    function buyIce(uint256 actorSeed, uint256 amountSeed, uint256 excessSeed) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = _tradeAmount(amountSeed, 1_000, 0.1 ether, 2 ether);
        uint256 beforePool = ice.balanceOf(manager);
        uint256 beforeIce = ice.balanceOf(actor);
        uint256 beforeImd = imd.balanceOf(actor);
        uint256 beforeNative = actor.balance;
        uint256 budget = wrapper.price() + bound(excessSeed, 0, 1 ether);
        vm.prank(actor);
        (uint256 output, uint256 id) = jackpot.fridgeSwap{value: budget}(false, amount, 1, block.timestamp);
        // Gross ICE comes from the independently observed pool withdrawal, not pot()
        // or the ticket's declared fee. Check both recipients against that amount.
        uint256 gross = beforePool - ice.balanceOf(manager);
        uint256 fee = gross / 100;
        contributed += fee;
        assertEq(output + fee, gross, "buy divides gross ICE between player and pot");
        assertEq(ice.balanceOf(actor), beforeIce + output, "buy delivers output");
        assertEq(imd.balanceOf(actor), beforeImd - amount, "buy consumes input once");
        assertEq(actor.balance, beforeNative - (amount >= 0.1 ether ? wrapper.price() : 0), "buy refunds payer");
        _recordTicket(id, actor, fee, amount >= 0.1 ether);
    }

    function throne(uint256 actorSeed, uint256 amountSeed, uint256 excessSeed) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = _tradeAmount(amountSeed, 10_000, 0.001 ether, 2 ether);
        uint256 beforePool = ice.balanceOf(manager);
        uint256 beforePlayer = imd.balanceOf(actor);
        uint256 beforeNative = actor.balance;
        uint256 budget = amount + wrapper.price() + bound(excessSeed, 0, 1 ether);
        vm.prank(actor);
        (uint256 output, uint256 id) = jackpot.goldenThrone{value: budget}(amount, 1, 1, block.timestamp);
        uint256 fee = beforePool - ice.balanceOf(manager);
        contributed += fee;
        assertGt(fee, 0);
        assertEq(imd.balanceOf(actor), beforePlayer + output, "throne delivers output");
        assertEq(
            actor.balance,
            beforeNative - amount - (amount >= 0.001 ether ? wrapper.price() : 0),
            "throne charges trade and oracle fee and refunds payer"
        );
        _recordTicket(id, actor, fee, amount >= 0.001 ether);
    }

    function fulfill(uint256 ticketSeed, uint256 wordSeed, uint8 failureSeed) public {
        _fulfill(ticketSeed, wordSeed, failureSeed, 0);
    }

    /// @dev The same word, delivered while a third party holds the manager's lock or this contract's guard.
    function relayFulfill(uint256 ticketSeed, uint256 wordSeed, uint8 failureSeed, bool viaRefund) public {
        _fulfill(ticketSeed, wordSeed, failureSeed, viaRefund ? 2 : 1);
    }

    function _fulfill(uint256 ticketSeed, uint256 wordSeed, uint8 failureSeed, uint8 context) private {
        if (ticketCount == 0) return;
        uint256 id = 1 + ticketSeed % ticketCount;
        ExpectedTicket storage ticket = expectedTickets[id];
        uint256 word = _randomWord(wordSeed);
        uint256 payout;
        // The refund relay's own 1% fee on its sub-threshold sell is in the pot before the word arrives.
        if (context == 2) contributed += RELAY_TRADE / 100;
        bool draws = ticket.status == PepeJackpot.TicketStatus.Pending && block.timestamp < ticket.issuedAt + 24 hours;
        if (draws) {
            uint256 available = contributed - paid - _totalReserved();
            uint256 roll = word % 100 + 1;
            // Direct specification arithmetic is safe over this campaign's bounded inputs.
            if (roll == 77) payout = available * 90 / 100;
            else if (roll % 20 == 0) payout = _min(ticket.fee * 20, available / 10);
        }
        uint256 beforePlayer = ice.balanceOf(ticket.player);
        uint8 failure = failureSeed % 4;
        ice.failTransfersTo(ticket.player, failure);
        if (context == 0) {
            wrapper.fulfill(id, word);
        } else if (context == 1) {
            unlockRelay.deliver(id, word);
            assertTrue(unlockRelay.delivered(), "a delivery inside a foreign unlock is accepted");
        } else {
            uint256 beforeRelayIce = ice.balanceOf(address(refundRelay));
            uint256 beforeRelayEth = address(refundRelay).balance;
            refundRelay.deliverFromRefund{value: 1}(id, word);
            assertTrue(refundRelay.attempted(), "the sub-threshold trade refunded its whole budget");
            assertTrue(refundRelay.delivered(), "a delivery while the guard is held is accepted");
            assertEq(ice.balanceOf(address(refundRelay)), beforeRelayIce - RELAY_TRADE, "relay paid its own trade");
            assertEq(address(refundRelay).balance, beforeRelayEth + 1, "relay budget refunded in full");
        }
        ice.failTransfersTo(ticket.player, 0);

        if (draws) {
            ticket.status = PepeJackpot.TicketStatus.Drawn;
            ticket.roll = uint8(word % 100 + 1);
            ticket.payout = payout;
            if (failure == 0) paid += payout;
            else reserved[ticket.player] += payout;
        } else if (ticket.status == PepeJackpot.TicketStatus.Pending) {
            ticket.status = PepeJackpot.TicketStatus.Expired;
        }
        assertEq(ice.balanceOf(ticket.player), beforePlayer + (failure == 0 ? payout : 0), "payout occurs once");
    }

    function claim(uint256 actorSeed, uint8 failureSeed) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = reserved[actor];
        uint256 beforePlayer = ice.balanceOf(actor);
        uint8 failure = failureSeed % 4;
        ice.failTransfersTo(actor, failure);
        vm.prank(actor);
        if (amount == 0) {
            vm.expectRevert(PepeJackpot.NothingToClaim.selector);
            jackpot.claim();
        } else if (failure != 0) {
            vm.expectRevert(PepeJackpot.TokenTransferFailed.selector);
            jackpot.claim();
        } else {
            jackpot.claim();
            paid += amount;
            reserved[actor] = 0;
        }
        ice.failTransfersTo(actor, 0);
        assertEq(ice.balanceOf(actor), beforePlayer + (failure == 0 ? amount : 0), "claim debit is atomic");
    }

    function advanceTime(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 48 hours));
    }

    function expire(uint256 ticketSeed) public {
        uint256 id = ticketCount == 0 ? 1 : 1 + ticketSeed % ticketCount;
        ExpectedTicket storage ticket = expectedTickets[id];
        if (ticket.status != PepeJackpot.TicketStatus.Pending) {
            vm.expectRevert(PepeJackpot.TicketNotPending.selector);
            jackpot.expire(id);
        } else if (block.timestamp < ticket.issuedAt + 24 hours) {
            vm.expectRevert(PepeJackpot.TicketNotExpired.selector);
            jackpot.expire(id);
        } else {
            jackpot.expire(id);
            ticket.status = PepeJackpot.TicketStatus.Expired;
        }
    }

    function malformedCallback(uint256 ticketSeed, bool empty, bool unknown) public {
        uint256 id = unknown || ticketCount == 0 ? ticketCount + 1 : 1 + ticketSeed % ticketCount;
        uint256[] memory words = new uint256[](unknown ? 1 : (empty ? 0 : 2));
        wrapper.fulfillWords(address(jackpot), id, words);
    }

    function assertConservation() public view {
        uint256 totalReserved = _totalReserved();
        assertEq(ice.balanceOf(address(jackpot)) + paid, contributed, "all ICE inflows are held or paid");
        assertEq(jackpot.totalClaimable(), totalReserved, "aggregate claims match independent actor debts");
        assertLe(totalReserved, ice.balanceOf(address(jackpot)), "deferred payouts remain solvent");
        assertEq(jackpot.pot(), contributed - paid - totalReserved, "reserved winnings cannot win again");
        for (uint256 i; i < actors.length; ++i) {
            assertEq(jackpot.claimable(actors[i]), reserved[actors[i]], "each actor owns its claim");
        }
    }

    function assertTickets() public view {
        assertEq(wrapper.requestCount(), ticketCount, "one oracle request per eligible trade");
        for (uint256 id = 1; id <= ticketCount; ++id) {
            ExpectedTicket storage expected = expectedTickets[id];
            (
                address player,
                uint48 issuedAt,
                uint8 roll,
                PepeJackpot.TicketStatus status,
                uint256 fee,
                uint256 payout
            ) = jackpot.tickets(id);
            assertEq(player, expected.player, "ticket owner is immutable");
            assertEq(issuedAt, expected.issuedAt, "ticket deadline cannot restart");
            assertEq(fee, expected.fee, "ticket records exactly its contributed fee");
            assertEq(uint256(status), uint256(expected.status), "terminal tickets cannot reopen");
            assertEq(roll, expected.roll, "only authenticated first valid callback determines roll");
            assertEq(payout, expected.payout, "payout follows pre-draw available pot");
        }
    }

    function _recordTicket(uint256 id, address actor, uint256 fee, bool eligible) private {
        if (!eligible) {
            assertEq(id, 0, "small trades do not issue tickets");
            return;
        }
        assertEq(id, ++ticketCount, "ticket cannot reuse a prior request");
        expectedTickets[id] = ExpectedTicket(actor, block.timestamp, fee, 0, 0, PepeJackpot.TicketStatus.Pending);
    }

    function _totalReserved() private view returns (uint256 result) {
        for (uint256 i; i < actors.length; ++i) {
            result += reserved[actors[i]];
        }
    }

    function _tradeAmount(uint256 seedValue, uint256 low, uint256 threshold, uint256 high)
        private
        pure
        returns (uint256)
    {
        uint256 mode = seedValue % 6;
        if (mode == 0) return low;
        if (mode == 1) return threshold - 1;
        if (mode == 2) return threshold;
        if (mode == 3) return threshold + 1;
        if (mode == 4) return high;
        return low + seedValue % (high - low + 1);
    }

    function _randomWord(uint256 seedValue) private pure returns (uint256) {
        if (seedValue % 4 == 0) return 76; // Jackpot.
        if (seedValue % 4 == 1) return 19 + 20 * (seedValue % 5); // Every minor prize.
        if (seedValue % 4 == 2) return 0; // Losing draw.
        return seedValue; // Includes type(uint256).max and unconstrained modulo inputs.
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PepeJackpotInvariantTest is Test {
    using TransientStateLibrary for IPoolManager;

    PoolManager internal manager;
    JackpotTestToken internal ice;
    JackpotTestToken internal imd;
    JackpotTestVRF internal wrapper;
    PepeJackpot internal jackpot;
    PepeJackpotSequenceHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        manager = new PoolManager(address(this));
        ice = new JackpotTestToken("Ice", "ICE");
        imd = new JackpotTestToken("IdentityMD", "IMD");
        wrapper = new JackpotTestVRF();
        JackpotTestLaunchpadHook hookCode = new JackpotTestLaunchpadHook();
        address hook = address(uint160(0x10080));
        vm.etch(hook, address(hookCode).code);
        jackpot = new PepeJackpot(address(manager), address(ice), hook, address(imd), address(wrapper));
        JackpotLiquidityFixture lp = new JackpotLiquidityFixture(IPoolManager(address(manager)));
        PoolKey memory iceKey = jackpot.launchpadPoolKey();
        PoolKey memory imdKey = jackpot.imdPoolKey();
        manager.initialize(iceKey, uint160(1 << 96));
        manager.initialize(imdKey, uint160(1 << 96));
        ice.mint(address(this), 1e30);
        imd.mint(address(this), 1e30);
        ice.approve(address(lp), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 1e31);
        lp.add{value: 1e28}(iceKey, -887220, 887220, 1e27);
        lp.add{value: 1e28}(imdKey, -887200, 887200, 1e27);
        handler = new PepeJackpotSequenceHandler(jackpot, ice, imd, wrapper);
        handler.seed(0, 100_000 ether);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[11] = handler.relayFulfill.selector;
        selectors[0] = handler.seed.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.fillTank.selector;
        selectors[3] = handler.sellIce.selector;
        selectors[4] = handler.buyIce.selector;
        selectors[5] = handler.throne.selector;
        selectors[6] = handler.fulfill.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.advanceTime.selector;
        selectors[9] = handler.expire.selector;
        selectors[10] = handler.malformedCallback.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ConservationAndReservedClaims() public view {
        handler.assertConservation();
    }

    function invariant_TicketsMatchTheirHistoryAndNeverReopen() public view {
        handler.assertTickets();
    }

    function invariant_UnlockSettlesAllCurrenciesAndRefundsSurplus() public view {
        IPoolManager pool = IPoolManager(address(manager));
        assertFalse(pool.isUnlocked(), "manager relocks after every action");
        assertEq(pool.getNonzeroDeltaCount(), 0, "no unsettled currency debt");
        assertEq(address(jackpot).balance, 0, "no native input or excess refund retained");
        assertEq(imd.balanceOf(address(jackpot)), 0, "IMD output belongs to players");
        assertEq(address(wrapper).balance, handler.ticketCount() * wrapper.price(), "one exact fee per ticket");
    }

    function test_HandlerExercisesDeferredClaimsAndTerminalTickets() public {
        handler.sellIce(0, 2, 1 ether);
        handler.fulfill(0, 0, 3); // A false-return transfer that mutates must still be rolled back.
        assertGt(handler.reserved(handler.actors(0)), 0);
        handler.assertConservation();
        handler.buyIce(1, 2, 0);
        handler.fulfill(1, 0, 0); // Second jackpot may not spend the first player's reserved prize.
        handler.claim(0, 2);
        handler.assertConservation();
        handler.claim(0, 0);
        handler.claim(0, 0);
        handler.fulfill(0, type(uint256).max, 0);
        handler.fillTank(2, 3, true);
        handler.fillTank(3, 2, false);
        handler.donate(3, 1);
        handler.throne(2, 2, 0);
        handler.advanceTime(24 hours);
        handler.expire(2);
        handler.fulfill(2, 0, 0);
        handler.malformedCallback(1, true, false);
        handler.assertConservation();
        handler.assertTickets();
        invariant_UnlockSettlesAllCurrenciesAndRefundsSurplus();
    }

    /// @dev Relayed words pay, defer and expire exactly like direct ones; a relay cannot replay a drawn ticket.
    function test_HandlerRelaysWordsThroughForeignUnlockAndGuardedRefund() public {
        handler.sellIce(0, 2, 0);
        handler.buyIce(1, 2, 0);
        handler.throne(2, 2, 0);
        handler.relayFulfill(0, 0, 0, false); // Jackpot paid from inside a foreign unlock.
        handler.relayFulfill(1, 1, 3, true); // Minor prize deferred while the guard is held.
        assertGt(handler.reserved(handler.actors(1)), 0);
        handler.relayFulfill(0, 1, 0, true); // Replay of a drawn ticket is ignored.
        handler.claim(1, 0);
        handler.advanceTime(24 hours);
        handler.relayFulfill(2, 0, 0, false); // Late relay expires, never pays.
        handler.assertConservation();
        handler.assertTickets();
        invariant_UnlockSettlesAllCurrenciesAndRefundsSurplus();
    }

    receive() external payable {}
}
