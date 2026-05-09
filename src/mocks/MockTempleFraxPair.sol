// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

contract MockTempleFraxPair {
    MockERC20 public immutable LP_TOKEN;
    MockERC20 public immutable TEMPLE;
    MockERC20 public immutable FRAX;
    uint256 public templeReserve;
    uint256 public fraxReserve;
    uint256 public lpReserve;

    event LiquiditySeeded(uint256 lpAmount, uint256 templeAmount, uint256 fraxAmount);
    event LpSwappedForUnderlying(address indexed user, uint256 lpIn, uint256 templeOut, uint256 fraxOut);

    constructor(address lpToken_, address temple_, address frax_) {
        LP_TOKEN = MockERC20(lpToken_);
        TEMPLE = MockERC20(temple_);
        FRAX = MockERC20(frax_);
    }

    function seedLiquidity(uint256 lpAmount, uint256 templeAmount, uint256 fraxAmount) external {
        LP_TOKEN.transferFrom(msg.sender, address(this), lpAmount);
        TEMPLE.mint(address(this), templeAmount);
        FRAX.mint(address(this), fraxAmount);
        lpReserve += lpAmount;
        templeReserve += templeAmount;
        fraxReserve += fraxAmount;
        emit LiquiditySeeded(lpAmount, templeAmount, fraxAmount);
    }

    function swapLpForUnderlying(uint256 lpAmount) external returns (uint256 templeOut, uint256 fraxOut) {
        require(lpAmount > 0, "zero lp");
        require(lpReserve > 0, "empty pair");
        templeOut = (templeReserve * lpAmount) / lpReserve;
        fraxOut = (fraxReserve * lpAmount) / lpReserve;
        require(templeOut > 0 || fraxOut > 0, "dust output");
        LP_TOKEN.transferFrom(msg.sender, address(this), lpAmount);
        lpReserve += lpAmount;
        templeReserve -= templeOut;
        fraxReserve -= fraxOut;
        TEMPLE.transfer(msg.sender, templeOut);
        FRAX.transfer(msg.sender, fraxOut);
        emit LpSwappedForUnderlying(msg.sender, lpAmount, templeOut, fraxOut);
    }
}
