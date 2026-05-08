// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "./ITrap.sol";
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

    function collect() external view returns (bytes memory) {
        address registry = TrapDeployConfig.REGISTRY;
        if (registry.code.length == 0) return _status(TempleTypes.STATUS_TARGET_MISSING, registry, bytes32(0), address(0));

        try ITempleMigrationBackingRegistry(registry).active() returns (bool active) {
            bytes32 environmentId = ITempleMigrationBackingRegistry(registry).environmentId();
            address target = ITempleMigrationBackingRegistry(registry).monitoredTarget();
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

    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory) {
        if (data.length < REQUIRED_SAMPLES) return (false, bytes(""));

        TempleTypes.CollectOutput memory current = abi.decode(data[0], (TempleTypes.CollectOutput));
        if (!_validWindow(data)) return _incident(TempleTypes.SEVERITY_WARNING, TempleTypes.REASON_INVALID_SAMPLE_WINDOW, current);
        if (current.schemaVersion != SCHEMA_VERSION || current.invariantId != TempleTypes.INVARIANT_ID) {
            return _incident(TempleTypes.SEVERITY_WARNING, TempleTypes.REASON_INVALID_METRICS, current);
        }
        if (current.paused) return (false, bytes(""));

        TempleTypes.CollectOutput memory previous = abi.decode(data[1], (TempleTypes.CollectOutput));
        TempleTypes.CollectOutput memory oldest = abi.decode(data[data.length - 1], (TempleTypes.CollectOutput));

        bytes32 reasons;
        if (current.status == TempleTypes.STATUS_REGISTRY_INACTIVE) reasons |= TempleTypes.REASON_REGISTRY_INACTIVE;
        if (current.status == TempleTypes.STATUS_TARGET_MISSING) reasons |= TempleTypes.REASON_TARGET_MISSING;
        if (current.status == TempleTypes.STATUS_METRICS_CALL_FAILED) reasons |= TempleTypes.REASON_METRICS_FAILED;
        if (current.status == TempleTypes.STATUS_INVALID_METRICS) reasons |= TempleTypes.REASON_INVALID_METRICS;

        if (_underBacked(current.creditedStake, current.tokenBacking)) reasons |= TempleTypes.REASON_UNBACKED_STAKE;
        if (current.lastMigrationAmount >= MIN_MIGRATION_AMOUNT && !current.oldStakingTrusted) {
            reasons |= TempleTypes.REASON_UNTRUSTED_MIGRATOR;
        }
        if (previous.tokenBacking > current.tokenBacking && _dropBps(previous.tokenBacking, current.tokenBacking) > BACKING_TOLERANCE_BPS) {
            reasons |= TempleTypes.REASON_BACKING_DROP;
        }
        if (oldest.creditedStake > 0 && current.creditedStake > oldest.creditedStake) {
            uint256 increaseBps = ((current.creditedStake - oldest.creditedStake) * BPS) / oldest.creditedStake;
            if (increaseBps > CREDIT_SPIKE_BPS && _underBacked(current.creditedStake, current.tokenBacking)) {
                reasons |= TempleTypes.REASON_CREDIT_SPIKE;
            }
        }

        if (reasons == bytes32(0)) return (false, bytes(""));
        uint8 severity = (reasons & (TempleTypes.REASON_UNBACKED_STAKE | TempleTypes.REASON_UNTRUSTED_MIGRATOR)) != bytes32(0)
            ? TempleTypes.SEVERITY_CRITICAL
            : TempleTypes.SEVERITY_WARNING;
        return _incident(severity, reasons, current);
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

    function _underBacked(uint256 creditedStake, uint256 tokenBacking) internal pure returns (bool) {
        if (creditedStake == 0) return false;
        return tokenBacking * BPS < creditedStake * (BPS - BACKING_TOLERANCE_BPS);
    }

    function _dropBps(uint256 oldValue, uint256 newValue) internal pure returns (uint256) {
        if (oldValue == 0 || newValue >= oldValue) return 0;
        return ((oldValue - newValue) * BPS) / oldValue;
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
                    reasonBitmap: reasons,
                    extraData: abi.encode(severity, current.status)
                })
            )
        );
    }
}
