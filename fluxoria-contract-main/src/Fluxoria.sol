// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ConditionalTokens.sol";
import "./OrderBook.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Fluxoria is Ownable, Pausable, ReentrancyGuard {
    // Custom errors
    error InvalidSide();
    error MarketDoesNotExist();
    error MarketNotActive();
    error CloseExistingPositionFirst();
    error InvalidLeverage();
    error SizeMustBePositive();
    error PositionSizeTooSmall();
    error CollateralTransferFailed();
    error NoOpenPosition();
    error MarketNotResolved();
    error NoTokensToRedeem();
    error InvalidPercentage();
    error PositionWouldBeLiquidated();
    error RemainingCollateralTransferFailed();
    error NotOrderOwner();
    error OrderNotActive();
    error NotEligibleForLiquidation();
    error PositionAlreadyLiquidated();
    error InvalidThreshold();
    error InvalidPenalty();
    error FeeTooHigh();
    error AmountMustBePositive();
    error InsufficientInsuranceFund();
    error InsuranceFundWithdrawalFailed();
    error InvalidPositionSize();
    error InvalidWarningThreshold();
    error PriceMustBePositive();
    error MarketNotReadyForResolution();
    error InsufficientTokenBalance();
    error InvalidWinningOutcome();
    error ArrayLengthMismatch();
    error InsufficientBalance();
    error FeeTransferFailed();
    
    enum PositionSide { None, Long, Short }
    enum MarketState { Active, Resolved, Cancelled }

    struct Position {
        PositionSide side;
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        uint256 leverage;
        uint256 marketId;
        uint256 outcome;
    }

    struct Market {
        string question;
        string description;
        uint256 resolutionTime;
        MarketState state;
        uint256 currentPrice;
        uint256 totalVolume;
        address conditionalTokensContract;
        bool isResolved;
    }

    mapping(address => Position) public userPositions;
    mapping(uint256 => Market) public markets;
    mapping(address => mapping(uint256 => uint256)) public userOutcomeBalances;

    uint256 public marketCount;
    IERC20 public collateralToken;
    ConditionalTokens public conditionalTokens;
    OrderBook public orderBook;
    
    // Liquidation parameters
    uint256 public liquidationThreshold = 80; // 80% of collateral
    uint256 public liquidationPenalty = 5; // 5% penalty for liquidation
    mapping(address => bool) public liquidatedUsers;
    
    // Insurance fund for covering liquidation losses
    uint256 public insuranceFund;
    uint256 public insuranceFundFee = 10; // 0.1% of each trade goes to insurance fund
    uint256 public constant INSURANCE_FEE_DENOMINATOR = 10000;
    
    // Position health warning threshold
    uint256 public warningThreshold = 90; // Warn user when health < 90%
    
    // Minimum position size to prevent dust
    uint256 public minPositionSize = 10 * 10**6; // 10 USDC (assuming 6 decimals)

    // Events
    event MarketCreated(
        uint256 indexed marketId,
        string question,
        uint256 resolutionTime,
        address conditionalTokensContract
    );
    
    event PositionOpened(
        address indexed user, 
        PositionSide side, 
        uint256 size, 
        uint256 collateral, 
        uint256 price, 
        uint256 leverage,
        uint256 marketId,
        uint256 outcome
    );
    
    event PositionClosed(
        address indexed user, 
        uint256 realizedPnl, 
        uint256 finalCollateral,
        uint256 marketId
    );
    
    event MarketResolved(
        uint256 indexed marketId,
        uint256 finalPrice,
        uint256 totalVolume
    );
    
    event TokensTraded(
        address indexed user,
        uint256 indexed marketId,
        uint256 outcome,
        uint256 amount,
        bool isBuy
    );
    
    event PositionLiquidated(
        address indexed user,
        uint256 indexed marketId,
        uint256 collateralLost,
        uint256 liquidationPenalty
    );
    
    event LiquidationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event LiquidationPenaltyUpdated(uint256 oldPenalty, uint256 newPenalty);
    
    event PartialPositionClosed(
        address indexed user,
        uint256 indexed marketId,
        uint256 closedAmount,
        uint256 realizedPnl,
        uint256 remainingSize
    );
    
    event InsuranceFundDeposit(uint256 amount, uint256 newTotal);
    event InsuranceFundWithdraw(uint256 amount, uint256 newTotal);
    event InsuranceFundFeeUpdated(uint256 oldFee, uint256 newFee);
    
    event PositionHealthWarning(
        address indexed user,
        uint256 indexed marketId,
        uint256 healthPercentage,
        uint256 currentPrice
    );
    
    event MinPositionSizeUpdated(uint256 oldSize, uint256 newSize);
    event WarningThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    
    event EmergencyPaused(address indexed by);
    event EmergencyUnpaused(address indexed by);

    constructor(
        string[] memory _name, 
        string[] memory _symbol, 
        uint256 _expiredTime,
        address _collateralToken
    ) Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
        
        // Deploy conditional tokens contract for this market
        conditionalTokens = new ConditionalTokens(_collateralToken);
        
        // Set mint fee to 0 to avoid double fee (Fluxoria already collects insurance fee)
        conditionalTokens.setMintFee(0);

        // Deploy order book contract
        orderBook = new OrderBook(address(conditionalTokens), _collateralToken);

        // Approve conditional tokens to spend our collateral
        collateralToken.approve(address(conditionalTokens), type(uint256).max);
        collateralToken.approve(address(orderBook), type(uint256).max);

        // Create the initial market in conditional tokens
        string[] memory outcomes = new string[](2);
        outcomes[0] = "Yes";
        outcomes[1] = "No";
        ConditionalTokens(address(conditionalTokens)).createMarket(
            _name[0], // question
            _symbol[0], // description
            _expiredTime,
            ConditionalTokens.OutcomeType.Binary,
            outcomes
        );

        // Create the initial market in Fluxoria
        _createMarket(
            _name[0], // question
            _symbol[0], // description
            _expiredTime
        );
    }

    /**
     * @dev Create a new prediction market
     */
    function _createMarket(
        string memory _question,
        string memory _description,
        uint256 _resolutionTime
    ) internal {
        uint256 marketId = marketCount++;
        
        markets[marketId] = Market({
            question: _question,
            description: _description,
            resolutionTime: _resolutionTime,
            state: MarketState.Active,
            currentPrice: 3000, // Default starting price
            totalVolume: 0,
            conditionalTokensContract: address(conditionalTokens),
            isResolved: false
        });
        
        emit MarketCreated(marketId, _question, _resolutionTime, address(conditionalTokens));
    }

    /**
     * @dev Open a leveraged position with conditional tokens
     */
    function openPosition(
        PositionSide _side, 
        uint256 _leverage, 
        uint256 _size,
        uint256 _marketId,
        uint256 _outcome
    ) external whenNotPaused nonReentrant {
        if (_side != PositionSide.Long && _side != PositionSide.Short) revert InvalidSide();
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        if (markets[_marketId].state != MarketState.Active) revert MarketNotActive();
        if (userPositions[msg.sender].side != PositionSide.None) revert CloseExistingPositionFirst();
        if (_leverage == 0 || _leverage > 10) revert InvalidLeverage();
        if (_size == 0) revert SizeMustBePositive();
        if (_size < minPositionSize) revert PositionSizeTooSmall();
        
        Market storage market = markets[_marketId];
        uint256 collateral = _size / _leverage;
        
        // Calculate insurance fund fee
        uint256 insuranceFee = (collateral * insuranceFundFee) / INSURANCE_FEE_DENOMINATOR;
        uint256 totalRequired = collateral + insuranceFee;
        
        // Transfer collateral + insurance fee from user
        if (!collateralToken.transferFrom(msg.sender, address(this), totalRequired)) {
            revert CollateralTransferFailed();
        }
        
        // Add insurance fee to fund
        insuranceFund += insuranceFee;
        emit InsuranceFundDeposit(insuranceFee, insuranceFund);
        
        // Mint conditional tokens for the chosen outcome
        conditionalTokens.mintTokens(_marketId, _outcome, collateral);
        
        // Update user balances
        userOutcomeBalances[msg.sender][_outcome] += collateral;
        
        // Create position
        userPositions[msg.sender] = Position({
            side: _side,
            size: _size,
            collateral: collateral,
            entryPrice: market.currentPrice,
            leverage: _leverage,
            marketId: _marketId,
            outcome: _outcome
        });
        
        // Update market volume
        market.totalVolume += _size;
        
        emit PositionOpened(
            msg.sender, 
            _side, 
            _size, 
            collateral, 
            market.currentPrice, 
            _leverage,
            _marketId,
            _outcome
        );
        
        emit TokensTraded(msg.sender, _marketId, _outcome, collateral, true);
    }

    /**
     * @dev Close a leveraged position
     */
    function closePosition() external whenNotPaused nonReentrant {
        Position storage pos = userPositions[msg.sender];
        if (pos.side == PositionSide.None) revert NoOpenPosition();
        
        Market storage market = markets[pos.marketId];
        if (market.state != MarketState.Active) revert MarketNotActive();
        
        (uint256 pnl, uint256 finalCollateral, bool wasLiquidated) = _calculatePositionValue(pos, market);
        
        // Burn conditional tokens
        conditionalTokens.burnTokens(pos.marketId, pos.outcome, pos.collateral);
        userOutcomeBalances[msg.sender][pos.outcome] -= pos.collateral;
        
        // Handle liquidation
        if (wasLiquidated) {
            liquidatedUsers[msg.sender] = true;
            uint256 penalty = (pos.collateral * liquidationPenalty) / 100;
            finalCollateral = finalCollateral > penalty ? finalCollateral - penalty : 0;
            
            emit PositionLiquidated(msg.sender, pos.marketId, pos.collateral - finalCollateral, penalty);
        }
        
        // Transfer final collateral to user
        if (finalCollateral > 0) {
            uint256 contractBalance = collateralToken.balanceOf(address(this));
            uint256 amountToTransfer = finalCollateral;
            
            // If we don't have enough collateral, cap at available balance
            if (contractBalance < finalCollateral) {
                amountToTransfer = contractBalance;
            }
            
            if (amountToTransfer > 0) {
                if (!collateralToken.transfer(msg.sender, amountToTransfer)) {
                    revert CollateralTransferFailed();
                }
            }
        }
        
        emit PositionClosed(msg.sender, pnl, finalCollateral, pos.marketId);
        emit TokensTraded(msg.sender, pos.marketId, pos.outcome, pos.collateral, false);
        
        delete userPositions[msg.sender];
    }
    
    /**
     * @dev Close a portion of the leveraged position
     * @param _percentage Percentage of position to close (1-100)
     */
    function closePartialPosition(uint256 _percentage) external whenNotPaused nonReentrant {
        if (_percentage == 0 || _percentage >= 100) revert InvalidPercentage();
        Position storage pos = userPositions[msg.sender];
        if (pos.side == PositionSide.None) revert NoOpenPosition();
        
        Market storage market = markets[pos.marketId];
        if (market.state != MarketState.Active) revert MarketNotActive();
        
        // Calculate partial amounts
        uint256 partialSize = (pos.size * _percentage) / 100;
        uint256 partialCollateral = (pos.collateral * _percentage) / 100;
        
        // Calculate PnL for the partial position
        Position memory tempPos = Position({
            side: pos.side,
            size: partialSize,
            collateral: partialCollateral,
            entryPrice: pos.entryPrice,
            leverage: pos.leverage,
            marketId: pos.marketId,
            outcome: pos.outcome
        });
        
        (uint256 pnl, uint256 finalCollateral, bool wasLiquidated) = _calculatePositionValue(tempPos, market);
        
        if (wasLiquidated) revert PositionWouldBeLiquidated();
        
        // Burn partial conditional tokens
        conditionalTokens.burnTokens(pos.marketId, pos.outcome, partialCollateral);
        userOutcomeBalances[msg.sender][pos.outcome] -= partialCollateral;
        
        // Transfer final collateral to user
        if (finalCollateral > 0) {
            uint256 contractBalance = collateralToken.balanceOf(address(this));
            uint256 amountToTransfer = finalCollateral;
            
            // If we don't have enough collateral, cap at available balance
            if (contractBalance < finalCollateral) {
                amountToTransfer = contractBalance;
            }
            
            if (amountToTransfer > 0) {
                if (!collateralToken.transfer(msg.sender, amountToTransfer)) {
                    revert CollateralTransferFailed();
                }
            }
        }
        
        // Update position
        pos.size -= partialSize;
        pos.collateral -= partialCollateral;
        
        // Check if remaining position is above minimum
        if (pos.size < minPositionSize) {
            // Close remaining position completely
            if (pos.collateral > 0) {
                conditionalTokens.burnTokens(pos.marketId, pos.outcome, pos.collateral);
                userOutcomeBalances[msg.sender][pos.outcome] -= pos.collateral;
                
                if (!collateralToken.transfer(msg.sender, pos.collateral)) {
                    revert RemainingCollateralTransferFailed();
                }
            }
            
            emit PositionClosed(msg.sender, pnl, finalCollateral + pos.collateral, pos.marketId);
            delete userPositions[msg.sender];
        } else {
            emit PartialPositionClosed(msg.sender, pos.marketId, partialSize, pnl, pos.size);
            emit TokensTraded(msg.sender, pos.marketId, pos.outcome, partialCollateral, false);
        }
    }
    
    /**
     * @dev Liquidate a position (can be called by anyone)
     */
    function liquidatePosition(address user) external whenNotPaused nonReentrant {
        Position storage pos = userPositions[user];
        if (pos.side == PositionSide.None) revert NoOpenPosition();
        if (liquidatedUsers[user]) revert PositionAlreadyLiquidated();
        
        Market storage market = markets[pos.marketId];
        if (market.state != MarketState.Active) revert MarketNotActive();
        
        // Check if position should be liquidated
        if (!_shouldLiquidate(pos, market)) revert NotEligibleForLiquidation();
        
        (uint256 pnl, uint256 finalCollateral, bool wasLiquidated) = _calculatePositionValue(pos, market);
        
        // Apply liquidation penalty
        uint256 penalty = (pos.collateral * liquidationPenalty) / 100;
        finalCollateral = finalCollateral > penalty ? finalCollateral - penalty : 0;
        
        // Burn conditional tokens
        conditionalTokens.burnTokens(pos.marketId, pos.outcome, pos.collateral);
        userOutcomeBalances[user][pos.outcome] -= pos.collateral;
        
        // Transfer final collateral to user
        if (finalCollateral > 0) {
            uint256 contractBalance = collateralToken.balanceOf(address(this));
            uint256 amountToTransfer = finalCollateral;
            
            // If we don't have enough collateral, cap at available balance
            if (contractBalance < finalCollateral) {
                amountToTransfer = contractBalance;
            }
            
            if (amountToTransfer > 0) {
                if (!collateralToken.transfer(user, amountToTransfer)) {
                    revert CollateralTransferFailed();
                }
            }
        }
        
        liquidatedUsers[user] = true;
        
        emit PositionLiquidated(user, pos.marketId, pos.collateral - finalCollateral, penalty);
        emit PositionClosed(user, pnl, finalCollateral, pos.marketId);
        
        delete userPositions[user];
    }
    
    /**
     * @dev Calculate position value and check for liquidation
     */
    function _calculatePositionValue(
        Position memory pos, 
        Market memory market
    ) internal pure returns (uint256 pnl, uint256 finalCollateral, bool wasLiquidated) {
        uint256 priceChange = 0;
        
        // Calculate PnL based on price movement
        if (pos.side == PositionSide.Long) {
            if (market.currentPrice > pos.entryPrice) {
                // Long position: price went up = profit
                priceChange = market.currentPrice - pos.entryPrice;
                pnl = (priceChange * pos.size * pos.leverage) / pos.entryPrice;
                finalCollateral = pos.collateral + pnl;
            } else {
                // Long position: price went down = loss
                priceChange = pos.entryPrice - market.currentPrice;
                pnl = (priceChange * pos.size * pos.leverage) / pos.entryPrice;
                if (pnl >= pos.collateral) {
                    finalCollateral = 0;
                    wasLiquidated = true;
                } else {
                    finalCollateral = pos.collateral - pnl;
                }
            }
        } else if (pos.side == PositionSide.Short) {
            if (market.currentPrice < pos.entryPrice) {
                // Short position: price went down = profit
                priceChange = pos.entryPrice - market.currentPrice;
                pnl = (priceChange * pos.size * pos.leverage) / pos.entryPrice;
                finalCollateral = pos.collateral + pnl;
            } else {
                // Short position: price went up = loss
                priceChange = market.currentPrice - pos.entryPrice;
                pnl = (priceChange * pos.size * pos.leverage) / pos.entryPrice;
                if (pnl >= pos.collateral) {
                    finalCollateral = 0;
                    wasLiquidated = true;
                } else {
                    finalCollateral = pos.collateral - pnl;
                }
            }
        }
    }
    
    /**
     * @dev Check if position should be liquidated
     */
    function _shouldLiquidate(Position memory pos, Market memory market) internal view returns (bool) {
        (uint256 pnl, uint256 finalCollateral, bool wasLiquidated) = _calculatePositionValue(pos, market);
        
        if (wasLiquidated) return true;
        
        // Check if collateral is below liquidation threshold
        uint256 threshold = (pos.collateral * liquidationThreshold) / 100;
        return finalCollateral < threshold;
    }
    
    /**
     * @dev Check if a position can be liquidated
     */
    function canLiquidate(address user) external view returns (bool) {
        Position memory pos = userPositions[user];
        if (pos.side == PositionSide.None) return false;
        if (liquidatedUsers[user]) return false;
        
        Market memory market = markets[pos.marketId];
        if (market.state != MarketState.Active) return false;
        
        return _shouldLiquidate(pos, market);
    }
    
    /**
     * @dev Get position health (percentage of collateral remaining)
     */
    function getPositionHealth(address user) external view returns (uint256) {
        Position memory pos = userPositions[user];
        if (pos.side == PositionSide.None) return 100;
        
        Market memory market = markets[pos.marketId];
        (, uint256 finalCollateral,) = _calculatePositionValue(pos, market);
        
        if (finalCollateral == 0) return 0;
        
        return (finalCollateral * 100) / pos.collateral;
    }

    /**
     * @dev Update market price (oracle integration)
     */
    function updatePrice(uint256 _marketId, uint256 newPrice) external onlyOwner {
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        if (markets[_marketId].state != MarketState.Active) revert MarketNotActive();
        if (newPrice == 0) revert PriceMustBePositive();
        
        markets[_marketId].currentPrice = newPrice;
    }

    /**
     * @dev Resolve a market
     */
    function resolveMarket(uint256 _marketId, uint256 finalPrice) external onlyOwner {
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        Market storage market = markets[_marketId];
        if (market.state != MarketState.Active) revert MarketNotActive();
        if (block.timestamp < market.resolutionTime) revert MarketNotReadyForResolution();
        
        market.state = MarketState.Resolved;
        market.currentPrice = finalPrice;
        market.isResolved = true;
        
        // Resolve the conditional tokens market
        conditionalTokens.resolveMarket(_marketId, 0); // Assuming outcome 0 is the winning outcome
        
        emit MarketResolved(_marketId, finalPrice, market.totalVolume);
    }

    /**
     * @dev Trade conditional tokens directly
     */
    function tradeTokens(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount,
        bool _isBuy
    ) external {
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        if (markets[_marketId].state != MarketState.Active) revert MarketNotActive();
        if (_amount == 0) revert AmountMustBePositive();
        
        if (_isBuy) {
            // Buy tokens
            if (!collateralToken.transferFrom(msg.sender, address(this), _amount)) {
                revert CollateralTransferFailed();
            }
            conditionalTokens.mintTokens(_marketId, _outcome, _amount);
            userOutcomeBalances[msg.sender][_outcome] += _amount;
        } else {
            // Sell tokens
            if (userOutcomeBalances[msg.sender][_outcome] < _amount) {
                revert InsufficientTokenBalance();
            }
            conditionalTokens.burnTokens(_marketId, _outcome, _amount);
            userOutcomeBalances[msg.sender][_outcome] -= _amount;
        }
        
        emit TokensTraded(msg.sender, _marketId, _outcome, _amount, _isBuy);
    }
    
    /**
     * @dev Redeem winning tokens for collateral after market resolution
     * @param _marketId The market ID
     * @param _outcome The outcome to redeem
     */
    function redeemTokens(uint256 _marketId, uint256 _outcome) external {
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        if (markets[_marketId].state != MarketState.Resolved) revert MarketNotResolved();
        
        uint256 amount = userOutcomeBalances[msg.sender][_outcome];
        if (amount == 0) revert NoTokensToRedeem();
        
        // Clear user's balance
        userOutcomeBalances[msg.sender][_outcome] = 0;
        
        // Redeem from ConditionalTokens
        // Note: This will only work if the outcome matches the winning outcome
        // The ConditionalTokens contract will revert if it's not the winning outcome
        conditionalTokens.redeemTokens(_marketId, _outcome);
        
        // Transfer collateral to user
        // The collateral is now in Fluxoria's balance after redeeming from ConditionalTokens
        if (!collateralToken.transfer(msg.sender, amount)) {
            revert CollateralTransferFailed();
        }
    }

    /**
     * @dev Get market information
     */
    function getMarket(uint256 _marketId) external view returns (Market memory) {
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        return markets[_marketId];
    }

    /**
     * @dev Get user's outcome balance
     */
    function getOutcomeBalance(address _user, uint256 _outcome) external view returns (uint256) {
        return userOutcomeBalances[_user][_outcome];
    }
    
    /**
     * @dev Update liquidation threshold (only owner)
     */
    function setLiquidationThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold == 0 || _newThreshold > 100) revert InvalidThreshold();
        uint256 oldThreshold = liquidationThreshold;
        liquidationThreshold = _newThreshold;
        emit LiquidationThresholdUpdated(oldThreshold, _newThreshold);
    }
    
    /**
     * @dev Update liquidation penalty (only owner)
     */
    function setLiquidationPenalty(uint256 _newPenalty) external onlyOwner {
        if (_newPenalty > 20) revert InvalidPenalty(); // Max 20%
        uint256 oldPenalty = liquidationPenalty;
        liquidationPenalty = _newPenalty;
        emit LiquidationPenaltyUpdated(oldPenalty, _newPenalty);
    }
    
    /**
     * @dev Update insurance fund fee (only owner)
     */
    function setInsuranceFundFee(uint256 _newFee) external onlyOwner {
        if (_newFee > 100) revert FeeTooHigh(); // Max 1%
        uint256 oldFee = insuranceFundFee;
        insuranceFundFee = _newFee;
        emit InsuranceFundFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @dev Withdraw from insurance fund (only owner)
     */
    function withdrawInsuranceFund(uint256 _amount) external onlyOwner {
        if (_amount == 0) revert AmountMustBePositive();
        if (_amount > insuranceFund) revert InsufficientInsuranceFund();
        
        insuranceFund -= _amount;
        if (!collateralToken.transfer(owner(), _amount)) {
            revert InsuranceFundWithdrawalFailed();
        }
        
        emit InsuranceFundWithdraw(_amount, insuranceFund);
    }
    
    /**
     * @dev Update minimum position size (only owner)
     */
    function setMinPositionSize(uint256 _newSize) external onlyOwner {
        if (_newSize == 0) revert InvalidPositionSize();
        uint256 oldSize = minPositionSize;
        minPositionSize = _newSize;
        emit MinPositionSizeUpdated(oldSize, _newSize);
    }
    
    /**
     * @dev Update warning threshold (only owner)
     */
    function setWarningThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold <= liquidationThreshold || _newThreshold > 100) revert InvalidWarningThreshold();
        uint256 oldThreshold = warningThreshold;
        warningThreshold = _newThreshold;
        emit WarningThresholdUpdated(oldThreshold, _newThreshold);
    }
    
    /**
     * @dev Check position health and emit warning if needed
     */
    function checkPositionHealth(address _user) external {
        Position memory pos = userPositions[_user];
        if (pos.side == PositionSide.None) return;
        
        Market memory market = markets[pos.marketId];
        if (market.state != MarketState.Active) return;
        
        (, uint256 finalCollateral,) = _calculatePositionValue(pos, market);
        
        uint256 healthPercentage = finalCollateral == 0 ? 0 : (finalCollateral * 100) / pos.collateral;
        
        if (healthPercentage < warningThreshold) {
            emit PositionHealthWarning(_user, pos.marketId, healthPercentage, market.currentPrice);
        }
    }
    
    /**
     * @dev Pause all market operations (only owner)
     */
    function pause() external onlyOwner {
        _pause();
        emit EmergencyPaused(msg.sender);
    }
    
    /**
     * @dev Unpause all market operations (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(msg.sender);
    }
    
    // ========== ORDER BOOK INTEGRATION ==========
    
    /**
     * @dev Create a buy order for conditional tokens
     * Note: Users should call orderBook.createBuyOrder() directly.
     * This function is kept for backward compatibility but will be deprecated.
     */
    function createBuyOrder(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount,
        uint256 _maxPrice
    ) external returns (uint256 orderId) {
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        if (markets[_marketId].state != MarketState.Active) revert MarketNotActive();
        
        // Transfer collateral from user to this contract
        uint256 totalCost = (_amount * _maxPrice) / 10**6; // Price denominator
        if (!collateralToken.transferFrom(msg.sender, address(this), totalCost)) {
            revert CollateralTransferFailed();
        }
        
        // Approve OrderBook to spend the collateral
        collateralToken.approve(address(orderBook), totalCost);
        
        // Create order (will be owned by this contract, not the user)
        return orderBook.createBuyOrder(_marketId, _outcome, _amount, _maxPrice);
    }
    
    /**
     * @dev Create a sell order for conditional tokens
     * Note: Users should call orderBook.createSellOrder() directly.
     * This function is kept for backward compatibility but will be deprecated.
     */
    function createSellOrder(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount,
        uint256 _minPrice
    ) external returns (uint256 orderId) {
        if (_marketId >= marketCount) revert MarketDoesNotExist();
        if (markets[_marketId].state != MarketState.Active) revert MarketNotActive();
        
        // Check user has enough tokens in their tracked balance
        if (userOutcomeBalances[msg.sender][_outcome] < _amount) {
            revert InsufficientBalance();
        }
        
        // Decrease user's tracked balance
        userOutcomeBalances[msg.sender][_outcome] -= _amount;
        
        // Approve OrderBook to spend Fluxoria's tokens
        conditionalTokens.approveOutcomeTokens(_marketId, address(orderBook), _outcome, _amount);
        
        // Create order (will be owned by this contract, not the user)
        // The tokens are already owned by this contract from tradeTokens()
        return orderBook.createSellOrder(_marketId, _outcome, _amount, _minPrice);
    }
    
    /**
     * @dev Cancel an order
     * Note: Users should call orderBook.cancelOrder() directly.
     * This function is kept for backward compatibility but will be deprecated.
     */
    function cancelOrder(uint256 _orderId) external {
        orderBook.cancelOrder(_orderId);
    }
    
    /**
     * @dev Get market depth (best buy/sell prices)
     */
    function getMarketDepth(uint256 _marketId, uint256 _outcome) external view returns (uint256 bestBuyPrice, uint256 bestSellPrice) {
        return orderBook.getMarketDepth(_marketId, _outcome);
    }
    
    /**
     * @dev Get all orders for a market
     */
    function getMarketOrders(uint256 _marketId) external view returns (uint256[] memory buyOrders, uint256[] memory sellOrders) {
        return orderBook.getMarketOrders(_marketId);
    }
    
    /**
     * @dev Get user's orders
     */
    function getUserOrders(address _user) external view returns (uint256[] memory) {
        return orderBook.getUserOrders(_user);
    }
    
    /**
     * @dev Withdraw fees from OrderBook (only owner)
     * Fees are withdrawn to this contract and then transferred to the owner
     */
    function withdrawOrderBookFees() external onlyOwner {
        uint256 balanceBefore = collateralToken.balanceOf(address(this));
        orderBook.withdrawFees();
        uint256 balanceAfter = collateralToken.balanceOf(address(this));
        uint256 fees = balanceAfter - balanceBefore;
        
        if (fees > 0) {
            if (!collateralToken.transfer(owner(), fees)) {
                revert FeeTransferFailed();
            }
        }
    }
    
    /**
     * @dev Get order details
     */
    function getOrder(uint256 _orderId) external view returns (OrderBook.Order memory) {
        return orderBook.getOrder(_orderId);
    }
    
    /**
     * @dev Get user position
     */
    function getUserPosition(address user) external view returns (Position memory) {
        return userPositions[user];
    }

    /**
     * @dev Get order book address
     */
    function getOrderBookAddress() external view returns (address) {
        return address(orderBook);
    }
    
    /**
     * @dev Get insurance fund balance
     */
    function getInsuranceFund() external view returns (uint256) {
        return insuranceFund;
    }
    
    /**
     * @dev Get all market parameters
     */
    function getMarketParameters() external view returns (
        uint256 _liquidationThreshold,
        uint256 _liquidationPenalty,
        uint256 _insuranceFundFee,
        uint256 _warningThreshold,
        uint256 _minPositionSize
    ) {
        return (
            liquidationThreshold,
            liquidationPenalty,
            insuranceFundFee,
            warningThreshold,
            minPositionSize
        );
    }
    
    // ========== ORACLE INTEGRATION ==========
    
    /**
     * @dev Batch update prices from oracle
     * @param _marketIds Array of market IDs
     * @param _prices Array of new prices
     */
    function batchUpdatePrices(
        uint256[] calldata _marketIds,
        uint256[] calldata _prices
    ) external onlyOwner {
        if (_marketIds.length != _prices.length) revert ArrayLengthMismatch();
        
        for (uint256 i = 0; i < _marketIds.length; i++) {
            if (_marketIds[i] >= marketCount) revert MarketDoesNotExist();
            if (markets[_marketIds[i]].state != MarketState.Active) revert MarketNotActive();
            if (_prices[i] == 0) revert PriceMustBePositive();
            
            markets[_marketIds[i]].currentPrice = _prices[i];
        }
    }
    
    /**
     * @dev Get positions at risk of liquidation
     * @param _users Array of user addresses to check
     */
    function getPositionsAtRisk(address[] calldata _users) external view returns (
        address[] memory atRiskUsers,
        uint256[] memory healthPercentages
    ) {
        uint256 count = 0;
        
        // First pass: count at-risk positions
        for (uint256 i = 0; i < _users.length; i++) {
            Position memory pos = userPositions[_users[i]];
            if (pos.side != PositionSide.None) {
                Market memory market = markets[pos.marketId];
                if (market.state == MarketState.Active) {
                    (, uint256 finalCollateral,) = _calculatePositionValue(pos, market);
                    uint256 health = finalCollateral == 0 ? 0 : (finalCollateral * 100) / pos.collateral;
                    if (health < warningThreshold) {
                        count++;
                    }
                }
            }
        }
        
        // Second pass: populate arrays
        atRiskUsers = new address[](count);
        healthPercentages = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < _users.length; i++) {
            Position memory pos = userPositions[_users[i]];
            if (pos.side != PositionSide.None) {
                Market memory market = markets[pos.marketId];
                if (market.state == MarketState.Active) {
                    (, uint256 finalCollateral,) = _calculatePositionValue(pos, market);
                    uint256 health = finalCollateral == 0 ? 0 : (finalCollateral * 100) / pos.collateral;
                    if (health < warningThreshold) {
                        atRiskUsers[index] = _users[i];
                        healthPercentages[index] = health;
                        index++;
                    }
                }
            }
        }
    }
}