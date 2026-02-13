<p align="center">
<img
src="./logo.png"
alt=""
style="display:block;margin:0 auto;width:500px;">
</p>

# Parametric Insurance MVP 

This repository contains a centralized, off-chain-assisted parametric insurance MVP.

Design intent:
- off-chain operator decides event facts (wind/hail inputs + event timestamp),
- on-chain contracts enforce product math, policy constraints, reserve constraints, and payout transfers.

## Contracts

### `src/MockUSDC.sol`
Test ERC20-like token (6 decimals) used for local testing.

### `src/ParametricPayoutEngine.sol`
Pure pricing/payout logic for a single product configuration:
- wind and hail tier bins (right-edge lookup),
- payout tables,
- scale factor (`wad`),
- corridor deductible,
- event cap.

Key behavior:
- constructor validates non-empty arrays and strict monotonic bins,
- `quoteEventPayoutBreakdown(...)` returns `(windTier, hailTier, raw, scaled, net)`.

### `src/PolicyPool.sol`
Main policy ledger + custody + settlement contract.

Key controls:
- owner role + operator role,
- two-step handover for owner/operator,
- pause/unpause circuit breaker.

Core behavior:
- `buyPolicy(...)` collects premium, stores policy, and enforces reserve sufficiency,
- `settlePolicy(...)` (operator-only) validates claim timing and policy state, applies annual cap + policy limit, and pays holder,
- legacy `payOut(...)` is intentionally disabled to prevent accounting bypass.

### `src/PolicyPoolV2.sol` (`PolicyV2`)
Legacy single-policy contract retained for reference/testing.  
Note: it expects pool `payOut(...)`; with current hardened `PolicyPool`, that path is disabled.

## Units and Math

- USDC amounts use 6 decimals (`USDC6`).
- scale uses `wad` precision (`1e18`).

Payout equation:
1. `windTier = lookup(windMph)`
2. `hailTier = lookup(hailTenthIn)`
3. `raw = windTier + hailTier`
4. `scaled = raw * scaleWad / 1e18`
5. `net = max(0, scaled - corridorDeductUSDC6)`
6. `net = min(net, eventCapUSDC6)` when cap is non-zero.

## Policy Lifecycle

1. Owner deploys `PolicyPool` and `ParametricPayoutEngine`.
2. Owner sets pool payout engine (`setPayoutEngine`).
3. Pool is funded with USDC.
4. User approves USDC and buys policy:
   - `endDate > startDate`
   - `startDate >= block.timestamp`
   - `premium > 0`, `limit > 0`
   - reserve check: post-buy pool balance must cover total active exposure.
5. After event, operator settles claim with observed metrics and `eventTimestamp`:
   - operator-only, contract not paused,
   - policy active and unpaid,
   - `eventTimestamp <= now`,
   - event timestamp inside policy window,
   - optional claim filing window,
   - annual cap check,
   - payout transfer to policy holder.

## Annual Cap Semantics

`paidThisYearUSDC6` rolls by a 365-day year bucket:
- `capYearIndex = block.timestamp / 365 days`
- on first settlement in a new bucket, `paidThisYearUSDC6` resets to `0`.

## Repo Layout

- `src/` Solidity contracts
- `test/` Foundry tests (unit + integration)
- `lib/forge-std` Foundry test library
- `foundry.toml` project config

## Development

### Prerequisites

- Foundry (`forge`, `cast`, `anvil`)

Install/update Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Coverage

```bash
forge coverage
```

### Format

```bash
forge fmt
```

## Deployment

Use the Forge script at `script/Deploy.s.sol`.

### 1) Configure env vars

Create local env file:

```bash
cp .env.example .env
```

Load env into shell:

```bash
set -a
source .env
set +a
```

### 2) Dry run

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url "$RPC_URL"
```

### 3) Broadcast

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url "$RPC_URL" --broadcast
```

### Script behavior

- If `USDC_ADDRESS` is unset/zero, script deploys `MockUSDC`.
- If `USDC_ADDRESS` is set, script uses existing token.
- Script deploys `ParametricPayoutEngine` and `PolicyPool`.
- Script sets payout engine and claim window on pool.
- If deploying `MockUSDC`, script can mint initial pool funds (`INITIAL_POOL_FUND_USDC6`).
- If `OWNER` or `OPERATOR` differ from deployer, script starts two-step transfer.
- If `OWNER_PRIVATE_KEY` / `OPERATOR_PRIVATE_KEY` are provided, script auto-calls acceptance.

### Deploy env vars

Required:
- `PRIVATE_KEY`
- `RPC_URL`

Optional:
- `USDC_ADDRESS`
- `ANNUAL_CAP_USDC6`
- `CLAIM_WINDOW_SEC`
- `INITIAL_POOL_FUND_USDC6`
- `SCALE_WAD`
- `CORRIDOR_DEDUCT_USDC6`
- `EVENT_CAP_USDC6`
- `OWNER`
- `OPERATOR`
- `OWNER_PRIVATE_KEY`
- `OPERATOR_PRIVATE_KEY`
