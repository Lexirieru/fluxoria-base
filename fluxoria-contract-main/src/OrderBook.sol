// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ConditionalTokens.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OrderBook is Ownable, Pausable, ReentrancyGuard {
    enum OrderType { Buy, Sell }
    enum OrderStatus { Active, Filled, Cancelled, PartiallyFilled }
    
    struct Order {
        uint256 id;
        address user;
        uint256 marketId;
        uint256 outcome;
        OrderType orderType;
        uint256 amount;         // Total amount of tokens
        uint256 filledAmount;   // Amount already filled
        uint256 price;          // Price per token (in collateral units)
        uint256 timestamp;
        OrderStatus status;
    }
    
    // Order management
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public userOrders;
    mapping(uint256 => uint256[]) public marketBuyOrders;  // marketId => orderIds
    mapping(uint256 => uint256[]) public marketSellOrders; // marketId => orderIds
    
    uint256 public nextOrderId = 1;
    uint256 public tradingFee = 25; // 0.25% (25 basis points)
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant PRICE_DENOMINATOR = 10**6; // Price is in units of 10^6
    
    // External contracts
    ConditionalTokens public conditionalTokens;
    IERC20 public collateralToken;
    
    // Events
    event OrderCreated(
        uint256 indexed orderId,
        address indexed user,
        uint256 indexed marketId,
        uint256 outcome,
        OrderType orderType,
        uint256 amount,
        uint256 price
    );
    
    event OrderFilled(
        uint256 indexed orderId,
        address indexed user,
        uint256 amount,
        uint256 price,
        uint256 fee
    );
    
    event OrderCancelled(
        uint256 indexed orderId,
        address indexed user,
        uint256 remainingAmount
    );
    
    event OrdersMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 amount,
        uint256 price
    );
    
    event TradingFeeUpdated(uint256 oldFee, uint256 newFee);
    
    constructor(
        address _conditionalTokens,
        address _collateralToken
    ) Ownable(msg.sender) {
        conditionalTokens = ConditionalTokens(_conditionalTokens);
        collateralToken = IERC20(_collateralToken);
    }
    
    /**
     * @dev Create a buy order
     */
    function createBuyOrder(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount,
        uint256 _maxPrice
    ) external whenNotPaused nonReentrant returns (uint256 orderId) {
        require(_amount > 0, "Amount must be positive");
        require(_maxPrice > 0, "Price must be positive");
        
        // Transfer collateral from user
        // Price is per token in units of 10^6, so we divide by PRICE_DENOMINATOR
        uint256 totalCost = (_amount * _maxPrice) / PRICE_DENOMINATOR;
        require(
            collateralToken.transferFrom(msg.sender, address(this), totalCost),
            "Collateral transfer failed"
        );
        
        orderId = _createOrder(
            msg.sender,
            _marketId,
            _outcome,
            OrderType.Buy,
            _amount,
            _maxPrice
        );
        
        marketBuyOrders[_marketId].push(orderId);
        userOrders[msg.sender].push(orderId);
        
        // Try to match with existing sell orders
        _matchOrders(orderId);
        
        emit OrderCreated(orderId, msg.sender, _marketId, _outcome, OrderType.Buy, _amount, _maxPrice);
    }
    
    /**
     * @dev Create a sell order
     */
    function createSellOrder(
        uint256 _marketId,
        uint256 _outcome,
        uint256 _amount,
        uint256 _minPrice
    ) external whenNotPaused nonReentrant returns (uint256 orderId) {
        require(_amount > 0, "Amount must be positive");
        require(_minPrice > 0, "Price must be positive");
        
        // Check user has enough tokens
        require(
            conditionalTokens.getOutcomeBalance(_marketId, msg.sender, _outcome) >= _amount,
            "Insufficient token balance"
        );
        
        // Transfer tokens from user using outcome-specific transfer
        conditionalTokens.transferOutcomeTokensFrom(_marketId, msg.sender, address(this), _outcome, _amount);
        
        orderId = _createOrder(
            msg.sender,
            _marketId,
            _outcome,
            OrderType.Sell,
            _amount,
            _minPrice
        );
        
        marketSellOrders[_marketId].push(orderId);
        userOrders[msg.sender].push(orderId);
        
        // Try to match with existing buy orders
        _matchOrders(orderId);
        
        emit OrderCreated(orderId, msg.sender, _marketId, _outcome, OrderType.Sell, _amount, _minPrice);
    }
    
    /**
     * @dev Cancel an order
     */
    function cancelOrder(uint256 _orderId) external whenNotPaused nonReentrant {
        Order storage order = orders[_orderId];
        require(order.user != address(0), "Order not active"); // Check if order exists
        require(order.user == msg.sender, "Not order owner");
        require(order.status == OrderStatus.Active || order.status == OrderStatus.PartiallyFilled, "Order not active");
        
        uint256 remainingAmount = order.amount - order.filledAmount;
        
        if (order.orderType == OrderType.Buy) {
            // Return unused collateral
            uint256 unusedCollateral = (remainingAmount * order.price) / PRICE_DENOMINATOR;
            if (unusedCollateral > 0) {
                require(
                    collateralToken.transfer(msg.sender, unusedCollateral),
                    "Collateral return failed"
                );
            }
        } else {
            // Return unused tokens
            if (remainingAmount > 0) {
                conditionalTokens.transferOutcomeTokens(order.marketId, msg.sender, order.outcome, remainingAmount);
            }
        }
        
        order.status = OrderStatus.Cancelled;
        
        emit OrderCancelled(_orderId, msg.sender, remainingAmount);
    }
    
    /**
     * @dev Match orders for a specific order
     */
    function _matchOrders(uint256 _orderId) internal {
        Order storage order = orders[_orderId];
        if (order.status != OrderStatus.Active) return;
        
        uint256[] storage oppositeOrders = order.orderType == OrderType.Buy 
            ? marketSellOrders[order.marketId]
            : marketBuyOrders[order.marketId];
        
        for (uint256 i = 0; i < oppositeOrders.length; i++) {
            uint256 oppositeOrderId = oppositeOrders[i];
            Order storage oppositeOrder = orders[oppositeOrderId];
            
            if (oppositeOrder.status != OrderStatus.Active) continue;
            if (oppositeOrder.outcome != order.outcome) continue;
            
            // Check if orders can match
            bool canMatch = order.orderType == OrderType.Buy 
                ? _canMatch(order, oppositeOrder)
                : _canMatch(oppositeOrder, order);
            if (!canMatch) continue;
            
            // Calculate match amount and price
            (uint256 matchAmount, uint256 matchPrice) = _calculateMatch(order, oppositeOrder);
            if (matchAmount == 0) continue;
            
            // Execute the match
            _executeMatch(order, oppositeOrder, matchAmount, matchPrice);
            
            // If order is fully filled, break
            if (order.status == OrderStatus.Filled) break;
        }
    }
    
    /**
     * @dev Check if two orders can match
     */
    function _canMatch(Order memory buyOrder, Order memory sellOrder) internal pure returns (bool) {
        return buyOrder.price >= sellOrder.price;
    }
    
    /**
     * @dev Calculate match amount and price
     */
    function _calculateMatch(
        Order memory order1, 
        Order memory order2
    ) internal pure returns (uint256 amount, uint256 price) {
        uint256 available1 = order1.amount - order1.filledAmount;
        uint256 available2 = order2.amount - order2.filledAmount;
        
        amount = available1 < available2 ? available1 : available2;
        
        // Use the price from the order that was placed first
        price = order1.timestamp < order2.timestamp ? order1.price : order2.price;
    }
    
    /**
     * @dev Execute a match between two orders
     */
    function _executeMatch(
        Order storage order1,
        Order storage order2,
        uint256 amount,
        uint256 price
    ) internal {
        // Calculate fees
        uint256 totalValue = (amount * price) / PRICE_DENOMINATOR;
        uint256 fee = (totalValue * tradingFee) / FEE_DENOMINATOR;
        
        // Update order states
        order1.filledAmount += amount;
        order2.filledAmount += amount;
        
        if (order1.filledAmount >= order1.amount) {
            order1.status = OrderStatus.Filled;
        } else {
            order1.status = OrderStatus.PartiallyFilled;
        }
        
        if (order2.filledAmount >= order2.amount) {
            order2.status = OrderStatus.Filled;
        } else {
            order2.status = OrderStatus.PartiallyFilled;
        }
        
        // Execute transfers
        if (order1.orderType == OrderType.Buy) {
            // Buy order: give tokens, take collateral
            conditionalTokens.transferOutcomeTokens(order1.marketId, order1.user, order1.outcome, amount);
            
            // Calculate excess collateral to return
            // Buyer deposited: order1.amount * order1.price
            // Buyer used so far: order1.filledAmount * price (at various match prices)
            // For this match, buyer used: amount * price
            // Excess from this match if price < order1.price: amount * (order1.price - price)
            // Plus any remaining unfilled amount: (order1.amount - order1.filledAmount) * order1.price
            uint256 excessFromPriceDiff = 0;
            if (price < order1.price) {
                excessFromPriceDiff = (amount * (order1.price - price)) / PRICE_DENOMINATOR;
            }
            uint256 excessFromUnfilled = ((order1.amount - order1.filledAmount) * order1.price) / PRICE_DENOMINATOR;
            uint256 totalExcess = excessFromPriceDiff + excessFromUnfilled;
            
            if (totalExcess > 0) {
                require(
                    collateralToken.transfer(order1.user, totalExcess),
                    "Collateral return failed"
                );
            }
            
            // Give collateral to sell order user
            require(
                collateralToken.transfer(order2.user, totalValue - fee),
                "Collateral transfer failed"
            );
        } else {
            // Sell order: give collateral, take tokens
            require(
                collateralToken.transfer(order1.user, totalValue - fee),
                "Collateral transfer failed"
            );
            
            // Return excess tokens
            uint256 excessTokens = order1.amount - order1.filledAmount;
            if (excessTokens > 0) {
                conditionalTokens.transferOutcomeTokens(order1.marketId, order1.user, order1.outcome, excessTokens);
            }
            
            // Give tokens to buy order user
            conditionalTokens.transferOutcomeTokens(order2.marketId, order2.user, order2.outcome, amount);
        }
        
        emit OrdersMatched(order1.id, order2.id, amount, price);
        emit OrderFilled(order1.id, order1.user, amount, price, fee);
        emit OrderFilled(order2.id, order2.user, amount, price, fee);
    }
    
    /**
     * @dev Create a new order
     */
    function _createOrder(
        address _user,
        uint256 _marketId,
        uint256 _outcome,
        OrderType _orderType,
        uint256 _amount,
        uint256 _price
    ) internal returns (uint256 orderId) {
        orderId = nextOrderId++;
        
        orders[orderId] = Order({
            id: orderId,
            user: _user,
            marketId: _marketId,
            outcome: _outcome,
            orderType: _orderType,
            amount: _amount,
            filledAmount: 0,
            price: _price,
            timestamp: block.timestamp,
            status: OrderStatus.Active
        });
    }
    
    /**
     * @dev Get all orders for a market
     */
    function getMarketOrders(uint256 _marketId) external view returns (uint256[] memory buyOrders, uint256[] memory sellOrders) {
        return (marketBuyOrders[_marketId], marketSellOrders[_marketId]);
    }
    
    /**
     * @dev Get user's orders
     */
    function getUserOrders(address _user) external view returns (uint256[] memory) {
        return userOrders[_user];
    }
    
    /**
     * @dev Get order details
     */
    function getOrder(uint256 _orderId) external view returns (Order memory) {
        return orders[_orderId];
    }
    
    /**
     * @dev Get market depth (best buy/sell prices)
     */
    function getMarketDepth(uint256 _marketId, uint256 _outcome) external view returns (uint256 bestBuyPrice, uint256 bestSellPrice) {
        uint256[] memory buyOrders = marketBuyOrders[_marketId];
        uint256[] memory sellOrders = marketSellOrders[_marketId];
        
        // Find best buy price
        for (uint256 i = 0; i < buyOrders.length; i++) {
            Order memory order = orders[buyOrders[i]];
            if (order.outcome == _outcome && order.status == OrderStatus.Active) {
                if (bestBuyPrice == 0 || order.price > bestBuyPrice) {
                    bestBuyPrice = order.price;
                }
            }
        }
        
        // Find best sell price
        for (uint256 i = 0; i < sellOrders.length; i++) {
            Order memory order = orders[sellOrders[i]];
            if (order.outcome == _outcome && order.status == OrderStatus.Active) {
                if (bestSellPrice == 0 || order.price < bestSellPrice) {
                    bestSellPrice = order.price;
                }
            }
        }
    }
    
    /**
     * @dev Update trading fee (only owner)
     */
    function setTradingFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee too high"); // Max 10%
        uint256 oldFee = tradingFee;
        tradingFee = _newFee;
        emit TradingFeeUpdated(oldFee, _newFee);
    }
    
    /**
     * @dev Withdraw collected fees (only owner)
     */
    function withdrawFees() external onlyOwner {
        uint256 balance = collateralToken.balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        require(
            collateralToken.transfer(owner(), balance),
            "Fee withdrawal failed"
        );
    }
    
    /**
     * @dev Get total collected fees
     */
    function getTotalFees() external view returns (uint256) {
        return collateralToken.balanceOf(address(this));
    }
    
    /**
     * @dev Pause all order book operations (only owner)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause all order book operations (only owner)
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
