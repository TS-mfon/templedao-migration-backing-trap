// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

contract GoodOldStaking {
    MockERC20 public immutable LP_TOKEN;
    mapping(address => uint256) public migratedBalance;

    event Seeded(address indexed user, uint256 amount);
    event MigrateWithdraw(address indexed user, address indexed newStaking, uint256 amount);

    constructor(address lpToken_) {
        LP_TOKEN = MockERC20(lpToken_);
    }

    function seed(address user, uint256 amount) external {
        LP_TOKEN.transferFrom(msg.sender, address(this), amount);
        migratedBalance[user] += amount;
        emit Seeded(user, amount);
    }

    function migrateWithdraw(address user, uint256 amount) external {
        require(migratedBalance[user] >= amount, "insufficient old stake");
        migratedBalance[user] -= amount;
        LP_TOKEN.transfer(msg.sender, amount);
        emit MigrateWithdraw(user, msg.sender, amount);
    }
}
