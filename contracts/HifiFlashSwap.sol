// SPDX-License-Identifier: LGPL-3.0-or-later
pragma solidity >=0.8.0;

import "@paulrberg/contracts/access/Admin.sol";
import "@paulrberg/contracts/token/erc20/IErc20.sol";
import "@hifi/protocol/contracts/core/balanceSheet/IBalanceSheetV1.sol";
import "@hifi/protocol/contracts/core/hToken/IHToken.sol";

import "./HifiFlashSwapInterface.sol";
import "./interfaces/UniswapV2PairLike.sol";

/// @title HifiFlashSwap
/// @author Hifi
contract HifiFlashSwap is
    HifiFlashSwapInterface, // one dependency
    Admin // two dependencies
{
    constructor(address balanceSheet_, address pair_) Admin() {
        balanceSheet = IBalanceSheetV1(balanceSheet_);
        pair = UniswapV2PairLike(pair_);
        wbtc = IErc20(pair.token0());
        usdc = IErc20(pair.token1());
    }

    /// @dev Calculate the amount of WBTC that has to be repaid to Uniswap. The formula applied is:
    ///
    ///              (wbtcReserves * usdcAmount) * 1000
    /// repayment = ------------------------------------
    ///              (usdcReserves - usdcAmount) * 997
    ///
    /// See "getAmountIn" and "getAmountOut" in UniswapV2Library.sol. Flash swaps that are repaid via
    /// the corresponding pair token is akin to a normal swap, so the 0.3% LP fee applies.
    function getRepayWbtcAmount(uint256 usdcAmount) public view returns (uint256) {
        (uint112 wbtcReserves, uint112 usdcReserves, ) = pair.getReserves();

        // Note that we don't need CarefulMath because the UniswapV2Pair.sol contract performs sanity
        // checks on "wbtcAmount" and "usdcAmount" before calling the current contract.
        uint256 numerator = wbtcReserves * usdcAmount * 1000;
        uint256 denominator = (usdcReserves - usdcAmount) * 997;
        uint256 wbtcRepaymentAmount = numerator / denominator + 1;

        return wbtcRepaymentAmount;
    }

    /// @dev Called by the UniswapV2Pair contract.
    function uniswapV2Call(
        address sender,
        uint256 wbtcAmount,
        uint256 usdcAmount,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pair), "ERR_UNISWAP_V2_CALL_NOT_AUTHORIZED");
        require(wbtcAmount == 0, "ERR_WBTC_AMOUNT_ZERO");

        // Unpack the ABI encoded data passed by the UniswapV2Pair contract.
        (address hTokenAddress, address borrower, uint256 minProfit) = abi.decode(data, (address, address, uint256));
        IHToken hToken = IHToken(hTokenAddress);

        // Mint hUSDC and liquidate the borrower.
        uint256 mintedHUsdcAmount = mintHUsdc(hToken, usdcAmount);
        uint256 clutchedWbtcAmount = liquidateBorrow(hToken, borrower, mintedHUsdcAmount);

        // Calculate the amount of WBTC required.
        uint256 repayWbtcAmount = getRepayWbtcAmount(usdcAmount);
        require(clutchedWbtcAmount > repayWbtcAmount + minProfit, "ERR_INSUFFICIENT_PROFIT");

        // Pay back the loan.
        require(wbtc.transfer(address(pair), repayWbtcAmount), "ERR_WBTC_TRANSFER");

        // Reap the profit.
        uint256 profit = clutchedWbtcAmount - repayWbtcAmount;
        wbtc.transfer(sender, profit);

        emit FlashLiquidate(sender, borrower, hTokenAddress, usdcAmount, mintedHUsdcAmount, clutchedWbtcAmount, profit);
    }

    /// @dev Supply the USDC to the hToken and mint hUSDC.
    function mintHUsdc(IHToken hToken, uint256 usdcAmount) internal returns (uint256) {
        // Allow the hToken to spend USDC if allowance not enough.
        uint256 allowance = usdc.allowance(address(this), address(hToken));
        if (allowance < usdcAmount) {
            usdc.approve(address(hToken), type(uint256).max);
        }

        uint256 oldHTokenBalance = hToken.balanceOf(address(this));
        hToken.supplyUnderlying(usdcAmount);
        uint256 newHTokenBalance = hToken.balanceOf(address(this));
        uint256 mintedHUsdcAmount = newHTokenBalance - oldHTokenBalance;
        return mintedHUsdcAmount;
    }

    /// @dev Liquidate the borrower by transferring the USDC to the BalanceSheet. In doing this,
    /// the liquidator receives WBTC at a discount.
    function liquidateBorrow(
        IHToken hToken,
        address borrower,
        uint256 mintedHUsdcAmount
    ) internal returns (uint256) {
        uint256 oldWbtcBalance = wbtc.balanceOf(address(this));
        balanceSheet.liquidateBorrow(borrower, hToken, mintedHUsdcAmount, wbtc);
        uint256 newWbtcBalance = wbtc.balanceOf(address(this));
        uint256 clutchedWbtcAmount = newWbtcBalance - oldWbtcBalance;
        return clutchedWbtcAmount;
    }
}
