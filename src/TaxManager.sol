//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title TaxManager
/// @notice Centralized logic for computing and allocating tax portions for different transfer contexts.
/// @dev Keeps running tallies of allocated portions; actual distribution/burning is expected externally.
contract TaxManager {
    /// @notice Cumulative portion allocated to marketing activities (40% of collected tax per allocation).
    uint256 public marketingTax; // 40% of the tax goes to marketing
    /// @notice Cumulative portion reserved for adding liquidity (30% per allocation event).
    uint256 public liquidityTax; // 30% of the tax goes to liquidity
    /// @notice Cumulative portion dedicated to development funding (20% per allocation event).
    uint256 public developmentTax; // 20% of the tax goes to development
    /// @notice Cumulative portion marked for burning (10% per allocation event).
    uint256 public burnTax; // 10% of the tax goes to burn

    /// @notice Compute sell-side tax (typically highest due to selling pressure).
    /// @param amount Gross transfer amount.
    /// @return The tax owed (8% of amount).
    function calculateTaxInSells(uint256 amount) public pure returns (uint256) {
        return (amount * 8) / 100; // 8% tax
    }

    /// @notice Compute buy-side tax (medium-tier incentive).
    /// @param amount Gross transfer amount.
    /// @return The tax owed (5% of amount).
    function calculateTaxInBuys(uint256 amount) public pure returns (uint256) {
        return (amount * 5) / 100; // 5% tax
    }

    /// @notice Compute wallet-to-wallet transfer tax (lowest friction tier).
    /// @param amount Gross transfer amount.
    /// @return The tax owed (2% of amount).
    function calculateTaxInTransfers(uint256 amount) public pure returns (uint256) {
        return (amount * 2) / 100; // 2% tax
    }

    /// @notice Simple tax exemption logic placeholder (currently only zero address). 
    /// @dev In production this would likely be replaced with role or mapping checks.
    /// @param account Address to examine.
    /// @return True if tax-exempt.
    function isTaxExempt(address account) public pure returns (bool) {
        return account == address(0);
    }

    /// @notice Allocate a collected tax amount into internal accounting buckets.
    /// @dev Percentages must sum to 100; current split: 40/30/20/10. Does not move tokens, only tracks.
    /// @param taxAmount The amount of tax just collected.
    /// @return marketing Aggregated marketing allocation after update.
    /// @return liquidity Aggregated liquidity allocation after update.
    /// @return development Aggregated development allocation after update.
    /// @return burn Aggregated burn allocation after update.
    function allocateTax(uint256 taxAmount) public returns (uint256 marketing, uint256 liquidity, uint256 development, uint256 burn) {
        marketingTax += (taxAmount * 40) / 100; // 40% to marketing
        liquidityTax += (taxAmount * 30) / 100; // 30% to liquidity
        developmentTax += (taxAmount * 20) / 100; // 20% to development
        burnTax += (taxAmount * 10) / 100; // 10% to burn
        return (marketingTax, liquidityTax, developmentTax, burnTax);
    }
}