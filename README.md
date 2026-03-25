# Locked Vault

A generic locked wrapper for Yearn V3 vaults.

## Overview

The locked vault accepts the underlying asset for a target Yearn vault, compounds it through that vault, and enforces a cooldown period before withdrawals. Users must:
1. Start a cooldown period (default: 14 days)
2. Wait for the cooldown to expire
3. Withdraw within the withdrawal window (default: 7 days)

## Deployment

### 1. Setup Environment

Copy `.env.example` to `.env` and update with your values:

```bash
cp .env.example .env
```

Edit `.env`:
- `ETH_RPC_URL`: Your Ethereum RPC endpoint
- `WRAPPED_VAULT`: The Yearn vault address to wrap
- `GOVERNANCE`: Governance address for the fee splitter
- `LOCKED_TOKEN_NAME`: Name for the locked token
- `PRIVATE_KEY`: Your deployer private key

### 2. Deploy

Dry run (test deployment):
```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url $ETH_RPC_URL
```

Deploy to mainnet:
```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url $ETH_RPC_URL --broadcast --verify
```

## Testing

Run all tests:
```bash
make tests
```

These tests are forked. They need `ETH_RPC_URL`.

Run specific test:
```bash
make test-test test=test_name
```

## Configuration After Deployment

After deployment, management still needs to point the wrapped vault's accountant at the new locked vault and then configure:

1. Set cooldown duration (default: 14 days)
```solidity
lockedVault.setCooldownDuration(14 days);
```

2. Set withdrawal window (default: 7 days)
```solidity
lockedVault.setWithdrawalWindow(7 days);
```

3. Set fees (if desired)
```solidity
lockedVault.setFees(
    100,  // 1% management fee
    1000, // 10% performance fee
    500   // 5% locker bonus
);
```

4. Set health check limits (optional)
```solidity
lockedVault.setProfitLimitRatio(1000); // 10% profit limit
lockedVault.setLossLimitRatio(500);    // 5% loss limit
```

## Build & Development

### Build
```shell
forge build
```

### Format
```shell
forge fmt
```

### Gas Snapshots
```shell
forge snapshot
```
