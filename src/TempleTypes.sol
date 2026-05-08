// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library TempleTypes {
    bytes32 internal constant INVARIANT_ID = keccak256("TEMPLEDAO_MIGRATION_BACKING_V1");

    uint8 internal constant STATUS_OK = 0;
    uint8 internal constant STATUS_REGISTRY_INACTIVE = 1;
    uint8 internal constant STATUS_TARGET_MISSING = 2;
    uint8 internal constant STATUS_METRICS_CALL_FAILED = 3;
    uint8 internal constant STATUS_INVALID_METRICS = 4;
    uint8 internal constant STATUS_ALREADY_PAUSED = 5;

    uint8 internal constant SEVERITY_NONE = 0;
    uint8 internal constant SEVERITY_WARNING = 1;
    uint8 internal constant SEVERITY_HIGH = 2;
    uint8 internal constant SEVERITY_CRITICAL = 3;

    bytes32 internal constant REASON_UNBACKED_STAKE = bytes32(uint256(1 << 0));
    bytes32 internal constant REASON_UNTRUSTED_MIGRATOR = bytes32(uint256(1 << 1));
    bytes32 internal constant REASON_BACKING_DROP = bytes32(uint256(1 << 2));
    bytes32 internal constant REASON_CREDIT_SPIKE = bytes32(uint256(1 << 3));
    bytes32 internal constant REASON_REGISTRY_INACTIVE = bytes32(uint256(1 << 4));
    bytes32 internal constant REASON_TARGET_MISSING = bytes32(uint256(1 << 5));
    bytes32 internal constant REASON_METRICS_FAILED = bytes32(uint256(1 << 6));
    bytes32 internal constant REASON_INVALID_SAMPLE_WINDOW = bytes32(uint256(1 << 7));
    bytes32 internal constant REASON_INVALID_METRICS = bytes32(uint256(1 << 8));
    bytes32 internal constant REASON_ALREADY_PAUSED = bytes32(uint256(1 << 9));

    struct Metrics {
        uint256 creditedStake;
        uint256 tokenBacking;
        uint256 lastMigrationAmount;
        address lastMigrationOldStaking;
        address lastMigrator;
        bool oldStakingTrusted;
        bool paused;
    }

    struct CollectOutput {
        uint8 schemaVersion;
        uint8 status;
        bytes32 invariantId;
        bytes32 environmentId;
        address registry;
        address target;
        uint256 observedBlockNumber;
        uint256 creditedStake;
        uint256 tokenBacking;
        uint256 lastMigrationAmount;
        address lastMigrationOldStaking;
        address lastMigrator;
        bool oldStakingTrusted;
        bool paused;
    }

    struct Incident {
        bytes32 invariantId;
        bytes32 environmentId;
        address target;
        uint256 blockNumber;
        uint256 creditedStake;
        uint256 tokenBacking;
        address lastMigrationOldStaking;
        address lastMigrator;
        uint256 lastMigrationAmount;
        bytes32 reasonBitmap;
        bytes extraData;
    }
}
