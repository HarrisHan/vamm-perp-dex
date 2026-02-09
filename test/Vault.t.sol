// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Vault.sol";
import "../src/mocks/MockUSDC.sol";

contract VaultTest is Test {
    Vault public vault;
    MockUSDC public usdc;

    address public owner = address(this);
    address public clearingHouse = address(0x1);
    address public alice = address(0x2);

    uint256 public constant INITIAL_BALANCE = 10000e6;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new Vault(address(usdc));
        vault.setClearingHouse(clearingHouse);

        usdc.mint(alice, INITIAL_BALANCE);
        
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Initialization Tests ============

    function test_QuoteAsset() public view {
        assertEq(address(vault.quoteAsset()), address(usdc));
    }

    function test_ClearingHouseSet() public view {
        assertEq(vault.clearingHouse(), clearingHouse);
    }

    // ============ Deposit Tests ============

    function test_Deposit() public {
        uint256 amount = 100e6;

        vm.prank(clearingHouse);
        vault.deposit(alice, amount);

        assertEq(vault.getTotalDeposits(), amount);
        assertEq(vault.getBalance(), amount);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - amount);
    }

    function test_DepositEvent() public {
        uint256 amount = 100e6;

        vm.expectEmit(true, false, false, true);
        emit Vault.Deposited(alice, amount);

        vm.prank(clearingHouse);
        vault.deposit(alice, amount);
    }

    function test_RevertWhen_NonClearingHouseDeposits() public {
        vm.prank(alice);
        vm.expectRevert(Vault.OnlyClearingHouse.selector);
        vault.deposit(alice, 100e6);
    }

    // ============ Withdraw Tests ============

    function test_Withdraw() public {
        uint256 depositAmount = 100e6;
        uint256 withdrawAmount = 50e6;

        // First deposit
        vm.prank(clearingHouse);
        vault.deposit(alice, depositAmount);

        // Then withdraw
        vm.prank(clearingHouse);
        vault.withdraw(alice, withdrawAmount);

        assertEq(vault.getTotalDeposits(), depositAmount - withdrawAmount);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - depositAmount + withdrawAmount);
    }

    function test_WithdrawEvent() public {
        uint256 amount = 100e6;
        
        vm.prank(clearingHouse);
        vault.deposit(alice, amount);

        vm.expectEmit(true, false, false, true);
        emit Vault.Withdrawn(alice, amount);

        vm.prank(clearingHouse);
        vault.withdraw(alice, amount);
    }

    function test_RevertWhen_NonClearingHouseWithdraws() public {
        vm.prank(alice);
        vm.expectRevert(Vault.OnlyClearingHouse.selector);
        vault.withdraw(alice, 100e6);
    }

    function test_RevertWhen_InsufficientBalance() public {
        vm.prank(clearingHouse);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.withdraw(alice, 100e6);
    }

    // ============ Access Control Tests ============

    function test_RevertWhen_SetClearingHouseTwice() public {
        vm.expectRevert("Already set");
        vault.setClearingHouse(address(0x3));
    }

    function test_OnlyOwnerCanSetClearingHouse() public {
        Vault newVault = new Vault(address(usdc));
        
        vm.prank(alice);
        vm.expectRevert();
        newVault.setClearingHouse(clearingHouse);
    }

    // ============ View Function Tests ============

    function test_GetTotalDeposits() public {
        vm.prank(clearingHouse);
        vault.deposit(alice, 100e6);

        assertEq(vault.getTotalDeposits(), 100e6);
    }

    function test_GetBalance() public {
        vm.prank(clearingHouse);
        vault.deposit(alice, 100e6);

        assertEq(vault.getBalance(), 100e6);
    }

    // ============ Fuzz Tests ============

    function testFuzz_DepositWithdraw(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1e6, INITIAL_BALANCE);
        withdrawAmount = bound(withdrawAmount, 0, depositAmount);

        vm.prank(clearingHouse);
        vault.deposit(alice, depositAmount);

        vm.prank(clearingHouse);
        vault.withdraw(alice, withdrawAmount);

        assertEq(vault.getTotalDeposits(), depositAmount - withdrawAmount);
    }
}
