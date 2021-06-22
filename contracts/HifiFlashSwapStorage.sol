// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity >=0.8.0;

import "@paulrberg/contracts/token/erc20/IErc20.sol";
import "@hifi/protocol/contracts/core/balanceSheet/IBalanceSheetV1.sol";

import "./interfaces/UniswapV2PairLike.sol";

/// @title HifiFlashSwapStorage
/// @author Hifi
abstract contract HifiFlashSwapStorage {
    IBalanceSheetV1 public balanceSheet;
    mapping(address => UniswapV2PairLike) public pairs;
    IErc20 public usdc;
}
