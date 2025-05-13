// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title ElasticSupplyToken
 * @dev A rebase token implementation with elastic supply similar to Ampleforth
 * 
 * Key Features:
 * - Elastic supply that automatically adjusts based on price deviation from target
 * - Rebase mechanism that occurs at regular intervals
 * - Smooth supply adjustments to minimize volatility
 * - Transparent rebase calculations
 * - Governance capabilities for parameter adjustments
 */
contract ElasticSupplyToken is ERC20, Ownable {
    using SafeMath for uint256;

    // Rebase parameters
    uint256 private _targetPrice = 1 * 10**18; // Target price of 1.00 USD (in wei)
    uint256 private _rebaseInterval = 24 hours; // Daily rebase by default
    uint256 private _lastRebaseTime;
    uint256 private _maxRebasePercentage = 5 * 10**16; // Max 5% supply change per rebase (5e16 = 5%)
    uint256 private _priceDeltaThreshold = 5 * 10**15; // 0.5% price deviation required for rebase (5e15)

    // Oracle interface
    address public priceOracle;
    
    // Supply tracking
    uint256 private _totalSupplyAtLastRebase;
    uint256 private _maxSupply = type(uint256).max;
    
    // Rebase event
    event Rebase(
        uint256 indexed epoch,
        uint256 currentPrice,
        uint256 targetPrice,
        uint256 totalSupplyBefore,
        uint256 totalSupplyAfter,
        int256 supplyDelta,
        uint256 timestamp
    );
    
    // Parameter update events
    event OracleUpdated(address indexed newOracle);
    event RebaseIntervalUpdated(uint256 newInterval);
    event MaxRebasePercentageUpdated(uint256 newPercentage);
    event PriceDeltaThresholdUpdated(uint256 newThreshold);

    /**
     * @dev Constructor that initializes the token
     * @param initialSupply The initial token supply
     * @param initialOracle The address of the price oracle
     */
    constructor(
        uint256 initialSupply,
        address initialOracle
    ) ERC20("Elastic Supply Token", "EST") {
        require(initialSupply > 0, "Initial supply must be greater than 0");
        require(initialOracle != address(0), "Oracle address cannot be zero");
        
        _mint(msg.sender, initialSupply);
        _totalSupplyAtLastRebase = initialSupply;
        priceOracle = initialOracle;
        _lastRebaseTime = block.timestamp;
    }

    /**
     * @dev Returns the current target price
     */
    function targetPrice() public view returns (uint256) {
        return _targetPrice;
    }

    /**
     * @dev Returns the rebase interval
     */
    function rebaseInterval() public view returns (uint256) {
        return _rebaseInterval;
    }

    /**
     * @dev Returns the maximum rebase percentage (scaled by 1e18)
     */
    function maxRebasePercentage() public view returns (uint256) {
        return _maxRebasePercentage;
    }

    /**
     * @dev Returns the price delta threshold for rebase (scaled by 1e18)
     */
    function priceDeltaThreshold() public view returns (uint256) {
        return _priceDeltaThreshold;
    }

    /**
     * @dev Returns the timestamp of the last rebase
     */
    function lastRebaseTime() public view returns (uint256) {
        return _lastRebaseTime;
    }

    /**
     * @dev Returns the total supply at last rebase
     */
    function totalSupplyAtLastRebase() public view returns (uint256) {
        return _totalSupplyAtLastRebase;
    }

    /**
     * @dev Updates the price oracle address
     * @param newOracle The address of the new price oracle
     */
    function setPriceOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Oracle address cannot be zero");
        priceOracle = newOracle;
        emit OracleUpdated(newOracle);
    }

    /**
     * @dev Updates the rebase interval
     * @param newInterval The new rebase interval in seconds
     */
    function setRebaseInterval(uint256 newInterval) external onlyOwner {
        require(newInterval > 0, "Rebase interval must be greater than 0");
        _rebaseInterval = newInterval;
        emit RebaseIntervalUpdated(newInterval);
    }

    /**
     * @dev Updates the maximum rebase percentage
     * @param newPercentage The new maximum rebase percentage (scaled by 1e18)
     */
    function setMaxRebasePercentage(uint256 newPercentage) external onlyOwner {
        require(newPercentage <= 1 * 10**18, "Max rebase percentage cannot exceed 100%");
        _maxRebasePercentage = newPercentage;
        emit MaxRebasePercentageUpdated(newPercentage);
    }

    /**
     * @dev Updates the price delta threshold for rebase
     * @param newThreshold The new price delta threshold (scaled by 1e18)
     */
    function setPriceDeltaThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold <= 1 * 10**18, "Price delta threshold cannot exceed 100%");
        _priceDeltaThreshold = newThreshold;
        emit PriceDeltaThresholdUpdated(newThreshold);
    }

    /**
     * @dev Performs rebase if conditions are met
     * @return A boolean indicating whether a rebase was performed
     */
    function rebase() public returns (bool) {
        // Check if enough time has passed since last rebase
        if (block.timestamp < _lastRebaseTime + _rebaseInterval) {
            return false;
        }

        // Get current price from oracle (simplified - in practice would use Chainlink or similar)
        uint256 currentPrice = getCurrentPrice();
        
        // Calculate price deviation from target
        uint256 priceDeviation;
        bool isPositiveDeviation;
        
        if (currentPrice > _targetPrice) {
            priceDeviation = currentPrice.sub(_targetPrice);
            isPositiveDeviation = true;
        } else if (currentPrice < _targetPrice) {
            priceDeviation = _targetPrice.sub(currentPrice);
            isPositiveDeviation = false;
        } else {
            // Price exactly at target - no rebase needed
            _lastRebaseTime = block.timestamp;
            return false;
        }
        
        // Calculate percentage deviation
        uint256 deviationPercentage = priceDeviation.mul(1e18).div(_targetPrice);
        
        // Check if deviation exceeds threshold
        if (deviationPercentage < _priceDeltaThreshold) {
            _lastRebaseTime = block.timestamp;
            return false;
        }
        
        // Calculate supply delta (capped at max rebase percentage)
        uint256 absSupplyDeltaPercentage = deviationPercentage;
        if (absSupplyDeltaPercentage > _maxRebasePercentage) {
            absSupplyDeltaPercentage = _maxRebasePercentage;
        }
        
        // Apply smoothing factor (can be adjusted based on needs)
        absSupplyDeltaPercentage = absSupplyDeltaPercentage.div(2);
        
        // Calculate new supply
        uint256 newSupply;
        int256 supplyDelta;
        
        if (isPositiveDeviation) {
            // Price above target - increase supply
            uint256 supplyIncrease = _totalSupplyAtLastRebase.mul(absSupplyDeltaPercentage).div(1e18);
            newSupply = _totalSupplyAtLastRebase.add(supplyIncrease);
            supplyDelta = int256(supplyIncrease);
        } else {
            // Price below target - decrease supply
            uint256 supplyDecrease = _totalSupplyAtLastRebase.mul(absSupplyDeltaPercentage).div(1e18);
            if (supplyDecrease >= _totalSupplyAtLastRebase) {
                newSupply = 0;
                supplyDelta = -int256(_totalSupplyAtLastRebase);
            } else {
                newSupply = _totalSupplyAtLastRebase.sub(supplyDecrease);
                supplyDelta = -int256(supplyDecrease);
            }
        }
        
        // Cap at max supply if needed
        if (newSupply > _maxSupply) {
            newSupply = _maxSupply;
            supplyDelta = int256(_maxSupply.sub(_totalSupplyAtLastRebase));
        }
        
        // Store new supply and update last rebase time
        uint256 supplyBefore = _totalSupplyAtLastRebase;
        _totalSupplyAtLastRebase = newSupply;
        _lastRebaseTime = block.timestamp;
        
        // Emit rebase event
        emit Rebase(
            block.timestamp / _rebaseInterval,
            currentPrice,
            _targetPrice,
            supplyBefore,
            newSupply,
            supplyDelta,
            block.timestamp
        );
        
        return true;
    }

    /**
     * @dev Gets the current price from the oracle (simplified for this example)
     * In a real implementation, this would use Chainlink or similar oracle
     */
    function getCurrentPrice() public view returns (uint256) {
        // In a real implementation, this would call the priceOracle contract
        // For this example, we'll simulate a price query
        // This is where you would integrate with Chainlink or other oracle
        
        // Simplified: return a fixed price for demonstration
        // In practice, this would be replaced with actual oracle call
        return 1.05 * 10**18; // Simulating price of 1.05 USD
    }

    /**
     * @dev Overrides ERC20 totalSupply to return the rebased supply
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupplyAtLastRebase;
    }

    /**
     * @dev Overrides ERC20 balanceOf to return the rebased balance
     */
    function balanceOf(address account) public view override returns (uint256) {
        // In a real implementation, we would track individual balances pre-rebase
        // and adjust them proportionally during rebase
        // For simplicity in this example, we use the standard ERC20 balance tracking
        
        return super.balanceOf(account);
    }

    /**
     * @dev Function to manually trigger a rebase (for testing or emergency)
     */
    function manualRebase() external onlyOwner returns (bool) {
        return rebase();
    }

    /**
     * @dev Sets the maximum total supply
     * @param newMaxSupply The new maximum supply
     */
    function setMaxSupply(uint256 newMaxSupply) external onlyOwner {
        require(newMaxSupply >= _totalSupplyAtLastRebase, "Max supply cannot be less than current supply");
        _maxSupply = newMaxSupply;
    }
}
