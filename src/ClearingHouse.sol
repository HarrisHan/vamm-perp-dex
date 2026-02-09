// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVAMM.sol";
import "./types/Position.sol";

/**
 * @title ClearingHouse
 * @notice Main entry point for users. Coordinates vAMM and Vault for position management.
 */
contract ClearingHouse is Ownable, ReentrancyGuard, Pausable {
    // ============ State Variables ============

    IVault public immutable vault;
    IVAMM public immutable vamm;
    IERC20 public immutable quoteAsset;

    // Protocol parameters
    uint256 public maxLeverage = 10;
    uint256 public minMargin = 10e6; // 10 USDC (assuming 6 decimals)
    uint256 public maintenanceMarginRatio = 625; // 6.25% = 625 basis points
    uint256 public liquidationRewardRatio = 500; // 5% = 500 basis points

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRECISION = 1e18;

    // User positions
    mapping(address => Position) public positions;

    // ============ Events ============

    event PositionOpened(
        address indexed trader,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 notional,
        int256 positionSize,
        uint256 entryPrice
    );

    event PositionClosed(
        address indexed trader,
        int256 realizedPnl,
        uint256 payout,
        uint256 exitPrice
    );

    event PositionLiquidated(
        address indexed trader,
        address indexed liquidator,
        int256 realizedPnl,
        uint256 liquidatorReward
    );

    event ParametersUpdated(
        uint256 maxLeverage,
        uint256 minMargin,
        uint256 maintenanceMarginRatio,
        uint256 liquidationRewardRatio
    );

    // ============ Errors ============

    error InvalidMargin();
    error InvalidLeverage();
    error PositionAlreadyExists();
    error NoPositionExists();
    error PositionNotLiquidatable();
    error InsufficientPayout();
    error ZeroAddress();
    error SlippageExceeded();

    // ============ Constructor ============

    constructor(address _vault, address _vamm, address _quoteAsset) Ownable(msg.sender) {
        if (_vault == address(0) || _vamm == address(0) || _quoteAsset == address(0)) {
            revert ZeroAddress();
        }
        vault = IVault(_vault);
        vamm = IVAMM(_vamm);
        quoteAsset = IERC20(_quoteAsset);
    }

    // ============ External Functions ============

    /**
     * @notice Open a new leveraged position.
     * @param _margin Collateral amount in quote asset
     * @param _leverage Leverage multiplier (1 to maxLeverage)
     * @param _isLong true = long, false = short
     * @param _minPositionSize Minimum acceptable position size (slippage protection, 0 to skip)
     */
    function openPosition(
        uint256 _margin,
        uint256 _leverage,
        bool _isLong,
        uint256 _minPositionSize
    ) external nonReentrant whenNotPaused {
        // Validations
        if (_margin < minMargin) revert InvalidMargin();
        if (_leverage < 1 || _leverage > maxLeverage) revert InvalidLeverage();
        if (positions[msg.sender].margin != 0) revert PositionAlreadyExists();

        // Transfer margin to vault
        vault.deposit(msg.sender, _margin);

        // Calculate notional value
        uint256 notional = _margin * _leverage;

        // Execute vAMM swap
        uint256 baseAmount = vamm.swapInput(_isLong, notional);

        // Slippage protection
        if (_minPositionSize > 0 && baseAmount < _minPositionSize) {
            revert SlippageExceeded();
        }

        // Calculate entry price
        uint256 entryPrice = (notional * PRECISION) / baseAmount;

        // Record position
        int256 positionSize = _isLong ? int256(baseAmount) : -int256(baseAmount);
        positions[msg.sender] = Position({
            margin: _margin,
            positionSize: positionSize,
            openNotional: notional,
            leverage: _leverage,
            entryPrice: entryPrice,
            openTimestamp: block.timestamp
        });

        emit PositionOpened(
            msg.sender,
            _isLong,
            _margin,
            _leverage,
            notional,
            positionSize,
            entryPrice
        );
    }

    /**
     * @notice Close the caller's entire position.
     */
    function closePosition() external nonReentrant whenNotPaused {
        Position memory pos = positions[msg.sender];
        if (pos.margin == 0) revert NoPositionExists();

        // Execute reverse trade in vAMM
        bool isLong = pos.positionSize > 0;
        uint256 baseAmount = isLong ? uint256(pos.positionSize) : uint256(-pos.positionSize);
        uint256 currentNotional = vamm.swapOutput(isLong, baseAmount);

        // Calculate PnL
        int256 pnl;
        if (isLong) {
            pnl = int256(currentNotional) - int256(pos.openNotional);
        } else {
            pnl = int256(pos.openNotional) - int256(currentNotional);
        }

        // Calculate payout (capped at 0 if underwater)
        uint256 payout;
        if (pnl >= 0) {
            payout = pos.margin + uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            payout = loss >= pos.margin ? 0 : pos.margin - loss;
        }

        // Calculate exit price
        uint256 exitPrice = (currentNotional * PRECISION) / baseAmount;

        // Clear position
        delete positions[msg.sender];

        // Transfer payout from vault
        if (payout > 0) {
            vault.withdraw(msg.sender, payout);
        }

        emit PositionClosed(msg.sender, pnl, payout, exitPrice);
    }

    /**
     * @notice Liquidate an undercollateralized position.
     * @param _user Address of the position holder to liquidate
     */
    function liquidatePosition(address _user) external nonReentrant whenNotPaused {
        Position memory pos = positions[_user];
        if (pos.margin == 0) revert NoPositionExists();

        // Check if position is liquidatable
        uint256 marginRatio = getMarginRatio(_user);
        if (marginRatio >= maintenanceMarginRatio) revert PositionNotLiquidatable();

        // Execute reverse trade in vAMM
        bool isLong = pos.positionSize > 0;
        uint256 baseAmount = isLong ? uint256(pos.positionSize) : uint256(-pos.positionSize);
        uint256 currentNotional = vamm.swapOutput(isLong, baseAmount);

        // Calculate PnL
        int256 pnl;
        if (isLong) {
            pnl = int256(currentNotional) - int256(pos.openNotional);
        } else {
            pnl = int256(pos.openNotional) - int256(currentNotional);
        }

        // Calculate remaining margin
        uint256 remainingMargin;
        if (pnl >= 0) {
            remainingMargin = pos.margin + uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            remainingMargin = loss >= pos.margin ? 0 : pos.margin - loss;
        }

        // Calculate liquidator reward
        uint256 liquidatorReward = (remainingMargin * liquidationRewardRatio) / BASIS_POINTS;

        // Clear position
        delete positions[_user];

        // Transfer reward to liquidator
        if (liquidatorReward > 0) {
            vault.withdraw(msg.sender, liquidatorReward);
        }

        emit PositionLiquidated(_user, msg.sender, pnl, liquidatorReward);
    }

    // ============ View Functions ============

    /**
     * @notice Get current vAMM spot price.
     */
    function getPrice() external view returns (uint256) {
        return vamm.getPrice();
    }

    /**
     * @notice Get a user's position.
     */
    function getPosition(address _user) external view returns (Position memory) {
        return positions[_user];
    }

    /**
     * @notice Calculate unrealized PnL for a position.
     */
    function getUnrealizedPnl(address _user) public view returns (int256) {
        Position memory pos = positions[_user];
        if (pos.margin == 0) return 0;

        bool isLong = pos.positionSize > 0;
        uint256 baseAmount = isLong ? uint256(pos.positionSize) : uint256(-pos.positionSize);
        uint256 currentNotional = vamm.getOutputPrice(isLong, baseAmount);

        if (isLong) {
            return int256(currentNotional) - int256(pos.openNotional);
        } else {
            return int256(pos.openNotional) - int256(currentNotional);
        }
    }

    /**
     * @notice Calculate margin ratio for a position (in basis points).
     */
    function getMarginRatio(address _user) public view returns (uint256) {
        Position memory pos = positions[_user];
        if (pos.margin == 0) return type(uint256).max;

        int256 pnl = getUnrealizedPnl(_user);
        int256 marginWithPnl = int256(pos.margin) + pnl;

        if (marginWithPnl <= 0) return 0;

        // Get current notional value
        bool isLong = pos.positionSize > 0;
        uint256 baseAmount = isLong ? uint256(pos.positionSize) : uint256(-pos.positionSize);
        uint256 currentNotional = vamm.getOutputPrice(isLong, baseAmount);

        if (currentNotional == 0) return type(uint256).max;

        return (uint256(marginWithPnl) * BASIS_POINTS) / currentNotional;
    }

    /**
     * @notice Check if a position is liquidatable.
     */
    function isLiquidatable(address _user) external view returns (bool) {
        if (positions[_user].margin == 0) return false;
        return getMarginRatio(_user) < maintenanceMarginRatio;
    }

    /**
     * @notice Get vAMM reserves.
     */
    function getVammReserves() external view returns (uint256, uint256) {
        return vamm.getReserves();
    }

    // ============ Admin Functions ============

    /**
     * @notice Update protocol parameters.
     */
    function setParameters(
        uint256 _maxLeverage,
        uint256 _minMargin,
        uint256 _maintenanceMarginRatio,
        uint256 _liquidationRewardRatio
    ) external onlyOwner {
        require(_maxLeverage >= 1, "Invalid max leverage");
        require(_maintenanceMarginRatio < BASIS_POINTS, "Invalid maintenance margin ratio");
        require(_liquidationRewardRatio <= 5000, "Reward ratio too high"); // Max 50%

        maxLeverage = _maxLeverage;
        minMargin = _minMargin;
        maintenanceMarginRatio = _maintenanceMarginRatio;
        liquidationRewardRatio = _liquidationRewardRatio;

        emit ParametersUpdated(_maxLeverage, _minMargin, _maintenanceMarginRatio, _liquidationRewardRatio);
    }

    /**
     * @notice Pause the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
