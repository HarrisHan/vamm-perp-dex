# vAMM Perpetual DEX

A simplified perpetual contract trading protocol based on the vAMM (Virtual Automated Market Maker) mechanism. This implementation allows users to open leveraged long/short positions on crypto assets without traditional order books or real counterparty liquidity.

## Overview

This protocol is inspired by [Perpetual Protocol V1](https://docs.perp.fi/), implementing core vAMM mechanics where:

- **vAMM** acts as a pricing engine using the constant product formula (x × y = k)
- **Vault** holds all real collateral (USDC) separately from the vAMM
- **ClearingHouse** coordinates user interactions, position management, and liquidations

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       ClearingHouse                         │
│  (Main Entry Point - openPosition/closePosition/liquidate) │
└──────────────────┬──────────────────────────────┬──────────┘
                   │                              │
                   ▼                              ▼
┌──────────────────────────┐    ┌─────────────────────────────┐
│         vAMM             │    │          Vault              │
│  (Price Discovery Only)  │    │  (Real Collateral Storage)  │
│  x × y = k formula       │    │  USDC deposits/withdrawals  │
│  No real tokens held     │    │  PnL settlements            │
└──────────────────────────┘    └─────────────────────────────┘
```

## Features

### V1 Scope
- ✅ Single trading pair (e.g., ETH/USDC)
- ✅ Open leveraged long/short positions
- ✅ Close positions with PnL settlement
- ✅ Liquidation mechanism for undercollateralized positions
- ✅ Configurable parameters (max leverage, min margin, maintenance margin)
- ✅ Pausable emergency mechanism
- ✅ ReentrancyGuard protection

### V1 Excluded (Future Versions)
- ❌ Funding rate mechanism
- ❌ Multiple trading pairs
- ❌ Partial close / add margin
- ❌ Limit orders / stop-loss
- ❌ Insurance fund
- ❌ Oracle integration

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd vamm-perp-dex

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test -v
```

## Testing

The project includes comprehensive tests covering:

- Unit tests for each contract
- Integration tests for full position lifecycle
- Fuzz tests for edge cases
- Access control tests

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/ClearingHouse.t.sol

# Run with gas report
forge test --gas-report
```

## Deployment

### Testnet (with Mock USDC)

```bash
# Set environment variables
export PRIVATE_KEY=<your-private-key>

# Deploy to testnet
forge script script/Deploy.s.sol:DeployTestnet \
  --rpc-url <RPC_URL> \
  --broadcast
```

### Mainnet

```bash
# Set environment variables
export PRIVATE_KEY=<your-private-key>
export QUOTE_ASSET=<usdc-address>
export INIT_BASE_RESERVE=100000000000000000000  # 100 ether
export INIT_QUOTE_RESERVE=100000000000           # 100000 USDC (6 decimals)

# Deploy
forge script script/Deploy.s.sol:Deploy \
  --rpc-url <RPC_URL> \
  --broadcast \
  --verify
```

## Usage

### Opening a Position

```solidity
// Approve ClearingHouse to spend USDC (via Vault)
IERC20(usdc).approve(vault, amount);

// Open a 5x long position with 100 USDC margin
clearingHouse.openPosition(
    100e6,    // margin: 100 USDC
    5,        // leverage: 5x
    true      // isLong: true for long, false for short
);
```

### Closing a Position

```solidity
// Close entire position, receive PnL
clearingHouse.closePosition();
```

### Liquidating a Position

```solidity
// Anyone can liquidate undercollateralized positions
if (clearingHouse.isLiquidatable(user)) {
    clearingHouse.liquidatePosition(user);
    // Liquidator receives 5% of remaining margin as reward
}
```

### View Functions

```solidity
// Get current price
uint256 price = clearingHouse.getPrice();

// Get position details
Position memory pos = clearingHouse.getPosition(user);

// Get unrealized PnL
int256 pnl = clearingHouse.getUnrealizedPnl(user);

// Get margin ratio (for liquidation check)
uint256 ratio = clearingHouse.getMarginRatio(user);

// Check if liquidatable
bool liquidatable = clearingHouse.isLiquidatable(user);
```

## Protocol Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxLeverage` | 10 | Maximum allowed leverage |
| `minMargin` | 10 USDC | Minimum margin to open position |
| `maintenanceMarginRatio` | 6.25% | Below this ratio, position is liquidatable |
| `liquidationRewardRatio` | 5% | Reward for liquidators |

## Security Considerations

### Known V1 Risks (Accepted)

1. **Protocol Insolvency Risk**: If position losses exceed margin, protocol absorbs the loss. No insurance fund in V1.

2. **No Funding Rate**: vAMM price may diverge from oracle/market price over time.

3. **Unilateral Exposure**: Protocol is counterparty to all trades. Net long/short imbalance creates directional risk.

4. **Price Manipulation**: Low virtual liquidity allows well-funded attackers to move prices significantly.

### Implemented Safeguards

- ReentrancyGuard on all external state-changing functions
- Pausable mechanism for emergencies
- Access control for admin functions
- Input validation on all user inputs
- SafeERC20 for token transfers

## License

MIT

## Acknowledgments

- [Perpetual Protocol](https://perp.fi/) for pioneering the vAMM concept
- [OpenZeppelin](https://openzeppelin.com/) for secure contract libraries
- [Foundry](https://book.getfoundry.sh/) for the development framework
