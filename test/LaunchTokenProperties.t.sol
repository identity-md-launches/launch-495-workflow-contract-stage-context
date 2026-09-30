// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenBoundaryPropertiesTest is Test {
    LaunchToken internal token;
    address internal constant ALICE = address(0xA110);
    address internal constant BOB = address(0xB020);
    address internal constant SPENDER = address(0x5EED);
    uint256 internal constant SUPPLY = 1e27;

    function setUp() public {
        token = new LaunchToken();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzDelegatedSelfTransferConsumesOnlyFiniteAllowance(uint256 amount, uint256 extra) public {
        amount = bound(amount, 0, SUPPLY);
        extra = bound(extra, 0, type(uint256).max - 1 - amount);
        token.approve(SPENDER, amount + extra);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), address(this), amount));

        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), SPENDER), extra);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzApprovalDoesNotAuthorizeDifferentSpender(uint256 approval, uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        token.approve(SPENDER, approval);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, BOB, 0, amount));
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, amount);

        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(address(this), SPENDER), approval);
        assertEq(token.allowance(address(this), BOB), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzBalanceFailureRestoresEveryAllowance(uint256 funded, uint256 approval) public {
        funded = bound(funded, 0, SUPPLY);
        uint256 amount = funded + 1;
        approval = bound(approval, amount, type(uint256).max);
        token.transfer(ALICE, funded);
        vm.prank(ALICE);
        token.approve(SPENDER, approval);

        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, funded, amount));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);

        assertEq(token.balanceOf(address(this)), SUPPLY - funded);
        assertEq(token.balanceOf(ALICE), funded);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(ALICE, SPENDER), approval);
    }

    function testInfiniteApprovalCanBeReplacedAndRevoked() public {
        token.approve(SPENDER, type(uint256).max);
        token.approve(SPENDER, 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), 0);

        token.approve(SPENDER, type(uint256).max);
        token.approve(SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function testDelegatedSelfTransferAtZeroOneAndFullSupply() public {
        token.approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        assertTrue(token.transferFrom(address(this), address(this), 0));
        assertTrue(token.transferFrom(address(this), address(this), 1));
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY));
        vm.stopPrank();
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
    }

    function testMaximumTransferAmountRevertsWithoutOverflowOrStateChange() public {
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
    }

    function testValueBearingCallsCannotTrapEthOrMutateTokenState() public {
        vm.deal(address(this), 1 ether);
        bytes[4] memory calls = [
            bytes(""),
            abi.encodeCall(LaunchToken.transfer, (ALICE, 1)),
            abi.encodeCall(LaunchToken.approve, (SPENDER, 1)),
            abi.encodeCall(LaunchToken.transferFrom, (address(this), ALICE, 0))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(token).call{value: 1}(calls[i]);
            assertFalse(success);
        }
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }
}

/// @dev Records requested token flows independently of the token's balance getters. The closed
/// actor set includes the deployer, so every minted unit remains accounted for across sequences.
contract LaunchTokenSequenceHandler is Test {
    uint256 public constant SUPPLY = 1e27;
    LaunchToken public immutable token;
    address[4] public actors;
    uint256[4] public sent;
    uint256[4] public received;
    uint256[4][4] public expectedAllowance;

    constructor() {
        actors = [address(this), address(0xA110), address(0xB020), address(0xCA30)];
        token = new LaunchToken();
        for (uint256 i = 1; i < actors.length; ++i) {
            token.transfer(actors[i], SUPPLY / 4);
        }
    }

    function expectedBalance(uint256 actorIndex) public view returns (uint256) {
        return SUPPLY / 4 + received[actorIndex] - sent[actorIndex];
    }

    function transfer(uint256 senderSeed, uint256 receiverSeed, uint256 amountSeed) external {
        uint256 sender = senderSeed % 4;
        uint256 receiver = receiverSeed % 4;
        uint256 amount = _amount(amountSeed, expectedBalance(sender));
        vm.prank(actors[sender]);
        assertTrue(token.transfer(actors[receiver], amount));
        _recordFlow(sender, receiver, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 amount;
        if (amountSeed % 4 == 0) amount = 0;
        else if (amountSeed % 4 == 1) amount = 1;
        else if (amountSeed % 4 == 2) amount = type(uint256).max;
        else amount = bound(amountSeed, 0, SUPPLY);
        _approve(owner, spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 receiverSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 receiver = receiverSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 permitted = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance(owner);
        uint256 amount = _amount(amountSeed, permitted < balance ? permitted : balance);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[receiver], amount));
        if (permitted != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _recordFlow(owner, receiver, amount);
    }

    function attemptOverspend(uint256 senderSeed, uint256 receiverSeed) external {
        uint256 sender = senderSeed % 4;
        uint256 balance = expectedBalance(sender);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, actors[sender], balance, balance + 1)
        );
        vm.prank(actors[sender]);
        token.transfer(actors[receiverSeed % 4], balance + 1);
    }

    function revokeAndAttemptSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 receiverSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        _approve(owner, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, actors[spender], 0, 1));
        vm.prank(actors[spender]);
        token.transferFrom(actors[owner], actors[receiverSeed % 4], 1);
    }

    function attemptInvalidReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 amount = _amount(amountSeed, expectedBalance(owner));
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(actors[spender]);
        token.transferFrom(actors[owner], address(0), amount);
    }

    function _approve(uint256 owner, uint256 spender, uint256 amount) internal {
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _recordFlow(uint256 sender, uint256 receiver, uint256 amount) internal {
        sent[sender] += amount;
        received[receiver] += amount;
    }

    function _amount(uint256 seed, uint256 maximum) internal pure returns (uint256) {
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return maximum == 0 ? 0 : 1;
        if (seed % 4 == 2) return maximum;
        return bound(seed, 0, maximum);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenSequenceInvariantTest is StdInvariant, Test {
    LaunchTokenSequenceHandler internal handler;
    LaunchToken internal token;

    function setUp() public {
        handler = new LaunchTokenSequenceHandler();
        token = handler.token();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.attemptOverspend.selector;
        selectors[4] = handler.revokeAndAttemptSpend.selector;
        selectors[5] = handler.attemptInvalidReceiver.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantBalancesAndAllowancesMatchRequestedFlows() public view {
        uint256 balanceSum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 actualBalance = token.balanceOf(actor);
            balanceSum += actualBalance;
            assertEq(actualBalance, handler.expectedBalance(i), "balance diverged from requested flows");
            for (uint256 j; j < 4; ++j) {
                assertEq(
                    token.allowance(actor, handler.actors(j)),
                    handler.expectedAllowance(i, j),
                    "allowance diverged from approvals and delegated spending"
                );
            }
            assertEq(token.allowance(actor, address(0)), 0);
        }
        assertEq(balanceSum, 1e27, "transfers created or destroyed balances");
        assertEq(token.totalSupply(), 1e27, "fixed supply changed");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
