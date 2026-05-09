// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EventFilter, ITrap} from "./ITrap.sol";
import {ITempleMigrationBackingMetrics, ITempleMigrationBackingRegistry} from "./ITempleMigrationBacking.sol";
import {TempleTypes} from "./TempleTypes.sol";
import {TrapDeployConfig} from "./TrapDeployConfig.sol";

contract TempleMigrationBackingTrap is ITrap {
    uint8 public constant SCHEMA_VERSION = 1;
    uint256 public constant REQUIRED_SAMPLES = 3;
    uint256 public constant MAX_BLOCK_GAP = 32;
    uint256 public constant BPS = 10_000;
    uint256 public constant BACKING_TOLERANCE_BPS = 50;
    uint256 public constant CREDIT_SPIKE_BPS = 500;
    uint256 public constant MIN_MIGRATION_AMOUNT = 1e18;
    uint256 public constant COLLECT_OUTPUT_ENCODED_SIZE = 16 * 32;
    string internal constant MIGRATED_STAKE_EVENT_SIGNATURE = "MigratedStake(address,address,uint256,bool,uint256,uint256)";
    bytes32 internal constant RESPONSE_REASONS = TempleTypes.REASON_UNBACKED_STAKE
        | TempleTypes.REASON_UNTRUSTED_MIGRATOR
        | TempleTypes.REASON_MIGRATION_WITHOUT_BACKING_INFLOW;

    function collect() external view returns (bytes memory) {
        address registry = TrapDeployConfig.REGISTRY;
        if (registry.code.length == 0) return _status(TempleTypes.STATUS_TARGET_MISSING, registry, bytes32(0), address(0));

        try ITempleMigrationBackingRegistry(registry).getConfig() returns (
            bool active,
            bytes32 environmentId,
            address target,
            address
        ) {
            if (!active) return _status(TempleTypes.STATUS_REGISTRY_INACTIVE, registry, environmentId, target);
            if (target == address(0) || target.code.length == 0) {
                return _status(TempleTypes.STATUS_TARGET_MISSING, registry, environmentId, target);
            }

            try ITempleMigrationBackingMetrics(target).templeMigrationMetrics() returns (TempleTypes.Metrics memory m) {
                uint8 status = _validMetrics(m) ? TempleTypes.STATUS_OK : TempleTypes.STATUS_INVALID_METRICS;
                if (m.paused) status = TempleTypes.STATUS_ALREADY_PAUSED;
                return abi.encode(
                    TempleTypes.CollectOutput({
                        schemaVersion: SCHEMA_VERSION,
                        status: status,
                        invariantId: TempleTypes.INVARIANT_ID,
                        environmentId: environmentId,
                        registry: registry,
                        target: target,
                        observedBlockNumber: block.number,
                        creditedStake: m.creditedStake,
                        tokenBacking: m.tokenBacking,
                        lastMigrationAmount: m.lastMigrationAmount,
                        lastBackingBefore: m.lastBackingBefore,
                        lastBackingAfter: m.lastBackingAfter,
                        lastMigrationOldStaking: m.lastMigrationOldStaking,
                        lastMigrator: m.lastMigrator,
                        oldStakingTrusted: m.oldStakingTrusted,
                        paused: m.paused
                    })
                );
            } catch {
                return _status(TempleTypes.STATUS_METRICS_CALL_FAILED, registry, environmentId, target);
            }
        } catch {
            return _status(TempleTypes.STATUS_METRICS_CALL_FAILED, registry, bytes32(0), address(0));
        }
    }

    function eventLogFilters() external pure returns (EventFilter[] memory filters) {
        filters = new EventFilter[](1);
        filters[0] = EventFilter({
            contractAddress: TrapDeployConfig.MONITORED_TARGET,
            signature: MIGRATED_STAKE_EVENT_SIGNATURE
        });
    }

    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory) {
        if (data.length < REQUIRED_SAMPLES) return (false, bytes(""));
        if (!_validEncodedSamples(data)) return (false, bytes(""));

        TempleTypes.CollectOutput memory current = abi.decode(data[0], (TempleTypes.CollectOutput));
        if (!_validWindow(data)) return (false, bytes(""));
        if (current.schemaVersion != SCHEMA_VERSION || current.invariantId != TempleTypes.INVARIANT_ID) return (false, bytes(""));
        if (current.paused) return (false, bytes(""));

        TempleTypes.CollectOutput memory previous = abi.decode(data[1], (TempleTypes.CollectOutput));
        TempleTypes.CollectOutput memory oldest = abi.decode(data[data.length - 1], (TempleTypes.CollectOutput));

        bytes32 reasons = _criticalReasons(current, previous, oldest);
        if ((reasons & RESPONSE_REASONS) == bytes32(0)) return (false, bytes(""));
        return _incident(TempleTypes.SEVERITY_CRITICAL, reasons, current);
    }

    function shouldAlert(bytes[] calldata data) external pure returns (bool, bytes memory) {
        if (data.length < REQUIRED_SAMPLES) return (false, bytes(""));
        if (!_validEncodedSamples(data)) {
            return _syntheticAlert(TempleTypes.REASON_INVALID_METRICS, TempleTypes.STATUS_INVALID_METRICS);
        }

        TempleTypes.CollectOutput memory current = abi.decode(data[0], (TempleTypes.CollectOutput));
        bytes32 reasons;
        if (!_validWindow(data)) reasons |= TempleTypes.REASON_INVALID_SAMPLE_WINDOW;
        if (current.schemaVersion != SCHEMA_VERSION || current.invariantId != TempleTypes.INVARIANT_ID) {
            reasons |= TempleTypes.REASON_INVALID_METRICS;
        }
        if (current.status == TempleTypes.STATUS_REGISTRY_INACTIVE) reasons |= TempleTypes.REASON_REGISTRY_INACTIVE;
        if (current.status == TempleTypes.STATUS_TARGET_MISSING) reasons |= TempleTypes.REASON_TARGET_MISSING;
        if (current.status == TempleTypes.STATUS_METRICS_CALL_FAILED) reasons |= TempleTypes.REASON_METRICS_FAILED;
        if (current.status == TempleTypes.STATUS_INVALID_METRICS) reasons |= TempleTypes.REASON_INVALID_METRICS;
        if (current.status == TempleTypes.STATUS_ALREADY_PAUSED || current.paused) reasons |= TempleTypes.REASON_ALREADY_PAUSED;

        if (reasons == bytes32(0)) return (false, bytes(""));
        return _incident(TempleTypes.SEVERITY_WARNING, reasons, current);
    }

    function decodeAlertOutput(bytes calldata data) external pure returns (TempleTypes.Incident memory) {
        return abi.decode(data, (TempleTypes.Incident));
    }

    function _criticalReasons(
        TempleTypes.CollectOutput memory current,
        TempleTypes.CollectOutput memory previous,
        TempleTypes.CollectOutput memory oldest
    ) internal pure returns (bytes32 reasons) {
        bool underBacked = _underBacked(current.creditedStake, current.tokenBacking);
        bool untrustedMigration = current.lastMigrationAmount >= MIN_MIGRATION_AMOUNT && !current.oldStakingTrusted;
        bool migrationWithoutBacking = current.lastMigrationAmount >= MIN_MIGRATION_AMOUNT
            && _backingInflow(current) + _dustTolerance(current.lastMigrationAmount) < current.lastMigrationAmount;

        if (underBacked) reasons |= TempleTypes.REASON_UNBACKED_STAKE;
        if (untrustedMigration) reasons |= TempleTypes.REASON_UNTRUSTED_MIGRATOR;
        if (migrationWithoutBacking) reasons |= TempleTypes.REASON_MIGRATION_WITHOUT_BACKING_INFLOW;
        if (previous.tokenBacking > current.tokenBacking && _dropBps(previous.tokenBacking, current.tokenBacking) > BACKING_TOLERANCE_BPS) {
            reasons |= TempleTypes.REASON_BACKING_DROP;
        }
        if (oldest.creditedStake > 0 && current.creditedStake > oldest.creditedStake) {
            uint256 increaseBps = ((current.creditedStake - oldest.creditedStake) * BPS) / oldest.creditedStake;
            if (increaseBps > CREDIT_SPIKE_BPS && _underBacked(current.creditedStake, current.tokenBacking)) {
                reasons |= TempleTypes.REASON_CREDIT_SPIKE;
            }
        }
    }

    function _validWindow(bytes[] calldata data) internal pure returns (bool) {
        TempleTypes.CollectOutput memory previous = abi.decode(data[0], (TempleTypes.CollectOutput));
        for (uint256 i = 1; i < data.length; i++) {
            TempleTypes.CollectOutput memory sample = abi.decode(data[i], (TempleTypes.CollectOutput));
            if (sample.schemaVersion != SCHEMA_VERSION) return false;
            if (sample.environmentId != previous.environmentId || sample.target != previous.target) return false;
            if (previous.observedBlockNumber <= sample.observedBlockNumber) return false;
            if (previous.observedBlockNumber - sample.observedBlockNumber > MAX_BLOCK_GAP) return false;
            previous = sample;
        }
        return true;
    }

    function _validEncodedSamples(bytes[] calldata data) internal pure returns (bool) {
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i].length != COLLECT_OUTPUT_ENCODED_SIZE) return false;
        }
        return true;
    }

    function _underBacked(uint256 creditedStake, uint256 tokenBacking) internal pure returns (bool) {
        if (creditedStake == 0) return false;
        return tokenBacking * BPS < creditedStake * (BPS - BACKING_TOLERANCE_BPS);
    }

    function _dropBps(uint256 oldValue, uint256 newValue) internal pure returns (uint256) {
        if (oldValue == 0 || newValue >= oldValue) return 0;
        return ((oldValue - newValue) * BPS) / oldValue;
    }

    function _backingInflow(TempleTypes.CollectOutput memory current) internal pure returns (uint256) {
        if (current.lastBackingAfter <= current.lastBackingBefore) return 0;
        return current.lastBackingAfter - current.lastBackingBefore;
    }

    function _dustTolerance(uint256 amount) internal pure returns (uint256) {
        return (amount * BACKING_TOLERANCE_BPS) / BPS;
    }

    function _validMetrics(TempleTypes.Metrics memory m) internal pure returns (bool) {
        if (m.creditedStake == 0 && m.lastMigrationAmount > 0) return false;
        if (m.lastMigrationAmount > m.creditedStake && m.creditedStake > 0) return false;
        return true;
    }

    function _status(uint8 status, address registry, bytes32 environmentId, address target) internal view returns (bytes memory) {
        return abi.encode(
            TempleTypes.CollectOutput({
                schemaVersion: SCHEMA_VERSION,
                status: status,
                invariantId: TempleTypes.INVARIANT_ID,
                environmentId: environmentId,
                registry: registry,
                target: target,
                observedBlockNumber: block.number,
                creditedStake: 0,
                tokenBacking: 0,
                lastMigrationAmount: 0,
                lastBackingBefore: 0,
                lastBackingAfter: 0,
                lastMigrationOldStaking: address(0),
                lastMigrator: address(0),
                oldStakingTrusted: false,
                paused: false
            })
        );
    }

    function _incident(uint8 severity, bytes32 reasons, TempleTypes.CollectOutput memory current)
        internal
        pure
        returns (bool, bytes memory)
    {
        return (
            true,
            abi.encode(
                TempleTypes.Incident({
                    invariantId: TempleTypes.INVARIANT_ID,
                    environmentId: current.environmentId,
                    target: current.target,
                    blockNumber: current.observedBlockNumber,
                    creditedStake: current.creditedStake,
                    tokenBacking: current.tokenBacking,
                    lastMigrationOldStaking: current.lastMigrationOldStaking,
                    lastMigrator: current.lastMigrator,
                    lastMigrationAmount: current.lastMigrationAmount,
                    lastBackingBefore: current.lastBackingBefore,
                    lastBackingAfter: current.lastBackingAfter,
                    reasonBitmap: reasons,
                    extraData: abi.encode(severity, current.status)
                })
            )
        );
    }

    function _syntheticAlert(bytes32 reasons, uint8 status) internal pure returns (bool, bytes memory) {
        return (
            true,
            abi.encode(
                TempleTypes.Incident({
                    invariantId: TempleTypes.INVARIANT_ID,
                    environmentId: bytes32(0),
                    target: address(0),
                    blockNumber: 0,
                    creditedStake: 0,
                    tokenBacking: 0,
                    lastMigrationOldStaking: address(0),
                    lastMigrator: address(0),
                    lastMigrationAmount: 0,
                    lastBackingBefore: 0,
                    lastBackingAfter: 0,
                    reasonBitmap: reasons,
                    extraData: abi.encode(TempleTypes.SEVERITY_WARNING, status)
                })
            )
        );
    }
}
