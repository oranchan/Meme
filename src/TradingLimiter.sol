//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TradingLimiter
/// @notice Enforces per-transaction size limits, per-wallet holding cap (soft), and per-address daily trade frequency.
/// @dev Designed to be queried & updated by the token contract before and after transfers.
contract TradingLimiter {
    /// @notice Maximum number of tokens allowed in a single transaction (absolute token units).
    uint256 public maxTradeAmount;
    /// @notice Maximum balance a wallet is allowed to hold (used as a soft cap validation point).
    uint256 public maxAccountBalance;
    /// @notice Tracks timestamp of the most recent trade counted inside the 24h window for each address.
    mapping(address => uint256) public lastTradeTime;
    /// @notice Tracks number of trades performed inside the current 24h window per address.
    mapping(address => uint256) public tradeCount;
    /// @notice Reference to the token contract for balance queries when enforcing wallet cap.
    IERC20 public memeToken;

    /// @param _totalSupply Total token supply used to derive relative limits.
    /// @param memeTokenAddr Address of the token implementing balanceOf for threshold checks.
    constructor(uint256 _totalSupply, address memeTokenAddr) {
        memeToken = IERC20(memeTokenAddr);
        maxTradeAmount = _totalSupply / 100; // 1% of total supply as max trade size
        maxAccountBalance = _totalSupply / 50; // 2% of total supply as max wallet allowed
    }

    /// @notice Check whether a prospective trade amount obeys the per-transaction cap.
    /// @param amount Gross intended transfer amount.
    /// @return True if amount <= maxTradeAmount.
    function isTradeAllowed(uint256 amount) public view returns (bool) {
        return amount <= maxTradeAmount;
    }

    /// @notice Validate whether a wallet currently holds below the configured balance ceiling.
    /// @param account Address whose balance is evaluated.
    /// @return True if current balance < maxAccountBalance (i.e., still below threshold).
    function isBalanceBelowThreshold(address account) public view returns (bool) {
        return memeToken.balanceOf(account) < maxAccountBalance;
    }

    /// @notice Determine if an address can execute another trade in the current 24h rolling window.
    /// @dev Resets implicitly when >24h (86400 seconds) has elapsed since last recorded trade.
    /// @param account The address being evaluated.
    /// @return True if either window expired or trade count < 20.
    function canTrade(address account) public view returns (bool) {
        if (block.timestamp - lastTradeTime[account] >= 86400) {
            return true; // window expired -> eligible & will reset upon record
        }
        return tradeCount[account] < 20;
    }

    /// @notice Record a trade occurrence for an account, updating rolling window state.
    /// @dev Resets count if >24h elapsed; always increments count afterward.
    /// @param account The address performing a trade.
    function recordTrade(address account) external {
        // Reset 24h window if needed (fresh period begins now)
        if (block.timestamp - lastTradeTime[account] >= 86400) {
            tradeCount[account] = 0;
            lastTradeTime[account] = block.timestamp;
        }
        tradeCount[account] += 1;
        lastTradeTime[account] = block.timestamp;
    } 
}
