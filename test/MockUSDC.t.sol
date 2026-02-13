// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_initialState() public view {
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "mUSDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.owner(), address(this));
        assertEq(usdc.totalSupply(), 0);
    }

    function test_mint_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not owner"));
        usdc.mint(alice, 1e6);
    }

    function test_mint_updatesSupplyAndBalance() public {
        usdc.mint(alice, 50e6);
        assertEq(usdc.totalSupply(), 50e6);
        assertEq(usdc.balanceOf(alice), 50e6);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(bytes("balance"));
        usdc.transfer(bob, 1);
    }

    function test_transfer_revertsOnZeroRecipient() public {
        usdc.mint(alice, 5e6);
        vm.prank(alice);
        vm.expectRevert(bytes("zero to"));
        usdc.transfer(address(0), 1e6);
    }

    function test_transfer_movesBalance() public {
        usdc.mint(alice, 5e6);

        vm.prank(alice);
        bool ok = usdc.transfer(bob, 2e6);
        assertTrue(ok);

        assertEq(usdc.balanceOf(alice), 3e6);
        assertEq(usdc.balanceOf(bob), 2e6);
    }

    function test_transferFrom_revertsWithoutAllowance() public {
        usdc.mint(alice, 5e6);

        vm.prank(bob);
        vm.expectRevert(bytes("allowance"));
        usdc.transferFrom(alice, bob, 1e6);
    }

    function test_approve_andTransferFrom_reduceAllowance() public {
        usdc.mint(alice, 10e6);

        vm.prank(alice);
        bool approved = usdc.approve(bob, 7e6);
        assertTrue(approved);
        assertEq(usdc.allowance(alice, bob), 7e6);

        vm.prank(bob);
        bool ok = usdc.transferFrom(alice, bob, 3e6);
        assertTrue(ok);

        assertEq(usdc.balanceOf(alice), 7e6);
        assertEq(usdc.balanceOf(bob), 3e6);
        assertEq(usdc.allowance(alice, bob), 4e6);
    }
}

