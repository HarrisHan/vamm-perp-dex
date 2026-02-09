// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IVault.sol";

/**
 * @title Vault
 * @notice Holds all real collateral (USDC). Isolated from vAMM pricing logic.
 */
contract Vault is IVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable quoteAsset;
    address public clearingHouse;
    uint256 public totalDeposits;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event ClearingHouseSet(address indexed clearingHouse);

    error OnlyClearingHouse();
    error InsufficientBalance();
    error ZeroAddress();

    modifier onlyClearingHouse() {
        if (msg.sender != clearingHouse) revert OnlyClearingHouse();
        _;
    }

    constructor(address _quoteAsset) Ownable(msg.sender) {
        quoteAsset = IERC20(_quoteAsset);
    }

    /**
     * @notice Set the ClearingHouse address. Can only be called once by owner.
     */
    function setClearingHouse(address _clearingHouse) external onlyOwner {
        if (_clearingHouse == address(0)) revert ZeroAddress();
        require(clearingHouse == address(0), "Already set");
        clearingHouse = _clearingHouse;
        emit ClearingHouseSet(_clearingHouse);
    }

    /**
     * @notice Deposit collateral from user. Called by ClearingHouse.
     */
    function deposit(address from, uint256 amount) external override onlyClearingHouse nonReentrant {
        quoteAsset.safeTransferFrom(from, address(this), amount);
        totalDeposits += amount;
        emit Deposited(from, amount);
    }

    /**
     * @notice Withdraw collateral to user. Called by ClearingHouse.
     */
    function withdraw(address to, uint256 amount) external override onlyClearingHouse nonReentrant {
        if (quoteAsset.balanceOf(address(this)) < amount) revert InsufficientBalance();
        totalDeposits = totalDeposits > amount ? totalDeposits - amount : 0;
        quoteAsset.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    function getTotalDeposits() external view override returns (uint256) {
        return totalDeposits;
    }

    function getBalance() external view override returns (uint256) {
        return quoteAsset.balanceOf(address(this));
    }
}
