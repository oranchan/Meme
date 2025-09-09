// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./TradingLimiter.sol";
import "./TaxManager.sol";

/// @title MemeToken
/// @notice ERC20 token with dynamic per-context taxation (buy/sell/transfer) and trading limits.
/// @dev Extends OpenZeppelin ERC20, Ownable, and ReentrancyGuard. Uses helper contracts for limits & tax.
contract MemeToken is ERC20, Ownable, ReentrancyGuard {
    /// @notice Cached self address (may be used by external integrations).
    address public memeAddr = address(this);
    /// @notice Trading limiter enforcing max trade size, wallet limits, and daily trade frequency.
    TradingLimiter public tradingLimiter;
    /// @notice Mapping of AMM pair addresses (true if an address is considered a market pair).
    mapping(address => bool) public isAMMPair;
    /// @notice Tax manager to compute taxes and allocate collected amounts.
    TaxManager public taxManager;
    /// @notice Last tax amount deducted in the most recent _update call (for external observation/UI).
    uint256 public tax; // last tax amount
    /// @notice Addresses exempt from any tax & trading limit checks (e.g., owner, system addresses).
    mapping(address => bool) public taxExempt; // addresses exempt from tax

    /// @param initialSupply The base supply (without decimals expansion) to mint to deployer.
    constructor(uint256 initialSupply) ERC20("MemeToken", "MEME") Ownable(msg.sender) {
        uint256 supply = initialSupply * 10 ** decimals();

        // Initialize limiter & tax manager before mint so supply-based limits are consistent.
        tradingLimiter = new TradingLimiter(supply, address(this));
        taxManager = new TaxManager();

        // Mint entire supply to deployer/owner.
        _mint(msg.sender, supply);
    }

    /// @notice Emitted whenever new tokens are minted via owner-controlled mint function.
    event Mint(address indexed to, uint256 amount);

    /// @dev Modifier ensuring a provided token amount parameter is non-zero.
    modifier amountGreaterThanZero(uint256 amount) {
        require(amount > 0, "Amount must be greater than zero");
        _;
    }

    /// @notice Mint new tokens to a specified address (owner only).
    /// @dev No additional limit or tax logic is applied here; relies on owner trust.
    /// @param to Recipient address for new tokens.
    /// @param amount Token amount (raw, without decimals multiplication; caller passes exact units).
    function mint(address to, uint256 amount) public onlyOwner amountGreaterThanZero(amount) {
        _mint(to, amount);
        emit Mint(to, amount);
    }

    /// @notice Add or remove an AMM pair address used to classify transfers as buys or sells.
    /// @param pair Pair contract address.
    /// @param isPair True to mark as AMM pair, false to unmark.
    function setAMMPair(address pair, bool isPair) external onlyOwner {
        isAMMPair[pair] = isPair;
    }

    /// @notice Set tax exemption for an account (skips taxes & limit checks in _update).
    /// @param account The address to modify exemption for.
    /// @param exempt True to exempt, false to remove exemption.
    function setTaxExempt(address account, bool exempt) external onlyOwner {
        taxExempt[account] = exempt;
    }

    /// @notice Core token movement hook with integrated taxation & trading constraints.
    /// @dev Determines transfer context (buy/sell/transfer) using AMM pair flags and applies:
    ///  - Max trade size & wallet threshold checks
    ///  - Daily trade count limit via TradingLimiter
    ///  - Contextual tax (buy/sell/transfer) computed by TaxManager
    ///  - Post-transfer wallet limit validation
    /// Collected tax is transferred to TaxManager which internally tracks allocation buckets.
    /// @param from Sender address.
    /// @param to Recipient address.
    /// @param amount Gross amount the caller intends to move before tax deduction.
    function _update(address from, address to, uint256 amount) internal override {
        bool isBuy = isAMMPair[from];
        bool isSell = isAMMPair[to];
        bool isTransfer = !isBuy && !isSell;
        uint256 tradeAmount = amount; // will become net (amount - tax)

        // Mint (from == 0) or burn (to == 0) bypass custom restrictions.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        // Exempt addresses bypass tax & limits for operational flexibility.
        if (taxExempt[from] || taxExempt[to]) {
            super._update(from, to, amount);
            return;
        }

        // Pre-condition: enforce maximum trade size relative to configured limit.
        require(tradingLimiter.isTradeAllowed(amount), "Trade amount exceeds limit");

        if (isBuy) {
            // Enforce recipient wallet cap (pre-state) & daily trade quota.
            require(tradingLimiter.isBalanceBelowThreshold(to), "Pre: recipient beyond threshold");
            require(tradingLimiter.canTrade(to), "Recipient daily trade limit");
            tax = taxManager.calculateTaxInBuys(amount);
            tradeAmount = amount - tax; // Net amount to receiver after tax.
        } else if (isSell) {
            // Seller must have available daily trade slot.
            require(tradingLimiter.canTrade(from), "Seller daily trade limit");
            tax = taxManager.calculateTaxInSells(amount);
            tradeAmount = amount - tax;
        } else if (isTransfer) {
            // Both sender & recipient subject to frequency limit; recipient also to wallet cap.
            require(tradingLimiter.isBalanceBelowThreshold(to), "Pre: recipient beyond threshold");
            require(tradingLimiter.canTrade(from), "Sender daily trade limit");
            require(tradingLimiter.canTrade(to), "Recipient daily trade limit");
            tax = taxManager.calculateTaxInTransfers(amount);
            tradeAmount = amount - tax;
        }

        // Move net amount first (sender is debited by net).
        super._update(from, to, tradeAmount);
        // Deduct tax by transferring remainder to TaxManager (sender total debit equals gross amount).
        if (tax > 0) {
            super._update(from, address(taxManager), tax);
            taxManager.allocateTax(tax); // Accounting only; distribution strategy external.
        }

        // Post-condition: ensure wallet cap after net transfer (for buys & plain transfers).
        if (isBuy || isTransfer) {
            require(tradingLimiter.isBalanceBelowThreshold(to), "Post: recipient beyond threshold");
        }

        // Record trade counts for relevant parties.
        if (isBuy) {
            tradingLimiter.recordTrade(to);
        } else if (isSell) {
            tradingLimiter.recordTrade(from);
        } else if (isTransfer) {
            tradingLimiter.recordTrade(from);
            tradingLimiter.recordTrade(to);
        }
    }
}
