# Parametric Insurance MVP (Centralized Operator Model)

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

## Trust Model and Security Assumptions

This MVP is not oracle-decentralized.

Trusted parties:
- `owner`: can pause/unpause, rotate roles, set claim window, set annual cap, set payout engine.
- `operator`: can settle claims.

Operational assumptions:
- off-chain process supplies truthful event data,
- owner/operator keys are protected (prefer multisig in staging/prod),
- payout engine configuration is audited before activation.

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

## Deployment Notes

There is no deployment script in this repo yet; deploy with `forge create` or add a script in `script/`.

Typical order:
1. Deploy `MockUSDC` (or real USDC address for non-local env).
2. Deploy `PolicyPool(usdcAddress, annualCapUSDC6)`.
3. Deploy `ParametricPayoutEngine(...)` with bins/payouts.
4. Call `PolicyPool.setPayoutEngine(engine)`.
5. Optionally rotate operator with:
   - `transferOperator(newOperator)` by owner
   - `acceptOperatorRole()` by new operator.

## Known Limitations

- Centralized event adjudication (no signed oracle payload verification yet).
- No withdraw/treasury management function in pool.
- No policy cancellation or endorsements.
- `PolicyV2` is legacy and not compatible with hardened pool payout path.

## Next Recommended Upgrades

- EIP-712 signed claim payloads from trusted off-chain oracle/operator.
- Multisig owner/operator accounts.
- Explicit claim IDs and idempotency keys for off-chain reconciliation.
- Policy cancellation and pro-rata premium refund flow.
