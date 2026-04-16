# Locked Vault

A generic locked wrapper for Yearn V3 vaults, a shared accountant, and an
exit-only zapper.

## Overview

The locked vault accepts the underlying asset for a target Yearn vault,
compounds it through that vault, and enforces a cooldown period before
withdrawals. Users must:
1. Start a cooldown period (default: 14 days)
2. Wait for the cooldown to expire
3. Withdraw within the withdrawal window (default: 7 days)

`LockedVaultAccountant` is the shared Yearn accountant. It serves multiple
wrapped vaults, charges management/performance/locker fees, can refund losses
from idle capital or an optional reserve vault, and keeps non-locker fee shares
for itself. Each locker later pulls its reserved bonus shares into the locker to
realize the locker bonus.

The zapper only exits locked positions. It redeems locked shares on behalf of
the user and returns unlocked Yearn vault shares. The zapper is generic: you
pass the locked vault address into the zap function. If the wrapped vault is
short on liquid underlying, it borrows the exact shortfall from Morpho, tops up
liquidity, exits the locked vault, then repays the flash loan in the same
transaction.

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

This deploy script also deploys a `LockedVaultAccountant` and a generic
`LockerZapper`. The zapper hardcodes the Morpho singleton at
`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`, and you pass the locked vault
address into each zap call.

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

After deployment, governance still needs to point the wrapped vault's accountant
at the shared accountant and then configure:

1. Set cooldown duration (default: 14 days)
```solidity
lockedVault.setCooldownDuration(14 days);
```

2. Set withdrawal window (default: 7 days)
```solidity
lockedVault.setWithdrawalWindow(7 days);
```

3. Configure the shared accountant for the wrapped vault
```solidity
accountant.setVaultConfig(
    wrappedVault,
    address(lockedVault),
    100,  // 1% management fee
    1000, // 10% performance fee
    500,  // 5% locker bonus
    0     // no refunds
);
```

4. Optional: configure a reserve vault for refunds
```solidity
accountant.setReserveVault(address(wrappedVault), address(reserveVault));
accountant.deployIdleToReserve(address(wrappedVault), 1_000_000e6);
```

5. Locker bonus shares are realized into the locker during `lockedVault.report()`

6. Set health check limits on the locker strategy itself (optional)
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
