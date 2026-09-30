// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeJackpot} from "../../src/PepeJackpot.sol";

interface IForkToken {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function nonces(address account) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Opt-in rehearsal: run this suite with --fork-url and a pinned mainnet block.
/// @dev Default offline runs skip explicitly. No test creates a fork or reads configuration from the environment.
contract PepeJackpotForkTest is Test {
    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant ICE = 0x64914921E03069dA66823F84fFcfB9931F05281A;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant HOOK = 0x51768F5dA32BA2008304cC81674da51aCb802888;
    address internal constant WRAPPER = 0x02aae1A04f9828517b3007f83f6181900CaD910c;
    // Synthetic signing fixture; never used to send a transaction or access a funded account.
    uint256 internal constant TEST_SIGNER = 0xA11CE;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    PepeJackpot internal jackpot;
    address internal player;

    function setUp() public {
        if (block.chainid != 1) {
            vm.skip(true);
            return;
        }
        assertGt(MANAGER.code.length, 0, "mainnet PoolManager missing");
        assertGt(ICE.code.length, 0, "mainnet ICE missing");
        assertGt(IMD.code.length, 0, "mainnet IMD missing");
        assertGt(HOOK.code.length, 0, "mainnet launchpad hook missing");
        assertGt(WRAPPER.code.length, 0, "mainnet VRF wrapper missing");
        assertEq(IForkToken(ICE).decimals(), 18, "ICE decimals changed");
        assertEq(IForkToken(IMD).decimals(), 18, "IMD decimals changed");
        (bool ok, bytes memory result) = HOOK.staticcall(abi.encodeWithSignature("poolManager()"));
        assertTrue(ok, "hook PoolManager getter reverted");
        assertEq(abi.decode(result, (address)), MANAGER, "hook uses a different PoolManager");
        jackpot = new PepeJackpot(MANAGER, ICE, HOOK, IMD, WRAPPER);
        player = vm.addr(TEST_SIGNER);
        vm.deal(player, 10 ether);
        vm.txGasPrice(2 gwei);
    }

    function testForkGoldenThroneAndRealVRFRequest() public {
        uint256 input = 0.001 ether;
        uint256 oracleFee = jackpot.vrfFee();
        uint256 beforeEth = player.balance;
        uint256 beforeImd = IForkToken(IMD).balanceOf(player);
        uint256 beforeWrapper = WRAPPER.balance;
        uint256 beforeJackpotEth = address(jackpot).balance;
        (uint256 quotedOut, uint256 quotedFee) = jackpot.quoteGoldenThrone(input);
        vm.prank(player);
        (uint256 output, uint256 id) =
            jackpot.goldenThrone{value: input + oracleFee + 0.02 ether}(input, quotedOut, quotedFee, block.timestamp);
        assertGt(output, 0);
        assertEq(output, quotedOut, "throne output quote");
        assertEq(jackpot.pot(), quotedFee, "throne ICE quote");
        assertGt(id, 0);
        assertEq(IForkToken(IMD).balanceOf(player) - beforeImd, output);
        assertEq(beforeEth - player.balance, input + oracleFee, "excess ETH was not refunded");
        assertEq(WRAPPER.balance - beforeWrapper, oracleFee, "real wrapper did not collect request price");
        assertEq(address(jackpot).balance, beforeJackpotEth, "trade retained ETH");
        assertGt(jackpot.pot(), 0);
        _assertPending(id, jackpot.pot());
    }

    function testForkFridgeBuysICEAndIssuesRealVRFRequest() public {
        uint256 input = 0.1 ether;
        deal(IMD, player, input);
        uint256 beforeIce = IForkToken(ICE).balanceOf(player);
        uint256 price = jackpot.vrfFee();
        (uint256 quotedOut, uint256 quotedFee) = jackpot.quoteFridgeSwap(false, input);
        vm.startPrank(player);
        IForkToken(IMD).approve(address(jackpot), input);
        (uint256 output, uint256 id) = jackpot.fridgeSwap{value: price}(false, input, quotedOut, block.timestamp);
        vm.stopPrank();
        assertEq(IForkToken(IMD).balanceOf(player), 0);
        assertEq(IForkToken(ICE).balanceOf(player) - beforeIce, output);
        assertGt(output, 0);
        assertEq(output, quotedOut, "fridge buy output quote");
        uint256 fee = jackpot.pot();
        assertEq(fee, quotedFee, "fridge buy fee quote");
        assertEq((output + fee) / 100, fee);
        _assertPending(id, fee);
    }

    function testForkFridgeSellsICEAndIssuesRealVRFRequest() public {
        uint256 input = 10_000 ether;
        deal(ICE, player, input);
        uint256 beforeImd = IForkToken(IMD).balanceOf(player);
        uint256 price = jackpot.vrfFee();
        (uint256 quotedOut, uint256 quotedFee) = jackpot.quoteFridgeSwap(true, input);
        vm.startPrank(player);
        IForkToken(ICE).approve(address(jackpot), input);
        (uint256 output, uint256 id) = jackpot.fridgeSwap{value: price}(true, input, quotedOut, block.timestamp);
        vm.stopPrank();
        assertEq(IForkToken(ICE).balanceOf(player), 0);
        assertEq(IForkToken(IMD).balanceOf(player) - beforeImd, output);
        assertGt(output, 0);
        assertEq(output, quotedOut, "fridge sell output quote");
        assertEq(jackpot.pot(), input / 100);
        assertEq(jackpot.pot(), quotedFee, "fridge sell fee quote");
        _assertPending(id, input / 100);
    }

    function testForkSeedAndRealICEPermitTankFill() public {
        deal(ICE, player, 7_000 ether);
        vm.startPrank(player);
        IForkToken(ICE).approve(address(jackpot), 2_000 ether);
        jackpot.seed(2_000 ether);
        vm.stopPrank();
        uint256 nonce = IForkToken(ICE).nonces(player);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IForkToken(ICE).DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, player, address(jackpot), 3_000 ether, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_SIGNER, digest);
        vm.prank(player);
        jackpot.fillTank(3, PepeJackpot.Permit(deadline, v, r, s));
        assertEq(IForkToken(ICE).nonces(player), nonce + 1);
        assertEq(IForkToken(ICE).balanceOf(player), 2_000 ether);
        assertEq(jackpot.pot(), 5_000 ether);
        assertEq(jackpot.totalClaimable(), 0);
    }

    function testForkImpossibleSlippageRevertsRealSwapsAtomically() public {
        uint256 input = 0.001 ether;
        uint256 oracleFee = jackpot.vrfFee();
        uint256 beforeEth = player.balance;
        uint256 beforeImd = IForkToken(IMD).balanceOf(player);
        vm.expectRevert(PepeJackpot.Slippage.selector);
        vm.prank(player);
        jackpot.goldenThrone{value: input + oracleFee}(input, type(uint256).max, 1, block.timestamp);
        assertEq(player.balance, beforeEth);
        assertEq(IForkToken(IMD).balanceOf(player), beforeImd);
        assertEq(jackpot.pot(), 0);
    }

    /// @dev This impersonates the authenticated wrapper: it tests payout integration, not a VRF proof.
    function testForkAuthenticatedCallbackPaysActualICE() public {
        uint256 input = 0.001 ether;
        uint256 price = jackpot.vrfFee();
        vm.prank(player);
        (, uint256 id) = jackpot.goldenThrone{value: input + price}(input, 1, 1, block.timestamp);
        uint256 beforePot = jackpot.pot();
        uint256 beforeIce = IForkToken(ICE).balanceOf(player);
        uint256[] memory words = new uint256[](1);
        words[0] = 76;
        vm.prank(WRAPPER);
        (bool callbackSucceeded,) =
            address(jackpot).call{gas: 500_000}(abi.encodeCall(PepeJackpot.rawFulfillRandomWords, (id, words)));
        assertTrue(callbackSucceeded, "callback exceeded configured gas budget or reverted");
        uint256 expected = beforePot / 10 * 9 + (beforePot % 10) * 9 / 10;
        assertEq(IForkToken(ICE).balanceOf(player) - beforeIce, expected);
        assertEq(jackpot.pot(), beforePot - expected);
        (,, uint8 roll, PepeJackpot.TicketStatus status,, uint256 payout) = jackpot.tickets(id);
        assertEq(roll, 77);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Drawn));
        assertEq(payout, expected);
        assertEq(jackpot.totalClaimable(), 0);
    }

    function _assertPending(uint256 id, uint256 fee) private view {
        (
            address ticketPlayer,
            uint48 issuedAt,
            uint8 roll,
            PepeJackpot.TicketStatus status,
            uint256 ticketFee,
            uint256 payout
        ) = jackpot.tickets(id);
        assertGt(id, 0);
        assertEq(ticketPlayer, player);
        assertEq(issuedAt, block.timestamp);
        assertEq(uint256(status), uint256(PepeJackpot.TicketStatus.Pending));
        assertEq(ticketFee, fee);
        assertEq(roll, 0);
        assertEq(payout, 0);
    }
}
