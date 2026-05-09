// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TempleTypes} from "../TempleTypes.sol";
import {MockERC20} from "./MockERC20.sol";

interface IOldStakingLike {
    function migrateWithdraw(address user, uint256 amount) external;
}

contract TempleStaxMigrationMockV2 {
    MockERC20 public immutable LP_TOKEN;
    address public owner;
    address public responseExecutor;
    bool public paused;
    bool public enforceOldStakingWhitelist;
    uint256 public totalCreditedStake;
    mapping(address => uint256) public credited;
    mapping(address => bool) public trustedOldStaking;
    uint256 public lastMigrationAmount;
    uint256 public lastBackingBefore;
    uint256 public lastBackingAfter;
    address public lastMigrationOldStaking;
    address public lastMigrator;

    event MigratedStake(
        address indexed user,
        address indexed oldStaking,
        uint256 amount,
        bool oldStakingTrusted,
        uint256 backingBefore,
        uint256 backingAfter
    );
    event WithdrawAll(address indexed user, uint256 creditedAmount, uint256 paidAmount, uint256 unpaidAmount);
    event EmergencyPaused(address indexed caller);

    error OnlyOwner();
    error OnlyResponse();
    error Paused();
    error UntrustedOldStaking();
    error ZeroAddress();
    error NoStake();

    constructor(address lpToken_) {
        if (lpToken_ == address(0)) revert ZeroAddress();
        LP_TOKEN = MockERC20(lpToken_);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function setResponseExecutor(address executor) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        responseExecutor = executor;
    }

    function setTrustedOldStaking(address oldStaking, bool trusted) external onlyOwner {
        trustedOldStaking[oldStaking] = trusted;
    }

    function setWhitelistEnforcement(bool enforced) external onlyOwner {
        enforceOldStakingWhitelist = enforced;
    }

    function seedBackedStake(address user, uint256 amount) external onlyOwner {
        LP_TOKEN.transferFrom(msg.sender, address(this), amount);
        credited[user] += amount;
        totalCreditedStake += amount;
    }

    function migrateStake(address oldStaking, uint256 amount) external {
        if (paused) revert Paused();
        if (oldStaking == address(0)) revert ZeroAddress();
        bool trusted = trustedOldStaking[oldStaking];
        if (enforceOldStakingWhitelist && !trusted) revert UntrustedOldStaking();
        uint256 backingBefore = LP_TOKEN.balanceOf(address(this));
        IOldStakingLike(oldStaking).migrateWithdraw(msg.sender, amount);
        uint256 backingAfter = LP_TOKEN.balanceOf(address(this));
        credited[msg.sender] += amount;
        totalCreditedStake += amount;
        lastMigrationAmount = amount;
        lastBackingBefore = backingBefore;
        lastBackingAfter = backingAfter;
        lastMigrationOldStaking = oldStaking;
        lastMigrator = msg.sender;
        emit MigratedStake(msg.sender, oldStaking, amount, trusted, backingBefore, backingAfter);
    }

    function withdrawAll(bool) external {
        if (paused) revert Paused();
        uint256 userCredit = credited[msg.sender];
        if (userCredit == 0) revert NoStake();
        uint256 backing = LP_TOKEN.balanceOf(address(this));
        uint256 paid = userCredit <= backing ? userCredit : backing;
        uint256 unpaid = userCredit - paid;
        credited[msg.sender] = 0;
        totalCreditedStake -= userCredit;
        if (paid > 0) LP_TOKEN.transfer(msg.sender, paid);
        emit WithdrawAll(msg.sender, userCredit, paid, unpaid);
    }

    function emergencyPause() external {
        if (msg.sender != responseExecutor) revert OnlyResponse();
        if (!paused) {
            paused = true;
            emit EmergencyPaused(msg.sender);
        }
    }

    function templeMigrationMetrics() external view returns (TempleTypes.Metrics memory) {
        return TempleTypes.Metrics({
            creditedStake: totalCreditedStake,
            tokenBacking: LP_TOKEN.balanceOf(address(this)),
            lastMigrationAmount: lastMigrationAmount,
            lastBackingBefore: lastBackingBefore,
            lastBackingAfter: lastBackingAfter,
            lastMigrationOldStaking: lastMigrationOldStaking,
            lastMigrator: lastMigrator,
            oldStakingTrusted: trustedOldStaking[lastMigrationOldStaking],
            paused: paused
        });
    }
}
