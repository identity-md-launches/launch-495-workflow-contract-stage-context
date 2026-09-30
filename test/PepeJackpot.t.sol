// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PepeJackpot} from "../src/PepeJackpot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    JackpotTestToken,
    JackpotTestVRF,
    JackpotTestLaunchpadHook,
    JackpotLiquidityFixture,
    JackpotActor,
    JackpotForeignUnlockRelay,
    JackpotRefundRelay
} from "./mocks/JackpotFixtures.sol";

contract PepeJackpotTest is Test {
    uint256 internal constant PLAYER_KEY = 0xA11CE;
    uint256 internal constant VRF_FEE = 0.0001 ether;
    uint256 internal constant INITIAL_POT = 1_000_000 ether;
    uint256 internal constant ICE_TRADE = 10_000 ether;
    address internal player;
    address internal other = address(0xB0B);
    PoolManager internal manager;
    JackpotTestToken internal ice;
    JackpotTestToken internal imd;
    JackpotTestVRF internal wrapper;
    JackpotTestLaunchpadHook internal hook;
    PepeJackpot internal jackpot;

    function setUp() public {
        vm.warp(1_000_000);
        player = vm.addr(PLAYER_KEY);
        manager = new PoolManager(address(this));
        ice = new JackpotTestToken("Ice", "ICE");
        imd = new JackpotTestToken("IdentityMD", "IMD");
        wrapper = new JackpotTestVRF();
        JackpotTestLaunchpadHook hookCode = new JackpotTestLaunchpadHook();
        address hookAddress = address(uint160(0x10080)); // Only v4 BEFORE_SWAP_FLAG.
        vm.etch(hookAddress, address(hookCode).code);
        hook = JackpotTestLaunchpadHook(hookAddress);
        jackpot = new PepeJackpot(address(manager), address(ice), hookAddress, address(imd), address(wrapper));
        JackpotLiquidityFixture lp = new JackpotLiquidityFixture(IPoolManager(address(manager)));
        PoolKey memory iceKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(ice)), 0, 60, IHooks(hookAddress));
        PoolKey memory imdKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 200, IHooks(address(0)));
        manager.initialize(iceKey, uint160(1 << 96));
        manager.initialize(imdKey, uint160(1 << 96));
        ice.mint(address(this), 10 ** 30);
        imd.mint(address(this), 10 ** 30);
        ice.approve(address(lp), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 10 ** 31);
        lp.add{value: 10 ** 28}(iceKey, -887220, 887220, 10 ** 27);
        lp.add{value: 10 ** 28}(imdKey, -887200, 887200, 10 ** 27);
        ice.mint(player, 10 ** 27);
        imd.mint(player, 10 ** 27);
        vm.deal(player, 100 ether);
        vm.startPrank(player);
        ice.approve(address(jackpot), type(uint256).max);
        imd.approve(address(jackpot), type(uint256).max);
        jackpot.seed(INITIAL_POT);
        vm.stopPrank();
    }

    function test_SeedUsesOneUnlockAndAddsExactlyToPot() public {
        uint256 before = ice.balanceOf(player);
        _expectOneUnlock();
        vm.prank(player);
        jackpot.seed(123 ether);
        assertEq(jackpot.pot(), INITIAL_POT + 123 ether);
        assertEq(ice.balanceOf(player), before - 123 ether);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_SeedRejectsZeroAndMissingAllowance() public {
        vm.expectRevert();
        jackpot.seed(0);
        vm.prank(player);
        ice.approve(address(jackpot), 0);
        vm.prank(player);
        vm.expectRevert();
        jackpot.seed(1 ether);
        assertEq(jackpot.pot(), INITIAL_POT);
    }

    function test_FridgeSellRoutesThroughBothPoolsAndPaysExactlyOnePercent() public {
        uint256 iceBefore = ice.balanceOf(player);
        uint256 imdBefore = imd.balanceOf(player);
        uint256 nativeBefore = player.balance;
        uint256 quotedFee = ICE_TRADE / 100;
        _expectOneUnlock();
        vm.prank(player);
        (uint256 output, uint256 ticketId) =
            jackpot.fridgeSwap{value: VRF_FEE + 1 ether}(true, ICE_TRADE, 1, block.timestamp);
        assertGt(output, 0);
        assertEq(quotedFee, 100 ether);
        assertEq(ice.balanceOf(player), iceBefore - ICE_TRADE);
        assertEq(imd.balanceOf(player), imdBefore + output);
        assertEq(player.balance, nativeBefore - VRF_FEE);
        assertEq(jackpot.pot(), INITIAL_POT + 100 ether);
        assertEq(address(jackpot).balance, 0);
        assertEq(hook.swaps(), 1);
        _assertPending(ticketId, 100 ether);
        assertEq(wrapper.requestCount(), 1);
        assertEq(wrapper.lastGasLimit(), 500_000);
        assertEq(wrapper.lastConfirmations(), 3);
        assertEq(wrapper.lastNumWords(), 1);
    }

    function test_FridgeBuyChargesIceOutputAndDeliversNetAmount() public {
        uint256 input = 0.1 ether;
        uint256 potBefore = jackpot.pot();
        uint256 iceBefore = ice.balanceOf(player);
        uint256 imdBefore = imd.balanceOf(player);
        _expectOneUnlock();
        vm.prank(player);
        (uint256 output, uint256 ticketId) = jackpot.fridgeSwap{value: VRF_FEE}(false, input, 1, block.timestamp + 1);
        assertGt(output, 0);
        uint256 fee = jackpot.pot() - potBefore;
        assertGt(fee, 0);
        assertEq(fee, (output + fee) / 100);
        assertEq(ice.balanceOf(player), iceBefore + output);
        assertEq(imd.balanceOf(player), imdBefore - input);
        assertEq(jackpot.pot(), INITIAL_POT + fee);
        assertEq(ice.balanceOf(address(jackpot)), jackpot.pot());
        _assertPending(ticketId, fee);
    }

    function test_GoldenThroneSplitsNativeInputAndRefundsExcess() public {
        uint256 input = 0.001 ether;
        uint256 potBefore = jackpot.pot();
        uint256 imdBefore = imd.balanceOf(player);
        uint256 ethBefore = player.balance;
        _expectOneUnlock();
        vm.prank(player);
        (uint256 output, uint256 ticketId) =
            jackpot.goldenThrone{value: input + VRF_FEE + 0.25 ether}(input, 1, 1, block.timestamp);
        assertGt(output, 0);
        assertEq(imd.balanceOf(player), imdBefore + output);
        uint256 fee = jackpot.pot() - potBefore;
        assertGt(fee, 0);
        assertEq(player.balance, ethBefore - input - VRF_FEE);
        assertEq(address(jackpot).balance, 0);
        _assertPending(ticketId, fee);
    }

    function test_BelowThresholdSwapsDoNotBuyRandomnessAndRefundAllFee() public {
        uint256 ethBefore = player.balance;
        vm.startPrank(player);
        (, uint256 sellId) = jackpot.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE - 1, 1, block.timestamp);
        (, uint256 buyId) = jackpot.fridgeSwap{value: VRF_FEE}(false, 0.1 ether - 1, 1, block.timestamp);
        (, uint256 throneId) =
            jackpot.goldenThrone{value: 0.001 ether - 1 + VRF_FEE}(0.001 ether - 1, 1, 1, block.timestamp);
        vm.stopPrank();
        assertEq(sellId, 0);
        assertEq(buyId, 0);
        assertEq(throneId, 0);
        assertEq(wrapper.requestCount(), 0);
        assertEq(player.balance, ethBefore - (0.001 ether - 1));
    }

    function test_SlippageRevertsTokensFeesAndPoolState() public {
        uint256 balanceBefore = ice.balanceOf(player);
        vm.prank(player);
        vm.expectRevert();
        jackpot.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE, type(uint256).max, block.timestamp);
        assertEq(ice.balanceOf(player), balanceBefore);
        assertEq(jackpot.pot(), INITIAL_POT);
        assertEq(wrapper.requestCount(), 0);
        assertEq(hook.swaps(), 0);
    }

    function test_ThroneChecksBothOutputFloorsAtomically() public {
        vm.startPrank(player);
        vm.expectRevert();
        jackpot.goldenThrone{value: 0.001 ether + VRF_FEE}(0.001 ether, type(uint256).max, 1, block.timestamp);
        vm.expectRevert();
        jackpot.goldenThrone{value: 0.001 ether + VRF_FEE}(0.001 ether, 1, type(uint256).max, block.timestamp);
        vm.stopPrank();
        assertEq(jackpot.pot(), INITIAL_POT);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_InsufficientVrfFundingRevertsEveryRoute() public {
        vm.startPrank(player);
        vm.expectRevert();
        jackpot.fridgeSwap{value: VRF_FEE - 1}(true, ICE_TRADE, 1, block.timestamp);
        vm.expectRevert();
        jackpot.fridgeSwap{value: VRF_FEE - 1}(false, 0.1 ether, 1, block.timestamp);
        vm.expectRevert();
        jackpot.goldenThrone{value: 0.001 ether + VRF_FEE - 1}(0.001 ether, 1, 1, block.timestamp);
        vm.stopPrank();
        assertEq(jackpot.pot(), INITIAL_POT);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_WrapperFailureRollsBackTradeAndHook() public {
        wrapper.setFailure(true);
        uint256 before = ice.balanceOf(player);
        vm.prank(player);
        vm.expectRevert();
        jackpot.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE, 1, block.timestamp);
        assertEq(ice.balanceOf(player), before);
        assertEq(jackpot.pot(), INITIAL_POT);
        assertEq(hook.swaps(), 0);
        assertEq(address(wrapper).balance, 0);
    }

    function test_LaunchpadRejectionRollsBackTrade() public {
        hook.setRejectSwap(true);
        uint256 before = ice.balanceOf(player);
        vm.prank(player);
        vm.expectRevert();
        jackpot.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE, 1, block.timestamp);
        assertEq(ice.balanceOf(player), before);
        assertEq(jackpot.pot(), INITIAL_POT);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_ExpiredDeadlineAndZeroAmountRejected() public {
        vm.startPrank(player);
        vm.expectRevert();
        jackpot.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE, 1, block.timestamp - 1);
        vm.expectRevert();
        jackpot.goldenThrone{value: 0.001 ether + VRF_FEE}(0.001 ether, 1, 1, block.timestamp - 1);
        vm.expectRevert();
        jackpot.fridgeSwap(true, 0, 0, block.timestamp);
        vm.expectRevert();
        jackpot.goldenThrone(0, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_PermitTankFillConsumesSignatureAndAddsExactAmount() public {
        vm.prank(player);
        ice.approve(address(jackpot), 0);
        PepeJackpot.Permit memory permit = _permit(PLAYER_KEY, 3_000 ether, block.timestamp + 60);
        uint256 before = ice.balanceOf(player);
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), 2);
        vm.prank(player);
        jackpot.fillTank(3, permit);
        assertEq(ice.nonces(player), 1);
        assertEq(ice.balanceOf(player), before - 3_000 ether);
        assertEq(jackpot.pot(), INITIAL_POT + 3_000 ether);
        assertEq(wrapper.requestCount(), 0);
        vm.prank(player);
        vm.expectRevert();
        jackpot.fillTank(3, permit);
        assertEq(jackpot.pot(), INITIAL_POT + 3_000 ether);
    }

    function test_FrontrunPermitStillAllowsOwnerTankFill() public {
        vm.prank(player);
        ice.approve(address(jackpot), 0);
        PepeJackpot.Permit memory permit = _permit(PLAYER_KEY, 1_000 ether, block.timestamp + 60);
        vm.prank(other);
        ice.permit(player, address(jackpot), 1_000 ether, permit.deadline, permit.v, permit.r, permit.s);
        vm.prank(player);
        jackpot.fillTank(1, permit);
        assertEq(ice.nonces(player), 1);
        assertEq(jackpot.pot(), INITIAL_POT + 1_000 ether);
        vm.prank(other);
        vm.expectRevert();
        jackpot.fillTank(1, permit);
    }

    function test_PermitWrongSignerDeadlineAndZeroPeesFailWithoutAllowance() public {
        vm.prank(player);
        ice.approve(address(jackpot), 0);
        PepeJackpot.Permit memory expired = _permit(PLAYER_KEY, 1_000 ether, block.timestamp - 1);
        vm.prank(player);
        vm.expectRevert();
        jackpot.fillTank(1, expired);
        PepeJackpot.Permit memory wrong = _permit(1234, 1_000 ether, block.timestamp + 60);
        vm.prank(player);
        vm.expectRevert();
        jackpot.fillTank(1, wrong);
        vm.prank(player);
        vm.expectRevert();
        jackpot.fillTank(0, wrong);
        assertEq(jackpot.pot(), INITIAL_POT);
    }

    function test_Roll77PaysNinetyPercentOfAvailablePot() public {
        uint256 ticketId = _sellTicket();
        uint256 before = ice.balanceOf(player);
        uint256 available = jackpot.pot();
        // Fulfilment must never depend on the manager's lock: a draw only moves pot ICE.
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), 0);
        wrapper.fulfill(ticketId, 76);
        uint256 payout = available * 90 / 100;
        assertEq(ice.balanceOf(player), before + payout);
        assertEq(jackpot.pot(), available - payout);
        assertEq(jackpot.claimable(player), 0);
        _assertDrawn(ticketId, 77, payout);
    }

    function test_AllFiveSmallPrizeRollsPayTwentyTimesFee() public {
        for (uint256 roll = 20; roll <= 100; roll += 20) {
            uint256 ticketId = _sellTicket();
            uint256 before = ice.balanceOf(player);
            wrapper.fulfill(ticketId, roll - 1);
            assertEq(ice.balanceOf(player), before + 2_000 ether);
            _assertDrawn(ticketId, uint8(roll), 2_000 ether);
        }
    }

    function test_SmallPrizeIsCappedAtTenPercentOfAvailablePot() public {
        uint256 jackpotId = _sellTicket();
        wrapper.fulfill(jackpotId, 76);
        uint256 jackpotId2 = _sellTicket();
        wrapper.fulfill(jackpotId2, 76);
        uint256 ticketId = _sellTicket();
        uint256 available = jackpot.pot();
        uint256 before = ice.balanceOf(player);
        assertLt(available / 10, 2_000 ether);
        wrapper.fulfill(ticketId, 19);
        assertEq(ice.balanceOf(player), before + available / 10);
        _assertDrawn(ticketId, 20, available / 10);
    }

    function test_NonWinningRollHasNoPayout() public {
        uint256 ticketId = _sellTicket();
        uint256 available = jackpot.pot();
        uint256 before = ice.balanceOf(player);
        wrapper.fulfill(ticketId, 0);
        assertEq(ice.balanceOf(player), before);
        assertEq(jackpot.pot(), available);
        _assertDrawn(ticketId, 1, 0);
    }

    function test_FailedPayoutIsReservedUntilClaimAndCannotBeWonAgain() public {
        uint256 ticketId = _sellTicket();
        uint256 available = jackpot.pot();
        ice.failTransfersTo(player, 1);
        wrapper.fulfill(ticketId, 76);
        uint256 reserved = available * 90 / 100;
        assertEq(jackpot.claimable(player), reserved);
        assertEq(ice.balanceOf(address(jackpot)), available);
        assertEq(jackpot.pot(), available - reserved);
        uint256 nextTicket = _sellTicket();
        uint256 newAvailable = jackpot.pot();
        wrapper.fulfill(nextTicket, 76);
        assertEq(jackpot.claimable(player), reserved + newAvailable * 90 / 100);
        vm.prank(player);
        vm.expectRevert();
        jackpot.claim();
        uint256 allReserved = jackpot.claimable(player);
        uint256 potBefore = jackpot.pot();
        ice.failTransfersTo(player, 0);
        uint256 before = ice.balanceOf(player);
        _expectOneUnlock();
        vm.prank(player);
        jackpot.claim();
        assertEq(ice.balanceOf(player), before + allReserved);
        assertEq(jackpot.claimable(player), 0);
        assertEq(jackpot.pot(), potBefore);
        vm.prank(player);
        vm.expectRevert();
        jackpot.claim();
    }

    function test_RevertingTokenTransferAlsoDefersPayout() public {
        uint256 ticketId = _sellTicket();
        ice.failTransfersTo(player, 2);
        wrapper.fulfill(ticketId, 19);
        assertEq(jackpot.claimable(player), 2_000 ether);
        _assertDrawn(ticketId, 20, 2_000 ether);
        vm.prank(other);
        vm.expectRevert();
        jackpot.claim();
    }

    function test_TokenThatMovesThenReturnsFalseCannotSpendReservedPayout() public {
        uint256 ticketId = _sellTicket();
        uint256 playerBefore = ice.balanceOf(player);
        uint256 contractBefore = ice.balanceOf(address(jackpot));
        ice.failTransfersTo(player, 3);
        wrapper.fulfill(ticketId, 19);
        assertEq(ice.balanceOf(player), playerBefore);
        assertEq(ice.balanceOf(address(jackpot)), contractBefore);
        assertEq(jackpot.claimable(player), 2_000 ether);
        assertEq(jackpot.totalClaimable(), 2_000 ether);
        assertEq(jackpot.pot(), contractBefore - 2_000 ether);
        ice.failTransfersTo(player, 0);
        vm.prank(player);
        jackpot.claim();
        assertEq(ice.balanceOf(player), playerBefore + 2_000 ether);
        assertEq(jackpot.claimable(player), 0);
    }

    function test_CallbackProducesEventsLinkingRequestPlayerAndPrize() public {
        vm.recordLogs();
        uint256 ticketId = _sellTicket();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool issued;
        bytes32 issuedSignature = keccak256("TicketIssued(uint256,address,uint256,uint256)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(jackpot) && entries[i].topics[0] == issuedSignature) {
                assertEq(entries[i].topics[1], bytes32(ticketId));
                assertEq(entries[i].topics[2], bytes32(uint256(uint160(player))));
                (uint256 fee, uint256 expiresAt) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(fee, 100 ether);
                assertEq(expiresAt, block.timestamp + 24 hours);
                issued = true;
            }
        }
        assertTrue(issued);
        vm.recordLogs();
        wrapper.fulfill(ticketId, 19);
        entries = vm.getRecordedLogs();
        bool drawn;
        bytes32 drawnSignature = keccak256("Drawn(uint256,address,uint8,uint256,bool)");
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(jackpot) && entries[i].topics[0] == drawnSignature) {
                assertEq(entries[i].topics[1], bytes32(ticketId));
                assertEq(entries[i].topics[2], bytes32(uint256(uint160(player))));
                (uint8 roll, uint256 payout, bool deferred) = abi.decode(entries[i].data, (uint8, uint256, bool));
                assertEq(roll, 20);
                assertEq(payout, 2_000 ether);
                assertFalse(deferred);
                drawn = true;
            }
        }
        assertTrue(drawn);
    }

    function test_PartialFillFromEmptyPoolRevertsInsteadOfKeepingFee() public {
        PoolManager emptyManager = new PoolManager(address(this));
        emptyManager.initialize(jackpot.launchpadPoolKey(), uint160(1 << 96));
        emptyManager.initialize(jackpot.imdPoolKey(), uint160(1 << 96));
        PepeJackpot emptyGame =
            new PepeJackpot(address(emptyManager), address(ice), address(hook), address(imd), address(wrapper));
        vm.prank(player);
        ice.approve(address(emptyGame), type(uint256).max);
        uint256 before = ice.balanceOf(player);
        vm.prank(player);
        vm.expectRevert(PepeJackpot.PartialFill.selector);
        emptyGame.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE, 1, block.timestamp);
        assertEq(ice.balanceOf(player), before);
        assertEq(ice.balanceOf(address(emptyGame)), 0);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_MissingTradeAllowanceCannotUseExistingPot() public {
        vm.prank(player);
        ice.approve(address(jackpot), 100 ether);
        uint256 before = ice.balanceOf(player);
        vm.prank(player);
        vm.expectRevert(PepeJackpot.TokenTransferFailed.selector);
        jackpot.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE, 1, block.timestamp);
        assertEq(ice.balanceOf(player), before);
        assertEq(ice.allowance(player, address(jackpot)), 100 ether);
        assertEq(jackpot.pot(), INITIAL_POT);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_InvalidConstructorAddressesRejected() public {
        address[5] memory args = [address(manager), address(ice), address(hook), address(imd), address(wrapper)];
        for (uint256 i; i < args.length; ++i) {
            address original = args[i];
            args[i] = address(0);
            vm.expectRevert(PepeJackpot.InvalidConfiguration.selector);
            new PepeJackpot(args[0], args[1], args[2], args[3], args[4]);
            args[i] = original;
        }
        vm.expectRevert(PepeJackpot.InvalidConfiguration.selector);
        new PepeJackpot(address(manager), address(ice), address(hook), address(ice), address(wrapper));
    }

    function test_RuntimeFitsEip170AndContainsNoEscapeOpcodes() public view {
        bytes memory runtime = address(jackpot).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
            }
        }
    }

    function test_PayoutEntrypointCannotBeCalledByAPlayer() public {
        vm.prank(player);
        vm.expectRevert(PepeJackpot.UnauthorizedCallback.selector);
        jackpot.deliverPayout(player, 1 ether);
        assertEq(jackpot.pot(), INITIAL_POT);
    }

    function test_CallbackUnauthorizedUnknownDuplicateAndMalformedRequests() public {
        uint256 ticketId = _sellTicket();
        uint256[] memory words = new uint256[](1);
        words[0] = 76;
        vm.prank(player);
        vm.expectRevert();
        jackpot.rawFulfillRandomWords(ticketId, words);
        wrapper.fulfillWords(address(jackpot), ticketId + 1, words);
        words = new uint256[](0);
        wrapper.fulfillWords(address(jackpot), ticketId, words);
        _assertPending(ticketId, 100 ether);
        wrapper.fulfill(ticketId, 76);
        uint256 before = jackpot.pot();
        wrapper.fulfill(ticketId, 76);
        assertEq(jackpot.pot(), before);
    }

    function test_ExpiryAt24HoursIsUnpaidAndCannotBeRevived() public {
        uint256 ticketId = _sellTicket();
        uint256 originalTime = block.timestamp;
        vm.warp(originalTime + 24 hours - 1);
        vm.expectRevert();
        jackpot.expire(ticketId);
        vm.warp(originalTime + 24 hours);
        uint256 available = jackpot.pot();
        vm.prank(other);
        jackpot.expire(ticketId);
        (,,, PepeJackpot.TicketStatus status,, uint256 payout) = jackpot.tickets(ticketId);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Expired));
        assertEq(payout, 0);
        assertEq(jackpot.pot(), available);
        wrapper.fulfill(ticketId, 76);
        vm.expectRevert();
        jackpot.expire(ticketId);
    }

    function test_LateCallbackCannotPayEvenBeforeSomeoneExpires() public {
        uint256 ticketId = _sellTicket();
        vm.warp(block.timestamp + 24 hours);
        uint256 before = ice.balanceOf(player);
        uint256 available = jackpot.pot();
        // Either a no-op expiry or a revert is safe; valuable late randomness must never pay.
        (bool ok,) = address(wrapper).call(abi.encodeCall(wrapper.fulfill, (ticketId, 76)));
        ok;
        assertEq(ice.balanceOf(player), before);
        assertEq(jackpot.pot(), available);
    }

    function test_RefundFailureRevertsTheWholeTrade() public {
        JackpotActor actor = new JackpotActor(address(jackpot));
        ice.mint(address(actor), ICE_TRADE);
        actor.approve(ice, type(uint256).max);
        actor.configure(true, false, "");
        vm.expectRevert();
        actor.execute{value: VRF_FEE + 1}(abi.encodeCall(jackpot.fridgeSwap, (true, ICE_TRADE, 1, block.timestamp)));
        assertEq(ice.balanceOf(address(actor)), ICE_TRADE);
        assertEq(jackpot.pot(), INITIAL_POT);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_RefundReentrancyCannotStartAnotherValueAction() public {
        JackpotActor actor = new JackpotActor(address(jackpot));
        ice.mint(address(actor), ICE_TRADE + 1);
        actor.approve(ice, type(uint256).max);
        actor.configure(false, true, abi.encodeCall(jackpot.seed, (1)));
        actor.execute{value: VRF_FEE + 1}(abi.encodeCall(jackpot.fridgeSwap, (true, ICE_TRADE, 1, block.timestamp)));
        assertEq(actor.attempts(), 1);
        assertFalse(actor.reentrySucceeded());
        assertEq(ice.balanceOf(address(actor)), 1);
        assertEq(jackpot.pot(), INITIAL_POT + 100 ether);
    }

    function test_ClaimReentrancyCannotSpendReservedFundsTwice() public {
        JackpotActor actor = new JackpotActor(address(jackpot));
        ice.mint(address(actor), ICE_TRADE);
        actor.approve(ice, type(uint256).max);
        bytes memory returned =
            actor.execute{value: VRF_FEE}(abi.encodeCall(jackpot.fridgeSwap, (true, ICE_TRADE, 1, block.timestamp)));
        (, uint256 ticketId) = abi.decode(returned, (uint256, uint256));
        ice.failTransfersTo(address(actor), 1);
        wrapper.fulfill(ticketId, 76);
        uint256 reserved = jackpot.claimable(address(actor));
        ice.failTransfersTo(address(actor), 0);
        actor.configure(false, true, abi.encodeCall(jackpot.claim, ()));
        ice.setCallback(address(actor), address(actor), abi.encodeCall(actor.tokenCallback, ()));
        actor.execute(abi.encodeCall(jackpot.claim, ()));
        assertEq(actor.attempts(), 1);
        assertFalse(actor.reentrySucceeded());
        assertEq(ice.balanceOf(address(actor)), reserved);
        assertEq(jackpot.claimable(address(actor)), 0);
    }

    function test_ForeignUnlockCallbackCannotMovePot() public {
        vm.prank(player);
        vm.expectRevert();
        jackpot.unlockCallback("");
        assertEq(jackpot.pot(), INITIAL_POT);
    }

    /// @dev The coordinator accepts a valid proof from anyone; a relay inside a foreign unlock must still pay.
    function test_DeliveryInsideForeignUnlockStillPays() public {
        uint256 ticketId = _sellTicket();
        uint256 before = ice.balanceOf(player);
        uint256 available = jackpot.pot();
        JackpotForeignUnlockRelay relay = new JackpotForeignUnlockRelay(IPoolManager(address(manager)), wrapper);
        relay.deliver(ticketId, 76);
        assertTrue(relay.delivered());
        uint256 payout = available * 90 / 100;
        assertEq(ice.balanceOf(player), before + payout);
        assertEq(jackpot.pot(), available - payout);
        _assertDrawn(ticketId, 77, payout);
    }

    /// @dev A relay from a sub-threshold trade's ETH refund, while this contract's own guard is held, must pay.
    function test_DeliveryDuringAnotherTradesRefundStillPays() public {
        uint256 ticketId = _sellTicket();
        uint256 before = ice.balanceOf(player);
        JackpotRefundRelay relay = new JackpotRefundRelay(jackpot, wrapper);
        ice.mint(address(relay), 1 ether);
        relay.approve(ice);
        // The relay's own 1% fee on 1 ICE is in the pot before the draw and is part of the 90% prize.
        uint256 available = jackpot.pot() + 0.01 ether;
        relay.deliverFromRefund{value: 1}(ticketId, 76);
        assertTrue(relay.attempted());
        assertTrue(relay.delivered());
        uint256 payout = available * 90 / 100;
        assertEq(ice.balanceOf(player), before + payout);
        assertEq(jackpot.pot(), available - payout);
        _assertDrawn(ticketId, 77, payout);
        assertEq(address(relay).balance, 1);
    }

    /// @dev The same-id replay and value-action reentry from inside a delivery remain blocked.
    function test_DeliveryCannotReplayItselfOrStartAValueAction() public {
        JackpotActor actor = new JackpotActor(address(jackpot));
        ice.mint(address(actor), ICE_TRADE + 1);
        actor.approve(ice, type(uint256).max);
        bytes memory returned =
            actor.execute{value: VRF_FEE}(abi.encodeCall(jackpot.fridgeSwap, (true, ICE_TRADE, 1, block.timestamp)));
        (, uint256 ticketId) = abi.decode(returned, (uint256, uint256));
        uint256 available = jackpot.pot();
        actor.configure(false, true, abi.encodeCall(wrapper.fulfill, (ticketId, 76)));
        ice.setCallback(address(actor), address(actor), abi.encodeCall(actor.tokenCallback, ()));
        wrapper.fulfill(ticketId, 76);
        uint256 payout = available * 90 / 100;
        assertEq(actor.attempts(), 1);
        assertEq(ice.balanceOf(address(actor)), 1 + payout);
        assertEq(jackpot.pot(), available - payout);
        assertEq(jackpot.claimable(address(actor)), 0);
        _assertDrawn(ticketId, 77, payout);
    }

    function testFuzz_SellFeeAndConservation(uint128 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 10_000 ether, 100_000 ether);
        uint256 playerBefore = ice.balanceOf(player);
        uint256 managerBefore = ice.balanceOf(address(manager));

        vm.prank(player);
        (uint256 actual,) = jackpot.fridgeSwap{value: VRF_FEE}(true, amount, 1, block.timestamp);
        assertGt(actual, 0);
        assertEq(jackpot.pot(), INITIAL_POT + amount / 100);
        assertEq(ice.balanceOf(player), playerBefore - amount);
        assertEq(ice.balanceOf(address(manager)), managerBefore + amount - amount / 100);
        assertEq(address(jackpot).balance, 0);
    }

    function testFuzz_RandomWordMapsToCorrectPrizeAndConservesFunds(uint256 word, bool failTransfer) public {
        uint256 ticketId = _sellTicket();
        uint256 available = jackpot.pot();
        uint256 before = ice.balanceOf(player);
        uint8 roll = uint8(word % 100 + 1);
        uint256 expected = roll == 77 ? available * 90 / 100 : roll % 20 == 0 ? 2_000 ether : 0;
        if (failTransfer) ice.failTransfersTo(player, 1);
        wrapper.fulfill(ticketId, word);
        assertEq(jackpot.pot(), available - expected);
        assertEq(jackpot.claimable(player), failTransfer ? expected : 0);
        assertEq(ice.balanceOf(player), before + (failTransfer ? 0 : expected));
        assertEq(ice.balanceOf(address(jackpot)), jackpot.pot() + jackpot.claimable(player));
        _assertDrawn(ticketId, roll, expected);
    }

    function testFuzz_BuyConservesTokensAndReservesOnePercentOfIceOutput(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 0.1 ether, 10_000 ether);
        uint256 managerIceBefore = ice.balanceOf(address(manager));
        uint256 managerImdBefore = imd.balanceOf(address(manager));
        uint256 playerIceBefore = ice.balanceOf(player);
        uint256 playerImdBefore = imd.balanceOf(player);
        vm.prank(player);
        (uint256 received, uint256 ticketId) = jackpot.fridgeSwap{value: VRF_FEE}(false, amount, 1, block.timestamp);
        uint256 gross = managerIceBefore - ice.balanceOf(address(manager));
        uint256 fee = gross / 100;
        assertEq(received + fee, gross);
        assertEq(ice.balanceOf(player), playerIceBefore + received);
        assertEq(imd.balanceOf(player), playerImdBefore - amount);
        assertEq(imd.balanceOf(address(manager)), managerImdBefore + amount);
        assertEq(jackpot.pot(), INITIAL_POT + fee);
        _assertPending(ticketId, fee);
    }

    function _sellTicket() internal returns (uint256 ticketId) {
        vm.prank(player);
        (, ticketId) = jackpot.fridgeSwap{value: VRF_FEE}(true, ICE_TRADE, 1, block.timestamp);
    }

    function _permit(uint256 signerKey, uint256 amount, uint256 deadline)
        internal
        view
        returns (PepeJackpot.Permit memory permit)
    {
        address signer = vm.addr(signerKey);
        bytes32 structHash = keccak256(
            abi.encode(ice.PERMIT_TYPEHASH(), signer, address(jackpot), amount, ice.nonces(signer), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ice.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        permit = PepeJackpot.Permit(deadline, v, r, s);
    }

    function _expectOneUnlock() internal {
        vm.expectCall(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), 1);
    }

    function _assertPending(uint256 id, uint256 fee) internal view {
        (address who, uint48 issuedAt, uint8 roll, PepeJackpot.TicketStatus status, uint256 paid, uint256 payout) =
            jackpot.tickets(id);
        assertGt(id, 0);
        assertEq(who, player);
        assertEq(issuedAt, block.timestamp);
        assertEq(roll, 0);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Pending));
        assertEq(paid, fee);
        assertEq(payout, 0);
    }

    function _assertDrawn(uint256 id, uint8 expectedRoll, uint256 expectedPayout) internal view {
        (,, uint8 roll, PepeJackpot.TicketStatus status,, uint256 payout) = jackpot.tickets(id);
        assertEq(roll, expectedRoll);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Drawn));
        assertEq(payout, expectedPayout);
    }

    receive() external payable {}
}
