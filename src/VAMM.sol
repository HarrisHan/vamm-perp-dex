// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IVAMM.sol";

/**
 * @title VAMM (Virtual Automated Market Maker)
 * @notice Price discovery engine using constant product formula (x * y = k).
 *         Never holds real tokens - purely virtual reserves.
 */
contract VAMM is IVAMM, Ownable {
    uint256 public vBaseReserve;
    uint256 public vQuoteReserve;
    uint256 public k;

    address public clearingHouse;

    // Precision for price calculations (18 decimals)
    uint256 public constant PRECISION = 1e18;

    event ReservesUpdated(uint256 baseReserve, uint256 quoteReserve);
    event ClearingHouseSet(address indexed clearingHouse);

    error OnlyClearingHouse();
    error InvalidReserves();
    error ZeroAmount();
    error InsufficientLiquidity();
    error ZeroAddress();

    modifier onlyClearingHouse() {
        if (msg.sender != clearingHouse) revert OnlyClearingHouse();
        _;
    }

    constructor(uint256 _initBaseReserve, uint256 _initQuoteReserve) Ownable(msg.sender) {
        if (_initBaseReserve == 0 || _initQuoteReserve == 0) revert InvalidReserves();
        vBaseReserve = _initBaseReserve;
        vQuoteReserve = _initQuoteReserve;
        k = _initBaseReserve * _initQuoteReserve;
    }

    function setClearingHouse(address _clearingHouse) external onlyOwner {
        if (_clearingHouse == address(0)) revert ZeroAddress();
        require(clearingHouse == address(0), "Already set");
        clearingHouse = _clearingHouse;
        emit ClearingHouseSet(_clearingHouse);
    }

    /**
     * @notice Swap quote asset for base asset (used for opening/closing positions).
     * @param isLong true = buy base (long), false = sell base (short)
     * @param quoteAmount Amount of quote asset to swap
     * @return baseAmount Amount of base asset received/sold
     */
    function swapInput(bool isLong, uint256 quoteAmount) external override onlyClearingHouse returns (uint256 baseAmount) {
        if (quoteAmount == 0) revert ZeroAmount();

        if (isLong) {
            // Buy base: quote increases, base decreases
            // newQuote = vQuoteReserve + quoteAmount
            // newBase = k / newQuote
            // baseAmount = vBaseReserve - newBase
            uint256 newQuoteReserve = vQuoteReserve + quoteAmount;
            uint256 newBaseReserve = k / newQuoteReserve;
            baseAmount = vBaseReserve - newBaseReserve;

            vQuoteReserve = newQuoteReserve;
            vBaseReserve = newBaseReserve;
        } else {
            // Sell base: quote decreases, base increases
            // First calculate how much base we need to sell to get quoteAmount
            // This is the reverse calculation for shorts
            if (quoteAmount >= vQuoteReserve) revert InsufficientLiquidity();
            uint256 newQuoteReserve = vQuoteReserve - quoteAmount;
            uint256 newBaseReserve = k / newQuoteReserve;
            baseAmount = newBaseReserve - vBaseReserve;

            vQuoteReserve = newQuoteReserve;
            vBaseReserve = newBaseReserve;
        }

        emit ReservesUpdated(vBaseReserve, vQuoteReserve);
    }

    /**
     * @notice Swap base asset for quote asset (used for closing positions).
     * @param isLong true = selling base (closing long), false = buying base (closing short)
     * @param baseAmount Amount of base asset to swap
     * @return quoteAmount Amount of quote asset received
     */
    function swapOutput(bool isLong, uint256 baseAmount) external override onlyClearingHouse returns (uint256 quoteAmount) {
        if (baseAmount == 0) revert ZeroAmount();

        if (isLong) {
            // Closing long: sell base back
            // newBase = vBaseReserve + baseAmount
            // newQuote = k / newBase
            // quoteAmount = vQuoteReserve - newQuote
            uint256 newBaseReserve = vBaseReserve + baseAmount;
            uint256 newQuoteReserve = k / newBaseReserve;
            quoteAmount = vQuoteReserve - newQuoteReserve;

            vBaseReserve = newBaseReserve;
            vQuoteReserve = newQuoteReserve;
        } else {
            // Closing short: buy base back
            // newBase = vBaseReserve - baseAmount
            // newQuote = k / newBase
            // quoteAmount = newQuote - vQuoteReserve
            if (baseAmount >= vBaseReserve) revert InsufficientLiquidity();
            uint256 newBaseReserve = vBaseReserve - baseAmount;
            uint256 newQuoteReserve = k / newBaseReserve;
            quoteAmount = newQuoteReserve - vQuoteReserve;

            vBaseReserve = newBaseReserve;
            vQuoteReserve = newQuoteReserve;
        }

        emit ReservesUpdated(vBaseReserve, vQuoteReserve);
    }

    /**
     * @notice Get the current spot price (vQuote / vBase).
     * @return price Price with PRECISION decimals
     */
    function getPrice() external view override returns (uint256) {
        return (vQuoteReserve * PRECISION) / vBaseReserve;
    }

    /**
     * @notice Get current reserves.
     */
    function getReserves() external view override returns (uint256, uint256) {
        return (vBaseReserve, vQuoteReserve);
    }

    /**
     * @notice Calculate output price for a given base amount (for closing positions).
     * @param isLong true = selling base (closing long), false = buying base (closing short)
     * @param baseAmount Amount of base asset
     * @return quoteAmount Expected quote amount
     */
    function getOutputPrice(bool isLong, uint256 baseAmount) external view override returns (uint256 quoteAmount) {
        if (baseAmount == 0) return 0;

        if (isLong) {
            uint256 newBaseReserve = vBaseReserve + baseAmount;
            uint256 newQuoteReserve = k / newBaseReserve;
            quoteAmount = vQuoteReserve - newQuoteReserve;
        } else {
            if (baseAmount >= vBaseReserve) return type(uint256).max; // Indicates insufficient liquidity
            uint256 newBaseReserve = vBaseReserve - baseAmount;
            uint256 newQuoteReserve = k / newBaseReserve;
            quoteAmount = newQuoteReserve - vQuoteReserve;
        }
    }

    /**
     * @notice Calculate input price for a given quote amount (for opening positions).
     * @param isLong true = buying base (long), false = selling base (short)
     * @param quoteAmount Amount of quote asset
     * @return baseAmount Expected base amount
     */
    function getInputPrice(bool isLong, uint256 quoteAmount) external view override returns (uint256 baseAmount) {
        if (quoteAmount == 0) return 0;

        if (isLong) {
            uint256 newQuoteReserve = vQuoteReserve + quoteAmount;
            uint256 newBaseReserve = k / newQuoteReserve;
            baseAmount = vBaseReserve - newBaseReserve;
        } else {
            uint256 newQuoteReserve = vQuoteReserve - quoteAmount;
            uint256 newBaseReserve = k / newQuoteReserve;
            baseAmount = newBaseReserve - vBaseReserve;
        }
    }

    /**
     * @notice Get vAMM reserves for external use.
     */
    function getVammReserves() external view returns (uint256, uint256) {
        return (vBaseReserve, vQuoteReserve);
    }
}
