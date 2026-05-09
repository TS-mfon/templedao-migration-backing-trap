# TempleDAO Migration Backing Trap

Drosera trap demo for the TempleDAO / STAX Finance migration exploit pattern from October 11, 2022.

## Incident Research

The TempleDAO incident was caused by a missing migration access-control check in the STAX `StaxLPStaking` contract. The exploited contract was `0xd2869042E12a3506100af1D192b5b04D65137941`, and the attacker address reported in public reproductions was `0x9c9Fb3100A2a521985F0c47DE3B4598dafD25B01`.

The relevant vulnerable flow was:

```solidity
function migrateStake(address oldStaking, uint256 amount) external {
    StaxLPStaking(oldStaking).migrateWithdraw(msg.sender, amount);
    _applyStake(msg.sender, amount);
}
```

The function trusted a caller-supplied `oldStaking` address. The attacker deployed a fake old staking contract with a `migrateWithdraw(address,uint256)` function that returned successfully but transferred no LP tokens. Then the attacker called `migrateStake(fakeOldStaking, stakingContractLpBalance)`, received fake staking credit, and completed the exploit with `withdrawAll(false)`.

Public reports agree on the core path:

- Fake migration contract returned from `migrateWithdraw` without backing transfer.
- `migrateStake` credited the attacker because the old staking address was not restricted by an `onlyMigrator` / whitelist check.
- About `321,154` xLP tokens were withdrawn from the xLP staking contract.
- The xLP was swapped into TEMPLE and FRAX, then value was moved through further swaps and transfers.
- Estimates put the loss around `1,830-1,831 ETH`, roughly `$2.3M-$2.4M` at the time.

Sources:

- Coinspect Learn EVM Attacks reproduction: https://www.coinspect.com/learn-evm-attacks/cases/templedao-spoof-old-staking-contract/
- Callisto investigation: https://docs.callisto.network/hack-investigation-dept./templedaos-stax-contract-hack-investigation
- Cointelegraph report: https://cointelegraph.com/news/templedao-exploit-results-in-2m-loss
- CryptoSlate / CertiK summary: https://cryptoslate.com/temple-dao-hacked-for-over-2-3m/

## Threat Model

This trap monitors staking migration accounting where `migrateStake` or equivalent logic can credit stake before the staking contract receives backing LP tokens.

It detects:

- `creditedStake` exceeding LP token backing held by the staking contract.
- A recent migration from an untrusted `oldStaking` address.
- Credit spikes that are not backed by a matching LP-token inflow.
- A migration whose credited amount is not matched by LP-token backing inflow.
- Explicit registry/target/metrics failures as alert-only operational issues.
- Bad Drosera sample ordering as an alert-only operational issue.

The on-chain response pauses the protected staking target through `emergencyPause()`. The mock proves that after the response lands, the attacker cannot complete the dangerous `withdrawAll(false)` path and the attacker LP balance remains zero.

## Honest Scope

The historical TempleDAO exploit was effectively completed inside the attacker transaction: fake migration credit and withdrawal happened together. A Drosera trap cannot interrupt a single atomic transaction that has already completed before the next block.

This demo is useful for:

- upgraded migration designs where migration credit and withdrawals are separable;
- protocols exposing an emergency pause path;
- detection of staged or repeated migration abuse;
- regression tests preventing the same missing-migrator class of bug.

It should not be described as a guaranteed retroactive stop for the original atomic transaction.

## Invariant

The core invariant is:

```text
creditedStake <= tokenBacking + tolerance
```

Where:

- `creditedStake` is the staking contract's aggregate accounting for user stake.
- `tokenBacking` is the LP token balance actually held by the staking contract.
- tolerance is `50 bps` to allow tiny accounting dust.

A second invariant is:

```text
lastMigrationAmount == 0 OR oldStakingTrusted == true
```

That maps directly to the TempleDAO root cause: an arbitrary fake `oldStaking` contract must not be able to mint stake credit.

A third side-effect invariant is:

```text
lastBackingAfter - lastBackingBefore >= lastMigrationAmount - tolerance
```

That ties a migration credit to the actual LP-token inflow observed around the migration. This is the direct mock-production check for the fake-old-staking primitive.

## Contracts

- `TempleMigrationBackingTrap`: constructorless Drosera trap using `TrapDeployConfig.REGISTRY` for metrics collection and `TrapDeployConfig.MONITORED_TARGET` for the static `MigratedStake(address,address,uint256,bool,uint256,uint256)` event filter.
- `TempleMigrationBackingRegistry`: stores environment ID, monitored target, response executor, and active flag.
- `TempleMigrationRiskResponse`: validates Drosera caller, invariant ID, environment ID, target, executor, cooldown, and pause result.
- `TempleTelegramAlertSink`: emits `TelegramAlertRequested` for webhook relays.
- `webhook/telegram-alert-webhook.js`: minimal HTTP webhook that forwards alerts to Telegram Bot API.

`shouldRespond()` only returns true for actionable exploit reasons:

- `REASON_UNBACKED_STAKE`
- `REASON_UNTRUSTED_MIGRATOR`
- `REASON_MIGRATION_WITHOUT_BACKING_INFLOW`

Operational reasons such as invalid sample ordering, inactive registry, missing target, failed metrics, invalid metrics, and already-paused target are surfaced through `shouldAlert()` and are rejected by the response contract if submitted to the pause path.

## Response Payload

`drosera.toml.example` uses:

```toml
response_function = "handleIncident((bytes32,bytes32,address,uint256,uint256,uint256,address,address,uint256,uint256,uint256,bytes32,bytes))"
```

The trap returns:

```solidity
TempleTypes.Incident({
    invariantId,
    environmentId,
    target,
    blockNumber,
    creditedStake,
    tokenBacking,
    lastMigrationOldStaking,
    lastMigrator,
    lastMigrationAmount,
    lastBackingBefore,
    lastBackingAfter,
    reasonBitmap,
    extraData
})
```

The response rejects non-actionable reason bitmaps, rejects targets with no code, reverts if pause fails, and verifies `templeMigrationMetrics().paused == true` before reporting containment.

## Telegram Webhook Setup

Create a Telegram bot:

1. Open Telegram and message `@BotFather`.
2. Run `/newbot`.
3. Choose a name and username.
4. Copy the bot token. It looks like `123456789:AA...`.
5. Create a private group or channel for alerts.
6. Add the bot to the group.
7. Send one message in the group.
8. Fetch your chat ID:

```bash
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates"
```

Find `chat.id` in the JSON response. Group chat IDs are often negative.

Run the webhook relay:

```bash
export TELEGRAM_BOT_TOKEN="botfather_token_here"
export TELEGRAM_CHAT_ID="telegram_chat_id_here"
export WEBHOOK_SECRET="choose-a-long-random-secret"
export PORT=8787
npm run telegram:webhook
```

You can also start from the checked-in template:

```bash
cp alerts.env.example .env
set -a
source .env
set +a
npm run telegram:webhook
```

Expose it with your preferred HTTPS service, for example Nginx, Cloudflare Tunnel, or a hosted Node service. The endpoint is:

```text
POST https://YOUR_HOST/drosera/templedao
Header: x-webhook-secret: your WEBHOOK_SECRET
```

Configure Drosera or your event-indexer webhook to POST decoded `TelegramAlertRequested` event fields or decoded `Incident` payloads to that endpoint. The relay accepts either shape and sends a Telegram message containing target, block, reason bitmap, credited stake, backing, migrator, old staking contract, migration amount, and backing before/after values when available.

Do not commit the bot token. Keep it in environment variables or your secret manager.

`alerts.config.example.json` documents the webhook shape expected by the relay. Replace:

- `source.contract` with the deployed `TempleTelegramAlertSink`.
- `webhook.url` with your public HTTPS webhook.
- `x-webhook-secret` with the same value as `WEBHOOK_SECRET`.

## Deployment Sequence

1. Deploy or identify a staking target that exposes `templeMigrationMetrics()` and `emergencyPause()`.
2. Deploy `TempleMigrationBackingRegistry` with a temporary response executor.
3. Deploy `TempleMigrationRiskResponse(droseraCaller, registry, telegramAlertSinkOrZero, cooldownBlocks)`.
4. Deploy `TempleTelegramAlertSink(response)` if using event-based Telegram alerts.
5. Update registry with `environmentId`, `monitoredTarget`, `responseExecutor`, `active=true`.
6. Set the staking target emergency module or response executor to the response contract.
7. Generate `src/TrapDeployConfig.sol` with the deployed registry address and monitored staking/adapter target.
8. Rebuild with `forge build`.
9. Update `drosera.toml`:
   - replace `response_contract = ""` with the deployed `TempleMigrationRiskResponse`;
   - replace `alerts.telegram.sink_contract = ""` with the deployed `TempleTelegramAlertSink`;
   - replace `alerts.telegram.webhook_url` with your public webhook URL.
10. Run `drosera dryrun`.
11. Run `drosera apply`.

`drosera.toml` contains all stable Ethereum mainnet and Drosera values, but the response and alert sink addresses are deployment-specific blanks. Do not run `drosera apply` until the response address is replaced with a deployed response contract. The trap reads `TrapDeployConfig.REGISTRY` and `TrapDeployConfig.MONITORED_TARGET`, so TOML alone does not configure the registry or event-filter target; rebuild after generating `TrapDeployConfig.sol` with deployed addresses.

## Build and Test

```bash
forge build
forge test -vvv
```

The test suite covers:

- healthy window does not trigger;
- insufficient samples do not trigger;
- unbacked fake migration triggers;
- event log filter targets the `MigratedStake(address,address,uint256,bool,uint256,uint256)` event;
- sample ordering is alert-only and does not pause;
- malformed schema and short malformed bytes do not revert;
- registry inactive, missing target, and metrics failure statuses;
- metrics failures are alert-only and do not pause;
- non-actionable incidents are rejected by the response;
- targets with no code are rejected by the response;
- wrong caller, invariant, environment, target, and response executor rejection;
- pause failure reverts;
- response pauses target;
- attacker `withdrawAll(false)` completion is blocked after response;
- full fake migration to LP withdrawal to TEMPLE/FRAX swap path without response;
- whitelist enforcement blocks fake migration;
- trusted old staking migration has matching LP backing inflow;
- already paused target does not retrigger;
- Telegram alert sink authorization.

## Trusted Adapter Assumptions

The trap trusts `templeMigrationMetrics()` on the monitored target or adapter. That function must read protocol accounting directly:

- aggregate credited stake;
- LP token backing held by the staking contract;
- last migration old staking address;
- last migrator;
- last migration amount;
- last backing before and after the migration;
- whether the old staking address is trusted;
- paused status.

If a protocol cannot expose these metrics safely, deploy a narrow audited adapter that reads them from storage or canonical getters. If the adapter fails, the trap encodes `STATUS_METRICS_CALL_FAILED`; it does not fabricate healthy values.
