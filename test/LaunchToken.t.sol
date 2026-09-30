// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);
    uint256 internal constant SUPPLY = 1e27;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    function testMetadataAndEntireSupplyBelongToDeployer() public view {
        assertEq(token.name(), "PepeJackpot");
        assertEq(token.symbol(), "PJACK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testConstructorMintsOnlyToActualDeployerAndEmitsTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        LaunchToken deployed = new LaunchToken();
        assertEq(deployed.balanceOf(ALICE), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function testTransferMovesExactAmountAndEmitsEvent() public {
        uint256 amount = 500 ether;
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testZeroTransferSucceedsAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testSelfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApproveSetsReplacesAndRevokesAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, 100 ether);
        assertTrue(token.approve(SPENDER, 100 ether));
        assertEq(token.allowance(address(this), SPENDER), 100 ether);
        token.approve(SPENDER, 10 ether);
        assertEq(token.allowance(address(this), SPENDER), 10 ether);
        token.approve(SPENDER, 0);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function testTransferFromSpendsExactAllowance() public {
        token.approve(SPENDER, 100 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 70 ether));
        assertEq(token.allowance(address(this), SPENDER), 30 ether);
        assertEq(token.balanceOf(ALICE), 70 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 70 ether);
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 30 ether);
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testMaximumAllowanceRemainsUnchanged() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, SUPPLY));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function testUnapprovedZeroTransferFromSucceeds() public {
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testTransferRevertsForInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferFromRevertsForInsufficientAllowance() public {
        token.approve(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 1, 2));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 2);
        assertEq(token.allowance(address(this), SPENDER), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testRevertingTransferFromRestoresAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(token.allowance(ALICE, SPENDER), 100);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testTransferRejectsZeroReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferFromRejectsZeroReceiverAndRestoresAllowance() public {
        token.approve(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), SPENDER), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testTransferFromRejectsZeroSender() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function testApproveRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function testNoAdministrativeOrSupplyChangingEntryPoints() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "pause()",
            "setFee(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)",
            "setBlacklist(address,bool)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, uint256(1)));
            assertFalse(success, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzzTransferSequenceConservesSupply(uint256 first, uint256 second, uint256 approved) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, first);
        approved = bound(approved, 0, first - second);
        token.transfer(ALICE, first);
        vm.prank(ALICE);
        token.transfer(BOB, second);
        vm.prank(ALICE);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, approved);
        assertEq(token.balanceOf(address(this)), SUPPLY - first);
        assertEq(token.balanceOf(ALICE), first - second - approved);
        assertEq(token.balanceOf(BOB), second + approved);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB), SUPPLY);
    }

    function testFuzzTransferCannotOverspend(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, amount));
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
