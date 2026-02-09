// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVault {
    function deposit(address from, uint256 amount) external;
    function withdraw(address to, uint256 amount) external;
    function getTotalDeposits() external view returns (uint256);
    function getBalance() external view returns (uint256);
}
